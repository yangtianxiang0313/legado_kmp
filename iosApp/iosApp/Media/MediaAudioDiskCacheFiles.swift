import Foundation
import Darwin

struct MediaAudioDiskCacheChunk: Codable, Equatable {
    let id: String
    let offset: Int64
    let count: Int
    let digest: String

    init(id: String = UUID().uuidString.lowercased(), offset: Int64, count: Int, digest: String) {
        self.id = id
        self.offset = offset
        self.count = count
        self.digest = digest
    }
}

struct MediaAudioDiskCacheManifest: Codable {
    var schema: Int = 1
    let id: String
    let requestKey: String
    let resourceKey: String
    let length: Int64
    let contentType: String
    let validator: String?
    let createdAt: Date
    var expiresAt: Date
    var accessedAt: Date
    var chunks: [MediaAudioDiskCacheChunk]
}

private enum MediaAudioDiskCacheFileError: LocalizedError {
    case invalid, io

    var errorDescription: String? {
        switch self {
        case .invalid: return "音频磁盘缓存数据无效。"
        case .io: return "无法访问音频磁盘缓存。"
        }
    }
}

private struct MediaAudioDiskCacheManifestEnvelope: Codable {
    let payload: Data
    let digest: String
}

final class MediaAudioDiskCacheFiles {
    let root: URL
    private let manager = FileManager.default
    private static let chunkLimit = 256 * 1024
    private static let manifestLimit = 8 * 1024 * 1024
    private var lockDescriptor: Int32 = -1
    private var rootDevice: dev_t = 0
    private var rootInode: ino_t = 0

    init(root: URL) throws {
        guard root.isFileURL else { throw MediaAudioDiskCacheFileError.invalid }
        self.root = root.standardizedFileURL
        do {
            try Self.checkAncestors(self.root)
            try manager.createDirectory(at: self.root, withIntermediateDirectories: true)
            try checkDirectory(self.root)
            try protect(self.root)
            var info = stat()
            guard lstat(self.root.path, &info) == 0 else { throw MediaAudioDiskCacheFileError.io }
            rootDevice = info.st_dev
            rootInode = info.st_ino
            let lockURL = self.root.appendingPathComponent(".owner.lock")
            let descriptor = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK, mode_t(0o600))
            guard descriptor >= 0 else { throw MediaAudioDiskCacheFileError.io }
            do {
                var lockInfo = stat()
                guard fstat(descriptor, &lockInfo) == 0, (lockInfo.st_mode & S_IFMT) == S_IFREG,
                    lockInfo.st_nlink == 1, flock(descriptor, LOCK_EX | LOCK_NB) == 0
                else { throw MediaAudioDiskCacheFileError.io }
                try protect(lockURL)
                lockDescriptor = descriptor
            } catch {
                close(descriptor)
                throw error
            }
        } catch { throw MediaAudioDiskCacheFileError.io }
    }

    deinit {
        if lockDescriptor >= 0 {
            _ = flock(lockDescriptor, LOCK_UN)
            close(lockDescriptor)
        }
    }

    func load() throws -> [MediaAudioDiskCacheManifest] {
        try checkRoot()
        var manifests: [MediaAudioDiskCacheManifest] = []
        for directory in try contents(root) where Self.isUUID(directory.lastPathComponent) {
            guard isDirectory(directory) else {
                try remove(version: directory.lastPathComponent)
                continue
            }
            do {
                let bytes = try readFile(directory.appendingPathComponent("manifest.json"), limit: Self.manifestLimit)
                let envelope = try JSONDecoder().decode(MediaAudioDiskCacheManifestEnvelope.self, from: bytes)
                guard Self.isDigest(envelope.digest),
                    MediaAudioDiskCachePolicy.digest(envelope.payload) == envelope.digest
                else { throw MediaAudioDiskCacheFileError.invalid }
                let manifest = try JSONDecoder().decode(MediaAudioDiskCacheManifest.self, from: envelope.payload)
                try validate(manifest)
                guard manifest.id == directory.lastPathComponent else { throw MediaAudioDiskCacheFileError.invalid }
                for chunk in manifest.chunks { _ = try read(chunk, version: manifest.id) }
                manifests.append(manifest)
            } catch {
                try remove(version: directory.lastPathComponent)
            }
        }
        return manifests
    }

    func save(_ manifest: MediaAudioDiskCacheManifest) throws {
        try validate(manifest)
        let bytes: Data
        do {
            let payload = try JSONEncoder().encode(manifest)
            bytes = try JSONEncoder().encode(
                MediaAudioDiskCacheManifestEnvelope(
                    payload: payload, digest: MediaAudioDiskCachePolicy.digest(payload)))
        } catch { throw MediaAudioDiskCacheFileError.invalid }
        guard bytes.count <= Self.manifestLimit else { throw MediaAudioDiskCacheFileError.invalid }
        let directory = try versionDirectory(manifest.id, create: true)
        try atomicWrite(bytes, to: directory.appendingPathComponent("manifest.json"))
    }

    func write(_ data: Data, id: String, version: String) throws {
        guard Self.isUUID(id), !data.isEmpty, data.count <= Self.chunkLimit else {
            throw MediaAudioDiskCacheFileError.invalid
        }
        let directory = try versionDirectory(version, create: true)
        try atomicWrite(data, to: directory.appendingPathComponent(id + ".chunk"))
    }

    func read(_ chunk: MediaAudioDiskCacheChunk, version: String) throws -> Data {
        guard Self.isUUID(chunk.id), chunk.count > 0, chunk.count <= Self.chunkLimit,
            Self.isDigest(chunk.digest)
        else { throw MediaAudioDiskCacheFileError.invalid }
        let directory = try versionDirectory(version, create: false)
        let data = try readFile(directory.appendingPathComponent(chunk.id + ".chunk"), limit: Self.chunkLimit)
        guard data.count == chunk.count, MediaAudioDiskCachePolicy.digest(data) == chunk.digest else {
            throw MediaAudioDiskCacheFileError.invalid
        }
        return data
    }

    func retire(version: String) throws {
        try checkRoot()
        guard Self.isUUID(version) else { throw MediaAudioDiskCacheFileError.invalid }
        let directory = root.appendingPathComponent(version, isDirectory: true)
        var info = stat()
        guard lstat(directory.path, &info) == 0 else {
            if errno == ENOENT { return }
            throw MediaAudioDiskCacheFileError.io
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            guard unlink(directory.path) == 0 else { throw MediaAudioDiskCacheFileError.io }
            try synchronize(root)
            return
        }
        let manifest = directory.appendingPathComponent("manifest.json")
        guard unlink(manifest.path) == 0 || errno == ENOENT else { throw MediaAudioDiskCacheFileError.io }
        try synchronize(directory)
    }

    func remove(version: String) throws {
        try checkRoot()
        guard Self.isUUID(version) else { throw MediaAudioDiskCacheFileError.invalid }
        let directory = root.appendingPathComponent(version, isDirectory: true)
        var directoryInfo = stat()
        guard lstat(directory.path, &directoryInfo) == 0 else {
            if errno == ENOENT { return }
            throw MediaAudioDiskCacheFileError.io
        }
        guard (directoryInfo.st_mode & S_IFMT) == S_IFDIR else {
            guard unlink(directory.path) == 0 else { throw MediaAudioDiskCacheFileError.io }
            try synchronize(root)
            return
        }
        for file in try contents(directory) where Self.isOwnedFile(file.lastPathComponent) {
            // Unlinking a symlink removes only the link; never traverse it.
            var info = stat()
            guard lstat(file.path, &info) == 0 else { continue }
            guard (info.st_mode & S_IFMT) != S_IFDIR else { continue }
            guard unlink(file.path) == 0 else { throw MediaAudioDiskCacheFileError.io }
        }
        if try contents(directory).isEmpty {
            guard rmdir(directory.path) == 0 else { throw MediaAudioDiskCacheFileError.io }
        }
        try synchronize(root)
    }

    func allocatedSize() throws -> Int64 {
        try checkRoot()
        func size(_ url: URL) throws -> Int64 {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw MediaAudioDiskCacheFileError.io }
            // lstat accounts for the link itself without following its target.
            if (info.st_mode & S_IFMT) == S_IFLNK { return max(Int64(info.st_size), Int64(info.st_blocks) * 512) }
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: [.fileAllocatedSizeKey, .totalFileAllocatedSizeKey, .fileSizeKey])
            } catch { throw MediaAudioDiskCacheFileError.io }
            var result = max(
                max(Int64(values.fileAllocatedSize ?? 0), Int64(values.totalFileAllocatedSize ?? 0)),
                max(Int64(values.fileSize ?? 0), Int64(info.st_blocks) * 512)
            )
            if (info.st_mode & S_IFMT) == S_IFDIR {
                for child in try contents(url) {
                    let (sum, overflow) = result.addingReportingOverflow(try size(child))
                    guard !overflow else { throw MediaAudioDiskCacheFileError.invalid }
                    result = sum
                }
            }
            return result
        }
        return try size(root)
    }

    func allocationUnit() throws -> Int64 {
        try checkRoot()
        var info = statfs()
        guard statfs(root.path, &info) == 0 else { throw MediaAudioDiskCacheFileError.io }
        return max(4096, Int64(info.f_bsize))
    }

    func removeOrphans(keeping manifests: [MediaAudioDiskCacheManifest]) throws {
        try checkRoot()
        var retained: [String: Set<String>] = [:]
        for manifest in manifests {
            try validate(manifest)
            retained[manifest.id, default: []].formUnion(manifest.chunks.map { $0.id + ".chunk" })
        }
        for directory in try contents(root) where Self.isUUID(directory.lastPathComponent) {
            guard isDirectory(directory) else {
                try remove(version: directory.lastPathComponent)
                continue
            }
            guard let chunks = retained[directory.lastPathComponent] else {
                try remove(version: directory.lastPathComponent)
                continue
            }
            for file in try contents(directory) where Self.isOwnedFile(file.lastPathComponent) {
                if file.lastPathComponent == "manifest.json" || chunks.contains(file.lastPathComponent) { continue }
                var info = stat()
                guard lstat(file.path, &info) == 0, (info.st_mode & S_IFMT) != S_IFDIR else { continue }
                guard unlink(file.path) == 0 else { throw MediaAudioDiskCacheFileError.io }
            }
        }
    }

    private func validate(_ manifest: MediaAudioDiskCacheManifest) throws {
        let created = manifest.createdAt.timeIntervalSince1970
        let expires = manifest.expiresAt.timeIntervalSince1970
        let accessed = manifest.accessedAt.timeIntervalSince1970
        guard manifest.schema == 1, Self.isUUID(manifest.id), Self.isDigest(manifest.requestKey),
            Self.isDigest(manifest.resourceKey), manifest.length > 0,
            Self.isMetadata(manifest.contentType),
            manifest.validator.map(Self.isMetadata) ?? true,
            manifest.chunks.count <= 16384, created.isFinite, expires.isFinite, accessed.isFinite,
            created < expires, expires - created <= 86400,
            accessed >= created, accessed <= expires
        else {
            throw MediaAudioDiskCacheFileError.invalid
        }
        var identifiers = Set<String>()
        var end: Int64 = 0
        for chunk in manifest.chunks {
            guard Self.isUUID(chunk.id), identifiers.insert(chunk.id).inserted,
                Self.isDigest(chunk.digest), chunk.offset >= end, chunk.count > 0,
                chunk.count <= Self.chunkLimit
            else { throw MediaAudioDiskCacheFileError.invalid }
            let (next, overflow) = chunk.offset.addingReportingOverflow(Int64(chunk.count))
            guard !overflow, next <= manifest.length else { throw MediaAudioDiskCacheFileError.invalid }
            end = next
        }
    }

    private static func isMetadata(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 8192
            && !value.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }

    private static func isUUID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func isOwnedFile(_ name: String) -> Bool {
        if name == "manifest.json" { return true }
        if name.hasSuffix(".chunk") { return isUUID(String(name.dropLast(6))) }
        if name.hasPrefix(".media-audio-"), name.hasSuffix(".tmp") {
            return isUUID(String(name.dropFirst(".media-audio-".count).dropLast(4)))
        }
        return false
    }

    private static func checkAncestors(_ url: URL) throws {
        var current = url
        while current.path != "/" {
            var info = stat()
            if lstat(current.path, &info) == 0 {
                guard (info.st_mode & S_IFMT) == S_IFDIR else { throw MediaAudioDiskCacheFileError.invalid }
            } else if errno != ENOENT {
                throw MediaAudioDiskCacheFileError.io
            }
            current.deleteLastPathComponent()
        }
    }

    private func checkRoot() throws {
        try Self.checkAncestors(root)
        try checkDirectory(root)
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_dev == rootDevice, info.st_ino == rootInode else {
            throw MediaAudioDiskCacheFileError.invalid
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    private func checkDirectory(_ url: URL) throws {
        guard isDirectory(url) else { throw MediaAudioDiskCacheFileError.invalid }
    }

    private func contents(_ url: URL) throws -> [URL] {
        do { return try manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) } catch {
            throw MediaAudioDiskCacheFileError.io
        }
    }

    private func versionDirectory(_ version: String, create: Bool) throws -> URL {
        try checkRoot()
        guard Self.isUUID(version) else { throw MediaAudioDiskCacheFileError.invalid }
        let directory = root.appendingPathComponent(version, isDirectory: true)
        if create {
            var info = stat()
            if lstat(directory.path, &info) != 0 {
                guard errno == ENOENT else { throw MediaAudioDiskCacheFileError.io }
                do { try manager.createDirectory(at: directory, withIntermediateDirectories: false) } catch {
                    throw MediaAudioDiskCacheFileError.io
                }
            }
        }
        try checkDirectory(directory)
        if create { try protect(directory) }
        return directory
    }

    private func protect(_ url: URL) throws {
        do {
            try manager.setAttributes(
                [
                    .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
                    .posixPermissions: isDirectory(url) ? 0o700 : 0o600,
                ], ofItemAtPath: url.path)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableURL = url
            try mutableURL.setResourceValues(values)
        } catch { throw MediaAudioDiskCacheFileError.io }
    }

    private func atomicWrite(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".media-audio-" + UUID().uuidString.lowercased() + ".tmp")
        defer { _ = unlink(temporary.path) }
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw MediaAudioDiskCacheFileError.io }
        defer { close(descriptor) }
        do {
            // Protect the empty temporary file before putting any media or metadata in it.
            try protect(temporary)
            let written = data.withUnsafeBytes { buffer -> Bool in
                guard let base = buffer.baseAddress else { return false }
                var position = 0
                while position < data.count {
                    let count = Darwin.write(descriptor, base.advanced(by: position), min(64 * 1024, data.count - position))
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { return false }
                    position += count
                }
                return true
            }
            guard written, fsync(descriptor) == 0 else { throw MediaAudioDiskCacheFileError.io }
            try checkRoot()
            try checkDirectory(destination.deletingLastPathComponent())
            guard rename(temporary.path, destination.path) == 0 else { throw MediaAudioDiskCacheFileError.io }
            try synchronize(destination.deletingLastPathComponent())
        } catch { throw MediaAudioDiskCacheFileError.io }
    }

    private func synchronize(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw MediaAudioDiskCacheFileError.io }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw MediaAudioDiskCacheFileError.io }
    }

    private func readFile(_ url: URL, limit: Int) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw MediaAudioDiskCacheFileError.io }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
            info.st_size > 0, info.st_size <= Int64(limit)
        else { throw MediaAudioDiskCacheFileError.invalid }
        var data = Data(count: Int(info.st_size))
        let expected = data.count
        let success = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            var position = 0
            while position < expected {
                let count = Darwin.read(descriptor, base.advanced(by: position), min(64 * 1024, expected - position))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                position += count
            }
            var extra: UInt8 = 0
            return Darwin.read(descriptor, &extra, 1) == 0
        }
        guard success else { throw MediaAudioDiskCacheFileError.invalid }
        return data
    }
}
