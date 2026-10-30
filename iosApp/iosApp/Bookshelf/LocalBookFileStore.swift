import CryptoKit
import Foundation

struct PreparedLocalBookFile: Sendable {
    let url: URL
    let wasCreated: Bool
    let leaseID: UUID?

    init(url: URL, wasCreated: Bool, leaseID: UUID? = nil) {
        self.url = url
        self.wasCreated = wasCreated
        self.leaseID = leaseID
    }
}

enum LocalBookFileStore {
    private static let queue = DispatchQueue(label: "io.legado.local-book-files", qos: .utility)
    private static let importLeases = ImportFileLeases()
    private static let archiveImportLimitGiB = 16
    private static let archiveImportByteLimit = archiveImportLimitGiB * 1024 * 1024 * 1024

    static func prepare(from url: URL) async throws -> PreparedLocalBookFile {
        try await prepareCopy(from: url, forUpload: false)
    }

    static func prepareForUpload(from url: URL) async throws -> PreparedLocalBookFile {
        try await prepareCopy(from: url, forUpload: true)
    }

    private static func prepareCopy(from url: URL, forUpload: Bool) async throws -> PreparedLocalBookFile {
        let cancellation = ImportCancellation()
        return try await withTaskCancellationHandler(
            operation: {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    queue.async {
                        do {
                            let prepared = try prepareSynchronously(
                                from: url,
                                forUpload: forUpload,
                                cancellation: cancellation
                            )
                            continuation.resume(returning: importLeases.register(prepared))
                        } catch is CancellationError {
                            continuation.resume(throwing: CancellationError())
                        } catch let error as StoreError {
                            continuation.resume(throwing: error)
                        } catch {
                            continuation.resume(throwing: StoreError.fileOperationFailed(error))
                        }
                    }
                }
            },
            onCancel: {
                cancellation.cancel()
            })
    }

    static func retain(_ file: PreparedLocalBookFile) async {
        // Ownership must also be recorded when the caller's task has been cancelled.
        await withCheckedContinuation { continuation in
            queue.async {
                _ = importLeases.finish(file, retaining: true)
                continuation.resume()
            }
        }
    }

    static func discard(_ file: PreparedLocalBookFile) async {
        // Cleanup must also run when the caller's parsing task has been cancelled.
        await withCheckedContinuation { continuation in
            queue.async {
                if file.leaseID != nil {
                    // A completed or unknown token must never fall back to legacy cleanup.
                    if let url = importLeases.finish(file, retaining: false) {
                        discardSynchronously(at: url)
                    }
                } else if file.wasCreated {
                    discardSynchronously(at: file.url)
                }
                continuation.resume()
            }
        }
    }

    private static func prepareSynchronously(
        from sourceURL: URL,
        forUpload: Bool,
        cancellation: ImportCancellation
    ) throws -> PreparedLocalBookFile {
        try cancellation.check()
        guard sourceURL.isFileURL else { throw StoreError.invalidFile }
        let fileExtension = sourceURL.pathExtension.lowercased()
        guard LocalBookFormats.importExtensions.contains(fileExtension) else { throw StoreError.unsupportedType }

        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessing { sourceURL.stopAccessingSecurityScopedResource() }
        }

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<PreparedLocalBookFile, Error>?
        // A false security-scope result is normal for files already inside the app sandbox.
        coordinator.coordinate(readingItemAt: sourceURL, options: [], error: &coordinationError) { readableURL in
            result = Result {
                try prepareCoordinatedFile(
                    at: readableURL,
                    originalURL: sourceURL,
                    fileExtension: fileExtension,
                    forUpload: forUpload,
                    cancellation: cancellation
                )
            }
        }

        // Once publication succeeds, neither cancellation nor a late coordinator error may hide it.
        if let result { return try result.get() }
        if let coordinationError { throw coordinationError }
        throw StoreError.invalidFile
    }

    private static func prepareCoordinatedFile(
        at readableURL: URL,
        originalURL: URL,
        fileExtension: String,
        forUpload: Bool,
        cancellation: ImportCancellation
    ) throws -> PreparedLocalBookFile {
        try cancellation.check()
        let fileManager = FileManager.default
        try validateFile(at: readableURL, fileManager: fileManager)
        if forUpload,
            let size = try fileManager.attributesOfItem(atPath: readableURL.path)[.size] as? NSNumber,
            size.uint64Value > 2 * 1024 * 1024 * 1024
        {
            throw StoreError.uploadTooLarge
        }
        let root = try storageRoot(fileManager: fileManager, create: true, forUpload: forUpload)
        let stagingDirectory = root.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: stagingDirectory) }

        let temporaryURL = stagingDirectory.appendingPathComponent("\(UUID().uuidString).part")
        let hash = try copyAndHash(
            from: readableURL,
            to: temporaryURL,
            fileManager: fileManager,
            cancellation: cancellation,
            byteLimit: forUpload
                ? 2 * 1024 * 1024 * 1024
                : (LocalBookArchiveType.isArchive(fileExtension: fileExtension) ? archiveImportByteLimit : nil),
            limitError: forUpload ? .uploadTooLarge : .archiveTooLarge
        )
        // Upload snapshots never share a mutable retained book or another filename's deduplicated original.
        let identity = forUpload ? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() : hash
        let directory = root.appendingPathComponent("\(fileExtension)-\(identity)", isDirectory: true)
        try cancellation.check()
        if let existing = try existingFile(in: directory, fileExtension: fileExtension, fileManager: fileManager) {
            return PreparedLocalBookFile(url: existing, wasCreated: false)
        }

        let filename = safeFilename(from: originalURL)
        try fileManager.moveItem(at: temporaryURL, to: stagingDirectory.appendingPathComponent(filename))
        try cancellation.check()
        do {
            // Both directories have the same parent: publish the complete file with one atomic rename.
            // moveItem refuses an existing destination; never replace a previously imported book.
            try fileManager.moveItem(at: stagingDirectory, to: directory)
        } catch {
            if let existing = try existingFile(in: directory, fileExtension: fileExtension, fileManager: fileManager) {
                try cancellation.check()
                return PreparedLocalBookFile(url: existing, wasCreated: false)
            }
            throw error
        }

        // There must be no throwing work or cancellation check after the successful move.
        return PreparedLocalBookFile(url: directory.appendingPathComponent(filename), wasCreated: true)
    }

    private static func copyAndHash(
        from source: URL,
        to destination: URL,
        fileManager: FileManager,
        cancellation: ImportCancellation,
        byteLimit: Int? = nil,
        limitError: StoreError = .archiveTooLarge
    ) throws -> String {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard fileManager.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw StoreError.cannotCreateFile
        }
        let output = try FileHandle(forWritingTo: destination)
        var outputClosed = false
        defer {
            if outputClosed == false { try? output.close() }
        }

        var hasher = SHA256()
        var copiedAnyBytes = false
        var copiedBytes = 0
        while true {
            try cancellation.check()
            let copiedChunk = try autoreleasepool {
                let data = try input.read(upToCount: 1024 * 1024) ?? Data()
                guard data.isEmpty == false else { return false }
                copiedBytes += data.count
                if let byteLimit, copiedBytes > byteLimit { throw limitError }
                try cancellation.check()
                try output.write(contentsOf: data)
                hasher.update(data: data)
                return true
            }
            guard copiedChunk else { break }
            copiedAnyBytes = true
        }
        guard copiedAnyBytes else { throw StoreError.emptyFile }
        try cancellation.check()
        try output.synchronize()
        try output.close()
        outputClosed = true
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func validateFile(at url: URL, fileManager: FileManager) throws {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw StoreError.invalidFile }
        guard let size = attributes[.size] as? NSNumber, size.uint64Value > 0 else { throw StoreError.emptyFile }
    }

    private static func existingFile(
        in directory: URL,
        fileExtension: String,
        fileManager: FileManager
    ) throws -> URL? {
        guard fileManager.fileExists(atPath: directory.path) else { return nil }
        let attributes = try fileManager.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw StoreError.invalidStorage }
        let files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard files.count == 1, let file = files.first,
            file.pathExtension.lowercased() == fileExtension
        else { throw StoreError.invalidStorage }
        try validateFile(at: file, fileManager: fileManager)
        return file
    }

    private static func storageRoot(fileManager: FileManager, create: Bool, forUpload: Bool = false) throws -> URL {
        let root = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: create
        ).appendingPathComponent(forUpload ? "LocalBookUploadCopies" : "LocalBooks", isDirectory: true)
        if create { try fileManager.createDirectory(at: root, withIntermediateDirectories: true) }
        return root
    }

    private static func safeFilename(from url: URL) -> String {
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        let stem = url.deletingPathExtension().lastPathComponent.unicodeScalars.map { scalar in
            forbidden.contains(scalar) ? "_" : String(scalar)
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        let suffix = ".\(url.pathExtension)"
        let byteLimit = 240 - suffix.utf8.count
        var shortened = ""
        var byteCount = 0
        for character in stem {
            let count = String(character).utf8.count
            guard byteCount + count <= byteLimit else { break }
            shortened.append(character)
            byteCount += count
        }
        return (shortened.isEmpty ? "LocalBook" : shortened) + suffix
    }

    private static func discardSynchronously(at fileURL: URL) {
        let fileManager = FileManager.default
        guard let root = try? storageRoot(fileManager: fileManager, create: false),
            let uploads = try? storageRoot(fileManager: fileManager, create: false, forUpload: true)
        else { return }
        let url = fileURL.standardizedFileURL
        let directory = url.deletingLastPathComponent()
        let parent = directory.deletingLastPathComponent()
        let isUpload = parent == uploads.standardizedFileURL
        guard url.isFileURL, isUpload || parent == root.standardizedFileURL
        else { return }
        let parts = directory.lastPathComponent.split(separator: "-", maxSplits: 1)
        guard parts.count == 2, LocalBookFormats.importExtensions.contains(String(parts[0])),
            url.pathExtension.lowercased() == String(parts[0]),
            parts[1].count == (isUpload ? 32 : 64),
            parts[1].allSatisfy({ "0123456789abcdef".contains($0) }),
            let directoryAttributes = try? fileManager.attributesOfItem(atPath: directory.path),
            directoryAttributes[.type] as? FileAttributeType == .typeDirectory,
            let attributes = try? fileManager.attributesOfItem(atPath: url.path),
            attributes[.type] as? FileAttributeType == .typeRegular
        else { return }

        do {
            try fileManager.removeItem(at: url)
            if try fileManager.contentsOfDirectory(atPath: directory.path).isEmpty {
                try fileManager.removeItem(at: directory)
            }
        } catch {
            // Best-effort rollback; never remove the root or recursively remove a nonempty book directory.
        }
    }

    // Mutable lease state is accessed only on LocalBookFileStore.queue.
    private final class ImportFileLeases: @unchecked Sendable {
        private struct DirectoryLease {
            let fileURL: URL
            var activeLeaseIDs: Set<UUID> = []
            var wasCreatedInGroup = false
            var hasSuccessfulRetain = false
        }

        private var directories: [URL: DirectoryLease] = [:]

        func register(_ file: PreparedLocalBookFile) -> PreparedLocalBookFile {
            let url = file.url.standardizedFileURL
            let directory = url.deletingLastPathComponent()
            let leaseID = UUID()
            var lease = directories[directory] ?? DirectoryLease(fileURL: url)
            lease.activeLeaseIDs.insert(leaseID)
            lease.wasCreatedInGroup = lease.wasCreatedInGroup || file.wasCreated
            directories[directory] = lease
            return PreparedLocalBookFile(url: file.url, wasCreated: file.wasCreated, leaseID: leaseID)
        }

        func finish(_ file: PreparedLocalBookFile, retaining: Bool) -> URL? {
            guard let leaseID = file.leaseID else { return nil }
            let directory = file.url.standardizedFileURL.deletingLastPathComponent()
            guard var lease = directories[directory],
                lease.activeLeaseIDs.remove(leaseID) != nil
            else { return nil }

            lease.hasSuccessfulRetain = lease.hasSuccessfulRetain || retaining
            guard lease.activeLeaseIDs.isEmpty else {
                directories[directory] = lease
                return nil
            }

            directories.removeValue(forKey: directory)
            guard lease.wasCreatedInGroup, lease.hasSuccessfulRetain == false else { return nil }
            return lease.fileURL
        }
    }

    private final class ImportCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var isCancelled = false

        func cancel() {
            lock.lock()
            isCancelled = true
            lock.unlock()
        }

        func check() throws {
            lock.lock()
            let cancelled = isCancelled
            lock.unlock()
            if cancelled { throw CancellationError() }
        }
    }

    private enum StoreError: LocalizedError {
        case unsupportedType
        case invalidFile
        case emptyFile
        case invalidStorage
        case cannotCreateFile
        case archiveTooLarge
        case uploadTooLarge
        case fileOperationFailed(Error)

        var errorDescription: String? {
            switch self {
            case .unsupportedType: return LocalBookFormats.unsupportedMessage
            case .invalidFile: return "请选择有效的常规文件"
            case .emptyFile: return "不能导入空文件"
            case .invalidStorage: return "本地书籍目录异常，无法导入"
            case .cannotCreateFile: return "无法创建本地书籍文件"
            case .archiveTooLarge: return "压缩包超过 \(LocalBookFileStore.archiveImportLimitGiB) GiB，无法导入"
            case .uploadTooLarge: return "上传文件超过 2 GiB 限制"
            case .fileOperationFailed: return "本地文件导入失败，请重试"
            }
        }
    }
}
