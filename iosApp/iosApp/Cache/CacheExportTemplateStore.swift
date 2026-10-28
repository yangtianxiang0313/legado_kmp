import CryptoKit
import Darwin
import Foundation

struct CacheExportTemplateSnapshot: Equatable, Sendable {
    let archive: Data
    let name: String

    var base64Zip: String { archive.base64EncodedString() }

    init(archive: Data, name: String) throws {
        guard !archive.isEmpty, archive.count <= CacheExportTemplateStore.maximumArchiveBytes else {
            throw CacheExportTemplateError.invalidSize
        }
        guard archive.starts(with: [0x50, 0x4b, 0x03, 0x04]) else {
            throw CacheExportTemplateError.invalidArchive
        }
        self.archive = archive
        self.name = Self.safeName(name)
    }

    private static func safeName(_ value: String) -> String {
        let leaf = (value.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        let cleaned = leaf.unicodeScalars.map { forbidden.contains($0) ? "_" : String($0) }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var name = ""
        for character in cleaned {
            guard name.utf8.count + String(character).utf8.count <= 240 else { break }
            name.append(character)
        }
        return name.isEmpty || name == "." || name == ".." ? "EPUB 模板.zip" : name
    }
}

enum CacheExportTemplateError: LocalizedError {
    case invalidSize, invalidArchive, invalidStorage, unavailable, busy

    var errorDescription: String? {
        switch self {
        case .invalidSize: return "模板 ZIP 不能为空，且不能超过 32 MiB"
        case .invalidArchive: return "模板文件已损坏或不是有效的 ZIP"
        case .invalidStorage: return "模板存储位置不是安全的普通文件或目录"
        case .unavailable: return "自定义模板缺失或损坏，无法导出"
        case .busy: return "模板仍在处理中，请稍后重试"
        }
    }
}

/// Only the archive bytes and display name are persisted, never a document-provider URL.
struct CacheExportTemplateStore: Sendable {
    static let maximumArchiveBytes = 32 * 1024 * 1024
    static let maximumBase64Bytes = ((maximumArchiveBytes + 2) / 3) * 4
    private static let maximumRecordBytes = maximumArchiveBytes + 4096

    static var standardDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .resolvingSymlinksInPath().appendingPathComponent("CacheExportTemplates", isDirectory: true)
    }

    private let directory: URL?

    init(directory: URL? = CacheExportTemplateStore.standardDirectory) {
        guard let directory, directory.isFileURL else {
            self.directory = nil
            return
        }
        let normalized = directory.standardizedFileURL
        // Canonicalize the parent (including the system /var alias), not the owned directory itself.
        self.directory = normalized.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(normalized.lastPathComponent, isDirectory: true)
    }

    func load() throws -> CacheExportTemplateSnapshot? {
        guard let directory = try storageDirectory(create: false) else { return nil }
        let file = directory.appendingPathComponent("selected-template.plist")
        guard try Self.attributesIfPresent(at: file) != nil else { return nil }
        let data = try Self.readRegularFile(at: file, maximumBytes: Self.maximumRecordBytes)
        let record = try PropertyListDecoder().decode(Record.self, from: data)
        let snapshot = try CacheExportTemplateSnapshot(archive: record.archive, name: record.name)
        guard record.version == 1, snapshot.name == record.name,
            record.sha256 == Self.digest(record.archive)
        else { throw CacheExportTemplateError.invalidArchive }
        return snapshot
    }

    /// Nothing that can throw follows the atomic publication of the complete record.
    func commit(_ snapshot: CacheExportTemplateSnapshot) throws {
        let checked = try CacheExportTemplateSnapshot(archive: snapshot.archive, name: snapshot.name)
        let record = Record(version: 1, archive: checked.archive, name: checked.name, sha256: Self.digest(checked.archive))
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(record)
        guard data.count <= Self.maximumRecordBytes else { throw CacheExportTemplateError.invalidSize }
        guard let directory = try storageDirectory(create: true) else { throw CacheExportTemplateError.invalidStorage }
        let file = directory.appendingPathComponent("selected-template.plist")
        if let attributes = try Self.attributesIfPresent(at: file),
            attributes[.type] as? FileAttributeType != .typeRegular
        {
            throw CacheExportTemplateError.invalidStorage
        }
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func storageDirectory(create: Bool) throws -> URL? {
        guard let directory, directory.isFileURL,
            directory.resolvingSymlinksInPath() == directory
        else { throw CacheExportTemplateError.invalidStorage }
        if let attributes = try Self.attributesIfPresent(at: directory) {
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw CacheExportTemplateError.invalidStorage
            }
        } else if create {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700, .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        } else {
            return nil
        }
        guard directory.resolvingSymlinksInPath() == directory else { throw CacheExportTemplateError.invalidStorage }
        return directory
    }

    // O_NOFOLLOW and fstat also cover a symlink substitution between metadata lookup and open.
    static func readRegularFile(at url: URL, maximumBytes: Int) throws -> Data {
        guard url.isFileURL else { throw CacheExportTemplateError.invalidStorage }
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(descriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
            throw CacheExportTemplateError.invalidStorage
        }
        guard status.st_size > 0, status.st_size <= Int64(maximumBytes) else {
            throw CacheExportTemplateError.invalidSize
        }
        var data = Data()
        while true {
            let chunk = try handle.read(upToCount: min(64 * 1024, maximumBytes - data.count + 1)) ?? Data()
            if chunk.isEmpty { break }
            guard chunk.count <= maximumBytes - data.count else { throw CacheExportTemplateError.invalidSize }
            data.append(chunk)
        }
        guard data.count == Int(status.st_size) else { throw CacheExportTemplateError.invalidArchive }
        try handle.close()
        return data
    }

    private static func attributesIfPresent(at url: URL) throws -> [FileAttributeKey: Any]? {
        do {
            return try FileManager.default.attributesOfItem(atPath: url.path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch let error as POSIXError where error.code == .ENOENT {
            return nil
        }
    }

    private static func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    private struct Record: Codable {
        let version: Int
        let archive: Data
        let name: String
        let sha256: Data
    }
}
