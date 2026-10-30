import Foundation

struct MediaAudioCacheRepresentation: Equatable, Sendable {
    let length: Int64
    let contentType: String
    let validator: String?
    /// Identity of the final response URL, not a URL or a credential-bearing request.
    let resourceKey: String
}

/// Persistent byte ranges for a single, validated media representation, not HLS offline storage.
final class MediaAudioDiskCache: @unchecked Sendable {
    static let shared = MediaAudioDiskCache(
        directory: (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory).appendingPathComponent("LegadoMediaAudio", isDirectory: true))

    private static let maximumCapacity: Int64 = 100 * 1024 * 1024
    private static let maximumChunk = 256 * 1024
    private static let maximumRead = 64 * 1024
    private let storage: Storage
    private let capacity: Int64
    private let lifetime: TimeInterval
    private let now: @Sendable () -> Date

    init(
        directory: URL, capacity: Int64 = 100 * 1024 * 1024, lifetime: TimeInterval = 86400,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.capacity = max(0, min(capacity, Self.maximumCapacity))
        self.lifetime = lifetime.isFinite ? max(0, min(lifetime, 86400)) : 0
        self.now = now
        // Only this namespace is scanned or cleaned, even if the caller supplies a shared cache directory.
        let base = directory.isFileURL ? directory.standardizedFileURL.resolvingSymlinksInPath() : directory
        storage = Registry.shared.storage(at: base.appendingPathComponent("single-file-v1", isDirectory: true))
    }

    static func resourceKey(_ url: URL) -> String { MediaAudioDiskCachePolicy.resourceKey(url) }

    var generation: UInt64 {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        return storage.generation
    }

    func lookup(request: URLRequest) -> MediaAudioDiskCacheLease? {
        guard let key = MediaAudioDiskCachePolicy.requestKey(request) else { return nil }
        storage.lock.lock()
        defer { storage.lock.unlock() }
        let date = now()
        guard prepare(at: date), let id = storage.current[key], let entry = storage.entries[id],
            !entry.retired, entry.usable
        else { return nil }
        return lease(entry, at: date, writable: false)
    }

    func store(
        request: URLRequest, response: HTTPURLResponse, contentType: String, length: Int64, validator: String?,
        generation: UInt64? = nil
    ) -> MediaAudioDiskCacheLease? {
        guard let key = MediaAudioDiskCachePolicy.requestKey(request) else { return nil }
        storage.lock.lock()
        defer { storage.lock.unlock() }
        guard generation == nil || generation == storage.generation else { return nil }
        let date = now()
        guard prepare(at: date, forRemoval: true) else { return nil }
        guard let url = response.url,
            let expires = MediaAudioDiskCachePolicy.freshness(
                request: request, response: response, lifetime: lifetime, now: date),
            Self.validMetadata(contentType, allowEmpty: false),
            validator.map({ Self.validMetadata($0, allowEmpty: false) }) ?? true,
            Self.responseMatchesLength(response, length: length)
        else {
            if let id = storage.current[key], let entry = storage.entries[id] { retire(entry) }
            collectRetired()
            return nil
        }
        let identity = Self.resourceKey(url)
        if validator != nil, let id = storage.current[key], let entry = storage.entries[id], entry.usable, !entry.retired,
            entry.manifest.resourceKey == identity, entry.manifest.length == length,
            entry.manifest.contentType == contentType, entry.manifest.validator == validator
        {
            // Repeated range responses must not turn an old representation into an immortal entry.
            let deadline = min(entry.manifest.expiresAt, expires)
            if deadline != entry.manifest.expiresAt {
                var updated = entry.manifest
                updated.expiresAt = deadline
                updated.accessedAt = max(updated.createdAt, min(date, deadline))
                guard let files = storage.files,
                    makeSpace(additional: manifestReservation(updated), protecting: updated.id)
                else {
                    retire(entry)
                    collectRetired()
                    return nil
                }
                do {
                    try files.save(updated)
                    entry.manifest = updated
                } catch {
                    retire(entry)
                    collectRetired()
                    return nil
                }
            }
            return lease(entry, at: date, writable: true)
        }
        if let id = storage.current[key], let old = storage.entries[id] { retire(old) }
        collectRetired()
        let manifest = MediaAudioDiskCacheManifest(
            id: UUID().uuidString.lowercased(), requestKey: key, resourceKey: identity,
            length: length, contentType: contentType, validator: validator, createdAt: date,
            expiresAt: expires, accessedAt: date, chunks: [])
        guard let files = storage.files,
            makeSpace(additional: manifestReservation(manifest), protecting: nil)
        else { return nil }
        do {
            try files.save(manifest)
            guard try files.allocatedSize() <= capacity else {
                try? files.remove(version: manifest.id)
                return nil
            }
        } catch {
            try? files.remove(version: manifest.id)
            return nil
        }
        let entry = Entry(manifest)
        storage.entries[manifest.id] = entry
        storage.current[key] = manifest.id
        return lease(entry, at: date, writable: true)
    }

    func invalidate(request: URLRequest) {
        guard let key = MediaAudioDiskCachePolicy.requestKey(request) else { return }
        storage.lock.lock()
        defer { storage.lock.unlock() }
        guard prepare(at: now(), forRemoval: true) else { return }
        // Include already detached leases so invalidation cannot leave a writable old generation.
        for entry in storage.entries.values where entry.manifest.requestKey == key { retire(entry) }
        collectRetired()
        cleanOrphans()
    }

    func removeAll() {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        storage.generation &+= 1
        guard prepare(at: now(), forRemoval: true) else { return }
        for entry in storage.entries.values { retire(entry) }
        collectRetired()
        cleanOrphans()
    }

    fileprivate func invalidate(version: String) {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        guard let entry = storage.entries[version] else { return }
        retire(entry)
        collectRetired()
    }

    fileprivate func read(version: String, offset: Int64, count: Int) throws -> Data? {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        let date = now()
        guard prepare(at: date), let entry = storage.entries[version], entry.usable,
            let files = storage.files, offset >= 0, offset < entry.manifest.length, count > 0
        else { return nil }
        let limit = min(Int64(min(count, Self.maximumRead)), entry.manifest.length - offset)
        var result = Data()
        var cursor = offset
        do {
            for chunk in entry.manifest.chunks {
                let end = chunk.offset + Int64(chunk.count)
                if end <= cursor { continue }
                if chunk.offset > cursor || Int64(result.count) >= limit { break }
                let bytes = try files.read(chunk, version: version)
                let start = Int(cursor - chunk.offset)
                let amount = min(chunk.count - start, Int(limit) - result.count)
                result.append(bytes.subdata(in: start..<start + amount))
                cursor += Int64(amount)
            }
        } catch {
            // Never expose even a prefix from a read which encountered a corrupt chunk.
            entry.usable = false
            retire(entry)
            collectRetired()
            return nil
        }
        guard !result.isEmpty else { return nil }
        touch(entry, at: date)
        return result
    }

    /// The caller supplies only bytes from a successfully completed and validated transfer.
    fileprivate func write(version: String, offset: Int64, data: Data) -> Bool {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        let date = now()
        guard prepare(at: date), let entry = storage.entries[version], entry.usable, !entry.retired,
            let files = storage.files, offset >= 0, offset <= entry.manifest.length,
            Int64(data.count) <= entry.manifest.length - offset
        else { return false }
        guard !data.isEmpty else { return true }
        let end = offset + Int64(data.count)
        do {
            // Existing chunks are immutable. Conflicting overlapping bytes revoke the representation.
            for chunk in entry.manifest.chunks where chunk.offset < end && chunk.offset + Int64(chunk.count) > offset {
                let bytes = try files.read(chunk, version: version)
                let start = max(offset, chunk.offset)
                let stop = min(end, chunk.offset + Int64(chunk.count))
                let existing = Int(start - chunk.offset)..<Int(stop - chunk.offset)
                let incoming = (data.startIndex + Int(start - offset))..<(data.startIndex + Int(stop - offset))
                guard bytes.subdata(in: existing) == data.subdata(in: incoming) else {
                    entry.usable = false
                    retire(entry)
                    collectRetired()
                    return false
                }
            }
            // Snapshot the coverage: insert only holes, never infer coverage from file length.
            let coverage = entry.manifest.chunks
            var cursor = offset
            for chunk in coverage {
                if cursor >= end { break }
                let chunkEnd = chunk.offset + Int64(chunk.count)
                if chunkEnd <= cursor { continue }
                if chunk.offset > cursor {
                    let stop = min(end, chunk.offset)
                    guard writeHole(entry, from: cursor, to: stop, inputOffset: offset, data: data, at: date) else {
                        return false
                    }
                    cursor = stop
                }
                if cursor < end { cursor = max(cursor, min(end, chunkEnd)) }
            }
            if cursor < end,
                !writeHole(entry, from: cursor, to: end, inputOffset: offset, data: data, at: date)
            {
                return false
            }
            touch(entry, at: date)
            return true
        } catch {
            entry.usable = false
            retire(entry)
            collectRetired()
            return false
        }
    }

    fileprivate func complete(version: String) -> Bool {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        guard prepare(at: now()), let entry = storage.entries[version], entry.usable,
            let files = storage.files
        else { return false }
        var cursor: Int64 = 0
        do {
            for chunk in entry.manifest.chunks {
                guard chunk.offset == cursor else { return false }
                _ = try files.read(chunk, version: version)
                cursor += Int64(chunk.count)
            }
        } catch {
            entry.usable = false
            retire(entry)
            collectRetired()
            return false
        }
        return cursor == entry.manifest.length
    }

    fileprivate func firstMissingOffset(version: String) -> Int64? {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        guard prepare(at: now()), let entry = storage.entries[version], entry.usable else { return nil }
        var cursor: Int64 = 0
        for chunk in entry.manifest.chunks {
            if chunk.offset > cursor { return cursor }
            cursor = max(cursor, chunk.offset + Int64(chunk.count))
        }
        return cursor < entry.manifest.length ? cursor : nil
    }

    fileprivate func release(version: String) {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        guard let entry = storage.entries[version], entry.leases > 0 else { return }
        entry.leases -= 1
        collectRetired()
        _ = makeSpace(additional: 0, protecting: nil)
    }

    private func writeHole(
        _ entry: Entry, from start: Int64, to end: Int64, inputOffset: Int64, data: Data, at date: Date
    ) -> Bool {
        guard let files = storage.files else { return false }
        var cursor = start
        while cursor < end {
            guard entry.manifest.chunks.count < 16384 else { return false }
            let amount = Int(min(Int64(Self.maximumChunk), end - cursor))
            let index = data.startIndex + Int(cursor - inputOffset)
            let bytes = data.subdata(in: index..<index + amount)
            let chunk = MediaAudioDiskCacheChunk(
                id: UUID().uuidString.lowercased(), offset: cursor, count: amount,
                digest: MediaAudioDiskCachePolicy.digest(bytes))
            var updated = entry.manifest
            updated.chunks.append(chunk)
            updated.chunks.sort { $0.offset < $1.offset }
            updated.accessedAt = max(updated.createdAt, min(date, updated.expiresAt))
            let reserve = allocationBound(amount) + manifestReservation(updated)
            guard makeSpace(additional: reserve, protecting: updated.id) else { return false }
            do {
                try files.write(bytes, id: chunk.id, version: updated.id)
                try files.save(updated)
                guard try files.allocatedSize() <= capacity else {
                    entry.usable = false
                    retire(entry)
                    cleanOrphans()
                    return false
                }
                // Publish coverage only after both the complete chunk and its manifest are durable.
                entry.manifest = updated
            } catch {
                // A failed atomic replace has an uncertain outcome. Do not keep that version reusable.
                entry.usable = false
                retire(entry)
                cleanOrphans()
                return false
            }
            cursor += Int64(amount)
        }
        return true
    }

    private func lease(_ entry: Entry, at date: Date, writable: Bool) -> MediaAudioDiskCacheLease {
        entry.leases += 1
        touch(entry, at: date)
        return MediaAudioDiskCacheLease(
            cache: self, version: entry.manifest.id, writable: writable,
            representation: MediaAudioCacheRepresentation(
                length: entry.manifest.length, contentType: entry.manifest.contentType,
                validator: entry.manifest.validator, resourceKey: entry.manifest.resourceKey))
    }

    private func touch(_ entry: Entry, at date: Date) {
        storage.clock &+= 1
        entry.lastUse = storage.clock
        guard !entry.retired, let files = storage.files else { return }
        let accessed = max(entry.manifest.createdAt, min(date, entry.manifest.expiresAt))
        guard accessed.timeIntervalSince(entry.manifest.accessedAt) >= 60 else { return }
        entry.manifest.accessedAt = accessed
        if makeSpace(additional: manifestReservation(entry.manifest), protecting: entry.manifest.id) {
            try? files.save(entry.manifest)
        }
    }

    private func prepare(at date: Date, forRemoval: Bool = false) -> Bool {
        guard (forRemoval || (capacity > 0 && lifetime > 0)), date.timeIntervalSince1970.isFinite else { return false }
        do {
            if storage.files == nil { storage.files = try MediaAudioDiskCacheFiles(root: storage.root) }
            guard let files = storage.files else { return false }
            if !storage.loaded {
                let manifests = try files.load().sorted {
                    if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                    if $0.accessedAt != $1.accessedAt { return $0.accessedAt < $1.accessedAt }
                    return $0.id < $1.id
                }
                for manifest in manifests {
                    let entry = Entry(manifest)
                    storage.entries[manifest.id] = entry
                    if let oldID = storage.current[manifest.requestKey], let old = storage.entries[oldID] {
                        retire(old)
                    }
                    storage.current[manifest.requestKey] = manifest.id
                }
                // Restore LRU order separately from generation selection.
                for entry in storage.entries.values.sorted(by: { $0.manifest.accessedAt < $1.manifest.accessedAt }) {
                    storage.clock &+= 1
                    entry.lastUse = storage.clock
                }
                storage.loaded = true
                cleanOrphans()
            }
            for entry in storage.entries.values where !entry.retired {
                let deadline = min(entry.manifest.expiresAt, entry.manifest.createdAt.addingTimeInterval(lifetime))
                if date < entry.manifest.createdAt || date >= deadline { retire(entry) }
            }
            collectRetired()
            // Leased versions are never evicted to make a new write fit.
            _ = makeSpace(additional: 0, protecting: nil)
            return true
        } catch {
            return false
        }
    }

    private func retire(_ entry: Entry) {
        entry.retired = true
        let manifest = entry.manifest
        if storage.current[manifest.requestKey] == manifest.id { storage.current.removeValue(forKey: manifest.requestKey) }
        // Removing only the manifest prevents resurrection after a crash without unlinking leased chunks.
        if !entry.retirementPersisted, let files = storage.files {
            do {
                try files.retire(version: manifest.id)
                entry.retirementPersisted = true
            } catch {}
        }
    }

    private func collectRetired() {
        guard let files = storage.files else { return }
        for entry in storage.entries.values where entry.retired && !entry.retirementPersisted {
            do {
                try files.retire(version: entry.manifest.id)
                entry.retirementPersisted = true
            } catch {}
        }
        let removable = storage.entries.values.filter { $0.retired && $0.leases == 0 }
        for entry in removable {
            do {
                try files.remove(version: entry.manifest.id)
                storage.entries.removeValue(forKey: entry.manifest.id)
            } catch {
                // Keep failed deletions accounted for and retry on the next operation.
            }
        }
    }

    private func cleanOrphans() {
        try? storage.files?.removeOrphans(keeping: storage.entries.values.map(\.manifest))
    }

    private func makeSpace(additional: Int64, protecting id: String?) -> Bool {
        guard let files = storage.files, additional >= 0, additional <= capacity else { return false }
        do {
            var occupied = try files.allocatedSize()
            if occupied <= capacity - additional { return true }
            let victims = storage.entries.values.filter {
                $0.leases == 0 && $0.manifest.id != id
            }.sorted {
                if $0.retired != $1.retired { return $0.retired }
                return $0.lastUse < $1.lastUse
            }
            for victim in victims {
                retire(victim)
                do {
                    try files.remove(version: victim.manifest.id)
                    storage.entries.removeValue(forKey: victim.manifest.id)
                } catch { continue }
                occupied = try files.allocatedSize()
                if occupied <= capacity - additional { return true }
            }
        } catch { return false }
        return false
    }

    private func manifestReservation(_ manifest: MediaAudioDiskCacheManifest) -> Int64 {
        guard let data = try? JSONEncoder().encode(manifest), data.count <= 8 * 1024 * 1024 else { return capacity + 1 }
        // Include the old/new atomic manifest, directory metadata and allocation rounding, not just payload.
        return 2 * allocationBound(data.count * 2 + 1024)
    }

    private func allocationBound(_ count: Int) -> Int64 {
        let block = (try? storage.files?.allocationUnit()) ?? 4096
        return ((Int64(count) + block - 1) / block + 1) * block
    }

    private static func validMetadata(_ value: String, allowEmpty: Bool) -> Bool {
        (allowEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && value.utf8.count <= 8192 && !value.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }

    private static func responseMatchesLength(_ response: HTTPURLResponse, length: Int64) -> Bool {
        guard length > 0 else { return false }
        func number(_ text: Substring) -> Int64? {
            guard !text.isEmpty, text.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
            return Int64(text)
        }
        let rawLength = response.value(forHTTPHeaderField: "Content-Length")?.trimmingCharacters(in: .whitespaces)
        let declared = rawLength.flatMap { number($0[...]) }
        if rawLength != nil && declared == nil { return false }
        if response.statusCode == 200 {
            return response.value(forHTTPHeaderField: "Content-Range") == nil && (declared == nil || declared == length)
        }
        guard response.statusCode == 206,
            let value = response.value(forHTTPHeaderField: "Content-Range")?.trimmingCharacters(in: .whitespaces),
            value.lowercased().hasPrefix("bytes ")
        else { return false }
        let parts = value.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let total = number(parts[1]), total == length else { return false }
        let bounds = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let start = number(bounds[0]), let end = number(bounds[1]),
            start <= end, end < length
        else { return false }
        return declared == nil || declared == end - start + 1
    }

    private final class Entry {
        var manifest: MediaAudioDiskCacheManifest
        var leases = 0
        var lastUse: UInt64 = 0
        var retired = false
        var retirementPersisted = false
        var usable = true

        init(_ manifest: MediaAudioDiskCacheManifest) { self.manifest = manifest }
    }

    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        let root: URL
        var files: MediaAudioDiskCacheFiles?
        var loaded = false
        var entries: [String: Entry] = [:]
        var current: [String: String] = [:]
        var clock: UInt64 = 0
        var generation: UInt64 = 0

        init(root: URL) { self.root = root }
    }

    private final class Registry: @unchecked Sendable {
        private final class WeakStorage {
            weak var value: Storage?
            init(_ value: Storage) { self.value = value }
        }

        static let shared = Registry()
        private let lock = NSLock()
        private var stores: [String: WeakStorage] = [:]

        func storage(at root: URL) -> Storage {
            lock.lock()
            defer { lock.unlock() }
            if let existing = stores[root.path]?.value { return existing }
            stores = stores.filter { $0.value.value != nil }
            let storage = Storage(root: root)
            stores[root.path] = WeakStorage(storage)
            return storage
        }
    }
}

final class MediaAudioDiskCacheLease: @unchecked Sendable {
    let representation: MediaAudioCacheRepresentation
    private let lock = NSLock()
    private var cache: MediaAudioDiskCache?
    private let version: String
    private let writable: Bool

    fileprivate init(
        cache: MediaAudioDiskCache, version: String, writable: Bool, representation: MediaAudioCacheRepresentation
    ) {
        self.cache = cache
        self.version = version
        self.writable = writable
        self.representation = representation
    }

    var isComplete: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cache?.complete(version: version) ?? false
    }

    /// Metadata coverage only; nil also includes a closed or unavailable version, not just complete coverage.
    var firstMissingOffset: Int64? {
        lock.lock()
        defer { lock.unlock() }
        return cache?.firstMissingOffset(version: version)
    }

    func read(offset: Int64, count: Int) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return try cache?.read(version: version, offset: offset, count: count)
    }

    @discardableResult
    func write(offset: Int64, data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return writable && (cache?.write(version: version, offset: offset, data: data) ?? false)
    }

    func close() {
        lock.lock()
        let owner = cache
        cache = nil
        lock.unlock()
        owner?.release(version: version)
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        cache?.invalidate(version: version)
    }

    deinit { close() }
}
