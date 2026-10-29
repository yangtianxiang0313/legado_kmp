import Darwin
import Foundation
import shared

enum SettingsBackupFilePreparation {
    struct PreparedBackupFile: Sendable {
        let data: Data
        let isZip: Bool
        let needsPassword: Bool
        let jsonPayload: String?
    }

    private static let maximumBytes = 128 * 1024 * 1024
    private static let chunkBytes = 64 * 1024
    private static let queue = DispatchQueue(label: "io.legado.settings.backup-file-preparation", qos: .userInitiated)

    static func prepare(url: URL) async throws -> PreparedBackupFile {
        let cancellation = CancellationState()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result: Result<PreparedBackupFile, Error> = await withCheckedContinuation { continuation in
                queue.async {
                    let result = autoreleasepool {
                        Result { try prepareSynchronously(url: url, cancellation: cancellation) }
                    }
                    // Only the worker resumes, after its file handle and security scope have been released.
                    continuation.resume(returning: result)
                }
            }
            try Task.checkCancellation()
            return try result.get()
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func prepareSynchronously(url: URL, cancellation: CancellationState) throws -> PreparedBackupFile {
        try cancellation.check()
        guard url.isFileURL else { throw PreparationError.invalidFile }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        try cancellation.check()

        let coordinator = NSFileCoordinator(filePresenter: nil)
        try cancellation.register(coordinator)
        defer { cancellation.unregister(coordinator) }
        var coordinationError: NSError?
        var result: Result<PreparedBackupFile, Error>?
        coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { readableURL in
            result = Result {
                try cancellation.check()
                let data = try readRegularFile(at: readableURL, cancellation: cancellation)
                let isZip = url.pathExtension.lowercased() == "zip" || data.starts(with: [0x50, 0x4b, 0x03, 0x04])
                let needsPassword: Bool
                let jsonPayload: String?
                if isZip {
                    needsPassword = true
                    jsonPayload = nil
                } else {
                    try cancellation.check()
                    guard let payload = String(data: data, encoding: .utf8) else { throw PreparationError.invalidUTF8 }
                    try cancellation.check()
                    needsPassword = try BackupCredentialCodec().requiresPassword(payload: payload)
                    jsonPayload = payload
                }
                try cancellation.check()
                return PreparedBackupFile(data: data, isZip: isZip, needsPassword: needsPassword, jsonPayload: jsonPayload)
            }
        }
        try cancellation.check()
        if let coordinationError { throw coordinationError }
        guard let result else { throw PreparationError.coordinationFailed }
        return try result.get()
    }

    private static func readRegularFile(at url: URL, cancellation: CancellationState) throws -> Data {
        try cancellation.check()
        guard url.isFileURL else { throw PreparationError.invalidFile }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw PreparationError.invalidFile }
        if let size = values.fileSize {
            guard size >= 0 else { throw PreparationError.invalidFile }
            guard size <= maximumBytes else { throw PreparationError.tooLarge }
        }
        try cancellation.check()

        // Reject symlink substitution; a substituted FIFO must not block open before fstat can reject it.
        let descriptor = try url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { throw PreparationError.invalidFile }
            let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return descriptor
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        try cancellation.check()
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard (status.st_mode & S_IFMT) == S_IFREG, status.st_size >= 0 else { throw PreparationError.invalidFile }
        guard status.st_size <= Int64(maximumBytes) else { throw PreparationError.tooLarge }

        var data = Data()
        while true {
            try cancellation.check()
            let hasMore = try autoreleasepool {
                // Probe one extra byte at the limit: missing, stale or understated sizes cannot bypass the budget.
                let chunk = try handle.read(upToCount: min(chunkBytes, maximumBytes - data.count + 1)) ?? Data()
                try cancellation.check()
                guard !chunk.isEmpty else { return false }
                guard chunk.count <= maximumBytes - data.count else { throw PreparationError.tooLarge }
                data.append(chunk)
                return true
            }
            if !hasMore { break }
        }
        try cancellation.check()
        guard !data.isEmpty else { throw PreparationError.emptyFile }
        return data
    }

    private final class CancellationState: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var coordinator: NSFileCoordinator?

        func cancel() {
            lock.lock()
            cancelled = true
            let coordinator = self.coordinator
            lock.unlock()
            // Stops coordination waits, not an accessor's in-flight read or synchronous shared JSON parsing.
            coordinator?.cancel()
        }

        func check() throws {
            lock.lock()
            let cancelled = self.cancelled
            lock.unlock()
            if cancelled { throw CancellationError() }
        }

        func register(_ coordinator: NSFileCoordinator) throws {
            lock.lock()
            let cancelled = self.cancelled
            if !cancelled { self.coordinator = coordinator }
            lock.unlock()
            if cancelled {
                coordinator.cancel()
                throw CancellationError()
            }
        }

        func unregister(_ coordinator: NSFileCoordinator) {
            lock.lock()
            if self.coordinator === coordinator { self.coordinator = nil }
            lock.unlock()
        }
    }

    private enum PreparationError: LocalizedError {
        case invalidFile
        case tooLarge
        case emptyFile
        case invalidUTF8
        case coordinationFailed

        var errorDescription: String? {
            switch self {
            case .invalidFile: return "请选择可读取的普通备份文件"
            case .tooLarge: return "备份文件超过 128 MiB"
            case .emptyFile: return "备份文件为空"
            case .invalidUTF8: return "备份文件不是 UTF-8 JSON"
            case .coordinationFailed: return "无法协调读取备份文件"
            }
        }
    }
}
