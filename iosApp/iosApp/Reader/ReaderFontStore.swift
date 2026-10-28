import CoreText
import CryptoKit
import Foundation
import UIKit

struct ReaderFontEntry: Equatable {
    let identifier: String
    let title: String
    let postScriptName: String
}

final class ReaderFontStore {
    static let shared = ReaderFontStore(
        directoryURL: (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support"))
            .appendingPathComponent(
                "ReaderFonts", isDirectory: true))

    // Registration is process-wide, including stores created for temporary diagnostics.
    private static let lock = NSLock()
    private static var registrations: [String: Registration] = [:]
    private static var pendingImports: [String: PendingImport] = [:]
    private static let prefix = "reader-font:"
    private static let fontLimit = 64 * 1024 * 1024
    private static let catalogLimit = 4 * 1024 * 1024

    private let directoryURL: URL
    private var catalogState: Result<Catalog, StoreError>?
    private var catalogStamp: FileStamp?
    private var cache: [String: CachedFont] = [:]
    private var catalogURL: URL { directoryURL.appendingPathComponent("catalog.json") }

    init(directoryURL: URL) {
        self.directoryURL = directoryURL.standardizedFileURL
    }

    func entries() throws -> [ReaderFontEntry] {
        try locked {
            try loadCatalog().fonts.compactMap { record in
                (try? descriptor(for: record)) == nil ? nil : record.entry
            }.sorted {
                let order = $0.title.localizedStandardCompare($1.title)
                return order == .orderedSame ? $0.identifier < $1.identifier : order == .orderedAscending
            }
        }
    }

    // This synchronous API should be called on a worker queue, especially for large CJK fonts.
    func importFont(from url: URL) throws -> ReaderFontEntry {
        try importFont(from: url, leaseID: nil)
    }

    func leaseFontImport(from url: URL) throws -> ImportLease {
        let id = UUID()
        let entry = try importFont(from: url, leaseID: id)
        return ImportLease(store: self, entry: entry, id: id)
    }

    func leaseFont(for identifier: String) throws -> ImportLease {
        try locked {
            guard let token = ReaderFontSelectionToken(identifier: identifier),
                let record = try loadCatalog().fonts.first(where: { $0.identifier == token.catalogIdentifier })
            else { throw StoreError.unavailable }
            let id = UUID()
            hold(record, leaseID: id, newlyCreated: false)
            return ImportLease(store: self, entry: record.entry, id: id)
        }
    }

    private func importFont(from url: URL, leaseID: UUID?) throws -> ReaderFontEntry {
        guard url.isFileURL else { throw StoreError.invalidFile }
        let fileExtension = url.pathExtension.lowercased()
        guard ["ttf", "otf"].contains(fileExtension) else { throw StoreError.unsupportedType }
        do {
            let data = try coordinatedData(from: url)
            let postScriptName = try inspect(data)
            let digest = Self.digest(data)
            return try locked {
                let catalog = try loadCatalog()
                if let existing = catalog.fonts.first(where: { $0.sha256 == digest }) {
                    guard existing.postScriptName == postScriptName else { throw StoreError.invalidCatalog }
                    do {
                        _ = try descriptor(for: existing)
                    } catch let error as StoreError {
                        switch error {
                        case .nameConflict, .registration: throw error
                        default: break
                        }
                        // A duplicate can repair a missing or damaged local copy without changing its token.
                        try data.write(to: fileURL(for: existing), options: .atomic)
                        cache.removeValue(forKey: existing.identifier)
                        _ = try descriptor(for: existing)
                    }
                    hold(existing, leaseID: leaseID, newlyCreated: false)
                    return existing.entry
                }
                guard !catalog.fonts.contains(where: { $0.postScriptName == postScriptName }) else {
                    throw StoreError.nameConflict(postScriptName)
                }
                let identifier = Self.prefix + UUID().uuidString
                let originalFilename = url.lastPathComponent
                var title = originalFilename
                var suffix = 2
                while catalog.fonts.contains(where: { $0.title.localizedStandardCompare(title) == .orderedSame }) {
                    title = "\(originalFilename) (\(suffix))"
                    suffix += 1
                }
                let record = Record(
                    identifier: identifier, title: title, originalFilename: originalFilename,
                    postScriptName: postScriptName, sha256: digest, fileExtension: fileExtension)
                let entry = try publish(record, data: data, catalog: catalog)
                hold(record, leaseID: leaseID, newlyCreated: true)
                return entry
            }
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.fileOperation(error.localizedDescription)
        }
    }

    func font(for identifier: String, size: CGFloat) -> UIFont? {
        guard let token = ReaderFontSelectionToken(identifier: identifier), size.isFinite, size > 0 else { return nil }
        return locked {
            guard let record = try? loadCatalog().fonts.first(where: { $0.identifier == token.catalogIdentifier }),
                let descriptor = try? descriptor(for: record),
                let registered = Self.registrations[record.postScriptName]
            else { return nil }
            let font = UIFont(descriptor: descriptor, size: size)
            guard font.fontName == record.postScriptName,
                let source = CTFontCopyAttribute(font as CTFont, kCTFontURLAttribute) as? URL,
                source.standardizedFileURL == registered.sourceURL
            else { return nil }
            // A consumer can select a font while a ZIP import is still awaiting shared persistence.
            retain(record)
            return font
        }
    }

    func title(for identifier: String) -> String? {
        guard let token = ReaderFontSelectionToken(identifier: identifier) else { return nil }
        return locked {
            guard let record = try? loadCatalog().fonts.first(where: { $0.identifier == token.catalogIdentifier }) else {
                return nil
            }
            return token.filename ?? record.title
        }
    }

    func originalFilename(for identifier: String) -> String? {
        guard let token = ReaderFontSelectionToken(identifier: identifier) else { return nil }
        return locked {
            guard let record = try? loadCatalog().fonts.first(where: { $0.identifier == token.catalogIdentifier }) else {
                return nil
            }
            return token.filename ?? record.originalFilename
        }
    }

    func selectionIdentifier(for identifier: String, filename: String) throws -> String {
        try selectionIdentifier(for: identifier, filename: filename, retaining: true)
    }

    private func selectionIdentifier(for identifier: String, filename: String, retaining: Bool) throws -> String {
        try locked {
            guard let token = ReaderFontSelectionToken(identifier: identifier),
                let record = try loadCatalog().fonts.first(where: { $0.identifier == token.catalogIdentifier }),
                let selection = ReaderFontSelectionToken.preservingFilename(filename, for: record.identifier)
            else { throw StoreError.invalidFile }
            _ = try descriptor(for: record)
            if retaining { retain(record) }
            return filename.utf8.elementsEqual(record.originalFilename.utf8) ? record.identifier : selection
        }
    }

    final class ImportLease {
        let entry: ReaderFontEntry
        private let store: ReaderFontStore
        private let id: UUID

        fileprivate init(store: ReaderFontStore, entry: ReaderFontEntry, id: UUID) {
            self.store = store
            self.entry = entry
            self.id = id
        }

        func selectionIdentifier(filename: String) throws -> String {
            try store.selectionIdentifier(for: entry.identifier, filename: filename, retaining: false)
        }

        func commit() {
            store.locked {
                guard let pending = ReaderFontStore.pendingImports[entry.postScriptName], pending.leases.contains(id) else {
                    return
                }
                ReaderFontStore.pendingImports.removeValue(forKey: entry.postScriptName)
            }
        }

        func rollback() throws {
            try store.locked {
                guard let pending = ReaderFontStore.pendingImports[entry.postScriptName], pending.leases.contains(id) else {
                    return
                }
                if pending.leases.count > 1 {
                    pending.leases.remove(id)
                    return
                }
                // Keep the last lease retryable if a catalog, unregister or file operation fails.
                try store.rollback(pending, postScriptName: entry.postScriptName)
                ReaderFontStore.pendingImports.removeValue(forKey: entry.postScriptName)
            }
        }

        deinit {
            do { try rollback() } catch { NSLog("ReaderFontStore rollback: %@", error.localizedDescription) }
        }
    }

    private func hold(_ record: Record, leaseID: UUID?, newlyCreated: Bool) {
        guard let leaseID else {
            retain(record)
            return
        }
        let url = fileURL(for: record).resolvingSymlinksInPath().standardizedFileURL
        if newlyCreated {
            let pending = Self.pendingImports[record.postScriptName] ?? PendingImport(sha256: record.sha256)
            pending.resources[url] = PendingResource(store: self, record: record)
            pending.leases.insert(leaseID)
            Self.pendingImports[record.postScriptName] = pending
        } else if let pending = Self.pendingImports[record.postScriptName] {
            if pending.resources[url] != nil {
                pending.leases.insert(leaseID)
            } else {
                // An existing catalog also owns a reused process-wide registration.
                retain(record)
            }
        }
    }

    private func retain(_ record: Record) {
        if Self.pendingImports[record.postScriptName]?.sha256 == record.sha256 {
            Self.pendingImports.removeValue(forKey: record.postScriptName)
        }
    }

    private func rollback(_ pending: PendingImport, postScriptName: String) throws {
        // A registration may be shared by multiple stores. Keep every temporary source until
        // all leases settle, and never unregister a source from a pre-existing catalog.
        for resource in pending.resources.values {
            let store = resource.store
            let catalog = try store.loadCatalog()
            if let existing = catalog.fonts.first(where: { $0.identifier == resource.record.identifier }) {
                guard existing == resource.record else { throw StoreError.invalidCatalog }
                try store.saveCatalog(Catalog(version: catalog.version, fonts: catalog.fonts.filter { $0 != existing }))
            }
            store.cache.removeValue(forKey: resource.record.identifier)
        }
        if let registered = Self.registrations[postScriptName], registered.sha256 == pending.sha256,
            pending.resources[registered.url.resolvingSymlinksInPath().standardizedFileURL] != nil
        {
            var error: Unmanaged<CFError>?
            guard CTFontManagerUnregisterFontsForURL(registered.url as CFURL, .process, &error) else {
                let detail = error.map { CFErrorCopyDescription($0.takeRetainedValue()) as String } ?? postScriptName
                throw StoreError.fileOperation("撤销字体注册失败：\(detail)")
            }
            Self.registrations.removeValue(forKey: postScriptName)
        }
        for resource in pending.resources.values {
            do {
                try FileManager.default.removeItem(at: resource.store.fileURL(for: resource.record))
            } catch {
                let value = error as NSError
                guard value.domain == NSCocoaErrorDomain,
                    [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(value.code)
                else { throw error }
            }
        }
    }

    /// Export only an imported file owned by this catalog, never a platform font.
    func exportResource(for identifier: String) throws -> (name: String, data: Data) {
        try locked {
            guard let token = ReaderFontSelectionToken(identifier: identifier),
                let record = try loadCatalog().fonts.first(where: { $0.identifier == token.catalogIdentifier })
            else {
                throw StoreError.unavailable
            }
            _ = try descriptor(for: record)
            return (token.filename ?? record.originalFilename, try readData(at: fileURL(for: record), limit: Self.fontLimit))
        }
    }

    static func ownsSource(of font: UIFont) -> Bool {
        guard let source = CTFontCopyAttribute(font as CTFont, kCTFontURLAttribute) as? URL else { return false }
        let normalized = source.standardizedFileURL
        lock.lock()
        defer { lock.unlock() }
        // Variable named instances can have a different PostScript name in the same imported file.
        return registrations.values.contains { $0.sourceURL == normalized }
    }

    private func publish(_ record: Record, data: Data, catalog: Catalog) throws -> ReaderFontEntry {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let destination = fileURL(for: record)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw StoreError.fileOperation("字体存储文件已存在，请重试。")
        }
        var committed = false
        defer {
            if !committed {
                cache.removeValue(forKey: record.identifier)
                if Self.registrations[record.postScriptName]?.url == destination {
                    Self.registrations.removeValue(forKey: record.postScriptName)
                    CTFontManagerUnregisterFontsForURL(destination as CFURL, .process, nil)
                }
                try? FileManager.default.removeItem(at: destination)
            }
        }
        try data.write(to: destination, options: .atomic)
        let stamp = try fileStamp(at: destination, limit: Self.fontLimit)
        let descriptor = try register(record, at: destination)
        let updated = Catalog(version: 1, fonts: catalog.fonts + [record])
        try saveCatalog(updated)
        // Nothing after the catalog commit may throw or report the import as failed.
        cache[record.identifier] = CachedFont(stamp: stamp, result: .success(descriptor))
        committed = true
        return record.entry
    }

    private func saveCatalog(_ catalog: Catalog) throws {
        let encoded = try JSONEncoder().encode(catalog)
        guard encoded.count <= Self.catalogLimit else { throw StoreError.catalogFull }
        try encoded.write(to: catalogURL, options: .atomic)
        catalogState = .success(catalog)
        catalogStamp = try? fileStamp(at: catalogURL, limit: Self.catalogLimit)
    }

    private func loadCatalog() throws -> Catalog {
        guard directoryURL.isFileURL else { throw StoreError.invalidCatalog }
        let stamp: FileStamp?
        do {
            stamp = try fileStamp(at: catalogURL, limit: Self.catalogLimit)
        } catch {
            let error = error as NSError
            guard error.domain == NSCocoaErrorDomain,
                [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)
            else { throw StoreError.invalidCatalog }
            stamp = nil
        }
        if let catalogState, catalogStamp == stamp { return try catalogState.get() }
        let result: Result<Catalog, StoreError>
        do {
            let catalog: Catalog
            if stamp == nil {
                catalog = Catalog(version: 1, fonts: [])
            } else {
                catalog = try JSONDecoder().decode(Catalog.self, from: readData(at: catalogURL, limit: Self.catalogLimit))
                var identifiers = Set<String>()
                var hashes = Set<String>()
                guard catalog.version == 1,
                    catalog.fonts.allSatisfy({ record in
                        record.isValid && identifiers.insert(record.identifier).inserted && hashes.insert(record.sha256).inserted
                    })
                else { throw StoreError.invalidCatalog }
            }
            result = .success(catalog)
        } catch {
            result = .failure(.invalidCatalog)
        }
        catalogState = result
        catalogStamp = stamp
        cache.removeAll()
        return try result.get()
    }

    private func descriptor(for record: Record) throws -> UIFontDescriptor {
        let url = fileURL(for: record)
        let stamp = try? fileStamp(at: url, limit: Self.fontLimit)
        if let cached = cache[record.identifier], cached.stamp == stamp { return try cached.result.get() }
        let result: Result<UIFontDescriptor, StoreError>
        do {
            guard stamp != nil else { throw StoreError.unavailable }
            let data = try readData(at: url, limit: Self.fontLimit)
            guard Self.digest(data) == record.sha256, try inspect(data) == record.postScriptName,
                try fileStamp(at: url, limit: Self.fontLimit) == stamp
            else { throw StoreError.invalidFont }
            result = .success(try register(record, at: url))
        } catch let error as StoreError {
            result = .failure(error)
        } catch {
            result = .failure(.unavailable)
        }
        cache[record.identifier] = CachedFont(stamp: stamp, result: result)
        return try result.get()
    }

    private func register(_ record: Record, at url: URL) throws -> UIFontDescriptor {
        if let registered = Self.registrations[record.postScriptName] {
            guard registered.sha256 == record.sha256,
                Self.registeredFont(named: record.postScriptName, at: registered.url) != nil
            else { throw StoreError.nameConflict(record.postScriptName) }
            return registered.descriptor
        }
        // Never interpret "already registered" as success: it may be another font with the same name.
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
            !descriptors.isEmpty
        else {
            throw StoreError.invalidFont
        }
        // A variable font registers all named instances, not only its default face.
        let names = descriptors.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String }
        guard names.count == descriptors.count, names.contains(record.postScriptName) else { throw StoreError.invalidFont }
        // UIKit can still return a cached font after a successful CoreText unregister.
        let available = Set(CTFontManagerCopyAvailablePostScriptNames() as? [String] ?? [])
        for name in names where available.contains(name) {
            throw StoreError.nameConflict(name)
        }
        var error: Unmanaged<CFError>?
        guard CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) else {
            let detail = error.map { CFErrorCopyDescription($0.takeRetainedValue()) as String } ?? record.postScriptName
            CTFontManagerUnregisterFontsForURL(url as CFURL, .process, nil)
            throw StoreError.registration(detail)
        }
        guard let font = Self.registeredFont(named: record.postScriptName, at: url),
            let source = CTFontCopyAttribute(font as CTFont, kCTFontURLAttribute) as? URL
        else {
            CTFontManagerUnregisterFontsForURL(url as CFURL, .process, nil)
            throw StoreError.nameConflict(record.postScriptName)
        }
        let descriptor = font.fontDescriptor
        Self.registrations[record.postScriptName] = Registration(
            sha256: record.sha256, url: url, sourceURL: source.standardizedFileURL, descriptor: descriptor
        )
        return descriptor
    }

    private static func registeredFont(named name: String, at url: URL) -> UIFont? {
        guard (CTFontManagerCopyAvailablePostScriptNames() as? [String])?.contains(name) == true,
            let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
            let descriptor = descriptors.first(where: {
                CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String == name
            })
        else { return nil }
        let font = CTFontCreateWithFontDescriptor(descriptor, 12, nil) as UIFont
        guard font.fontName == name,
            let source = CTFontCopyAttribute(font as CTFont, kCTFontURLAttribute) as? URL,
            source.resolvingSymlinksInPath().standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL
        else { return nil }
        return font
    }

    private func inspect(_ data: Data) throws -> String {
        let signature = Array(data.prefix(4))
        guard signature == [0, 1, 0, 0] || signature == Array("OTTO".utf8) || signature == Array("true".utf8) else {
            throw StoreError.invalidFont
        }
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor],
            !descriptors.isEmpty,
            let provider = CGDataProvider(data: data as CFData), let graphicsFont = CGFont(provider),
            graphicsFont.numberOfGlyphs > 0, let name = graphicsFont.postScriptName as String?, !name.isEmpty,
            descriptors.contains(where: { CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String == name })
        else { throw StoreError.invalidFont }
        return name
    }

    private func coordinatedData(from url: URL) throws -> Data {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
            result = Result { try readData(at: readable, limit: Self.fontLimit) }
        }
        if let coordinationError { throw StoreError.fileOperation(coordinationError.localizedDescription) }
        guard let result else { throw StoreError.invalidFile }
        return try result.get()
    }

    private func readData(at url: URL, limit: Int) throws -> Data {
        _ = try fileStamp(at: url, limit: limit)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(1024 * 1024, limit - data.count + 1)), !chunk.isEmpty {
            guard data.count + chunk.count <= limit else { throw StoreError.tooLarge }
            data.append(chunk)
        }
        guard !data.isEmpty else { throw StoreError.emptyFile }
        return data
    }

    private func fileStamp(at url: URL, limit: Int) throws -> FileStamp {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw StoreError.invalidFile }
        guard let size = attributes[.size] as? NSNumber, size.uint64Value > 0 else { throw StoreError.emptyFile }
        guard size.uint64Value <= UInt64(limit) else { throw StoreError.tooLarge }
        guard let modified = attributes[.modificationDate] as? Date,
            let number = attributes[.systemFileNumber] as? NSNumber
        else { throw StoreError.invalidFile }
        return FileStamp(size: size.uint64Value, modified: modified, number: number.uint64Value)
    }

    private func fileURL(for record: Record) -> URL {
        directoryURL.appendingPathComponent(String(record.identifier.dropFirst(Self.prefix.count)) + "." + record.fileExtension)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return try body()
    }

    private struct Catalog: Codable {
        let version: Int
        let fonts: [Record]
    }

    private struct Record: Codable, Equatable {
        let identifier: String
        let title: String
        let originalFilename: String
        let postScriptName: String
        let sha256: String
        let fileExtension: String

        var entry: ReaderFontEntry {
            ReaderFontEntry(identifier: identifier, title: title, postScriptName: postScriptName)
        }

        var isValid: Bool {
            identifier.hasPrefix(ReaderFontStore.prefix)
                && UUID(uuidString: String(identifier.dropFirst(ReaderFontStore.prefix.count)))?.uuidString
                    == String(identifier.dropFirst(ReaderFontStore.prefix.count))
                && ["ttf", "otf"].contains(fileExtension) && !title.isEmpty && !postScriptName.isEmpty
                && !originalFilename.isEmpty && (originalFilename as NSString).lastPathComponent == originalFilename
                && sha256.utf8.count == 64 && sha256.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
    }

    private struct FileStamp: Equatable {
        let size: UInt64
        let modified: Date
        let number: UInt64
    }

    private struct CachedFont {
        let stamp: FileStamp?
        let result: Result<UIFontDescriptor, StoreError>
    }

    private struct Registration {
        let sha256: String
        let url: URL
        let sourceURL: URL
        let descriptor: UIFontDescriptor
    }

    private final class PendingImport {
        let sha256: String
        var leases: Set<UUID> = []
        var resources: [URL: PendingResource] = [:]

        init(sha256: String) { self.sha256 = sha256 }
    }

    private struct PendingResource {
        let store: ReaderFontStore
        let record: Record
    }

    private enum StoreError: LocalizedError {
        case invalidFile, unsupportedType, emptyFile, tooLarge, invalidFont, unavailable, invalidCatalog, catalogFull
        case nameConflict(String)
        case registration(String)
        case fileOperation(String)

        var errorDescription: String? {
            switch self {
            case .invalidFile: return "请选择可读取的字体文件，不能导入目录或文件链接。"
            case .unsupportedType: return "仅支持导入 TTF 或 OTF 字体文件。"
            case .emptyFile: return "字体文件为空，请重新选择。"
            case .tooLarge: return "字体文件过大，最多支持 64 MiB。"
            case .invalidFont: return "文件不是有效的 TTF/OTF，或字体格式不受支持。"
            case .unavailable: return "字体文件已丢失或无法读取，请重新导入。"
            case .invalidCatalog: return "字体目录记录损坏或无法读取，为保护已有字体，未覆盖原记录。"
            case .catalogFull: return "字体目录记录过大，无法继续导入。"
            case .nameConflict(let name): return "字体内部名称“\(name)”与已有字体冲突，请选择内部名称不同的字体。"
            case .registration(let reason): return "字体注册失败，可能与已有字体重名：\(reason)"
            case .fileOperation(let reason): return "无法读取或保存字体：\(reason)"
            }
        }
    }
}
