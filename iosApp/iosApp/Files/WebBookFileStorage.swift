import Darwin
import Foundation

final class WebBookFileCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var committed = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !committed else { return false }
        cancelled = true
        return true
    }

    func check() throws {
        if isCancelled { throw CancellationError() }
    }

    func publishAttempt(_ operation: () throws -> URL?) throws -> URL? {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        let url = try operation()
        if url != nil { committed = true }
        return url
    }
}

/// Anchored directory descriptors prevent symlink traversal and no-replace rename prevents all name races.
final class WebBookFileOutput {
    private var documentsFD: Int32 = -1
    private var downloadsFD: Int32 = -1
    private var stagingFD: Int32 = -1
    private var outputFD: Int32 = -1
    private var stagingName: String?
    private var payloadIdentity: stat?
    private var stagingIdentity: stat?
    private var ownsPayload = false
    private var root: URL = URL(fileURLWithPath: "/")
    private var documents: URL = URL(fileURLWithPath: "/")

    init() throws {
        do {
            documents = try FileManager.default.url(
                for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            ).resolvingSymlinksInPath().standardizedFileURL
            root = documents.appendingPathComponent("Downloads", isDirectory: true)
            documentsFD = Darwin.open(documents.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard documentsFD >= 0 else { throw diskError("无法打开文稿目录") }
            if mkdirat(documentsFD, "Downloads", 0o700) != 0 && errno != EEXIST {
                throw diskError("无法创建下载目录")
            }
            downloadsFD = openat(documentsFD, "Downloads", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard downloadsFD >= 0 else { throw diskError("下载目录不是安全文件夹") }
            try validateDirectories()
            let name = ".webbook-\(UUID().uuidString)"
            guard mkdirat(downloadsFD, name, 0o700) == 0 else { throw diskError("无法创建下载暂存目录") }
            stagingName = name
            var identity = stat()
            guard fstatat(downloadsFD, name, &identity, AT_SYMLINK_NOFOLLOW) == 0,
                isDirectory(identity)
            else { throw diskError("无法读取下载暂存目录") }
            stagingIdentity = identity
            stagingFD = openat(downloadsFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard stagingFD >= 0 else { throw diskError("无法打开下载暂存目录") }
            var openedDirectory = stat()
            guard fstat(stagingFD, &openedDirectory) == 0, sameFile(openedDirectory, identity) else {
                throw WebBookFilePolicy.failure("下载暂存目录位置已变更")
            }
            outputFD = openat(stagingFD, "payload", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard outputFD >= 0 else { throw diskError("无法创建下载临时文件") }
            ownsPayload = true
            var payload = stat()
            guard fstat(outputFD, &payload) == 0, isRegular(payload) else { throw diskError("临时文件无效") }
            payloadIdentity = payload
        } catch {
            cleanup()
            throw error
        }
    }

    deinit { cleanup() }

    func write(_ data: Data, cancellation: WebBookFileCancellation) throws {
        guard outputFD >= 0 else { throw WebBookFilePolicy.failure("文件写入已结束") }
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                try cancellation.check()
                let count = Darwin.write(outputFD, base.advanced(by: offset), min(64 * 1024, buffer.count - offset))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw diskError("文件写入失败，请检查存储空间") }
                offset += count
            }
        }
    }

    func synchronizeAndClose(bytes: Int64) throws {
        var actual = stat()
        guard outputFD >= 0, fstat(outputFD, &actual) == 0, isRegular(actual), actual.st_size == bytes,
            let payloadIdentity, sameFile(actual, payloadIdentity), actual.st_nlink == 1
        else { throw WebBookFilePolicy.failure("文件落盘长度或类型校验失败") }
        while fsync(outputFD) != 0 {
            if errno == EINTR { continue }
            throw diskError("文件同步失败，请检查存储空间")
        }
        let descriptor = outputFD
        outputFD = -1
        guard Darwin.close(descriptor) == 0 else { throw diskError("文件关闭失败") }
    }

    func commit(name: String, cancellation: WebBookFileCancellation) throws -> URL {
        try cancellation.check()
        try validateDirectories()
        guard outputFD < 0, let stagingName, let stagingIdentity, let payloadIdentity else {
            throw WebBookFilePolicy.failure("下载临时文件尚未完成")
        }
        var directory = stat()
        var payload = stat()
        guard fstatat(downloadsFD, stagingName, &directory, AT_SYMLINK_NOFOLLOW) == 0,
            isDirectory(directory), sameFile(directory, stagingIdentity),
            fstatat(stagingFD, "payload", &payload, AT_SYMLINK_NOFOLLOW) == 0,
            isRegular(payload), sameFile(payload, payloadIdentity), payload.st_nlink == 1
        else { throw WebBookFilePolicy.failure("下载暂存文件位置已变更") }
        let suffix = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        for index in 0..<10_000 {
            let candidate = index == 0 ? name : "\(stem) (\(index)).\(suffix)"
            let destination = root.appendingPathComponent(candidate, isDirectory: false)
            // Hold the cancellation gate for one atomic rename, never for the entire collision loop.
            let published = try cancellation.publishAttempt {
                // RENAME_EXCL rejects every existing directory entry, including dangling symlinks.
                if renameatx_np(stagingFD, "payload", downloadsFD, candidate, UInt32(RENAME_EXCL)) == 0 {
                    ownsPayload = false
                    return destination
                }
                guard errno == EEXIST else { throw diskError("下载完成，但保存文件失败") }
                return nil
            }
            // No throwing work or cancellation check is allowed after atomic publication.
            if let published { return published }
        }
        throw WebBookFilePolicy.failure("同名文件过多，请更换文件名")
    }

    func cleanup() {
        if outputFD >= 0 { _ = Darwin.close(outputFD); outputFD = -1 }
        if ownsPayload, stagingFD >= 0, let payloadIdentity {
            var current = stat()
            if fstatat(stagingFD, "payload", &current, AT_SYMLINK_NOFOLLOW) == 0,
                isRegular(current), sameFile(current, payloadIdentity)
            {
                _ = unlinkat(stagingFD, "payload", 0)
            }
        }
        ownsPayload = false
        if stagingFD >= 0 { _ = Darwin.close(stagingFD); stagingFD = -1 }
        if downloadsFD >= 0, let stagingName, let stagingIdentity {
            var current = stat()
            if fstatat(downloadsFD, stagingName, &current, AT_SYMLINK_NOFOLLOW) == 0,
                isDirectory(current), sameFile(current, stagingIdentity)
            {
                _ = unlinkat(downloadsFD, stagingName, AT_REMOVEDIR)
            }
        }
        stagingName = nil
        if downloadsFD >= 0 { _ = Darwin.close(downloadsFD); downloadsFD = -1 }
        if documentsFD >= 0 { _ = Darwin.close(documentsFD); documentsFD = -1 }
    }

    private func validateDirectories() throws {
        var documentsHandle = stat()
        var documentsPath = stat()
        var downloadsHandle = stat()
        var downloadsPath = stat()
        guard fstat(documentsFD, &documentsHandle) == 0, lstat(documents.path, &documentsPath) == 0,
            isDirectory(documentsPath), sameFile(documentsHandle, documentsPath),
            fstat(downloadsFD, &downloadsHandle) == 0,
            fstatat(documentsFD, "Downloads", &downloadsPath, AT_SYMLINK_NOFOLLOW) == 0,
            isDirectory(downloadsPath), sameFile(downloadsHandle, downloadsPath)
        else { throw WebBookFilePolicy.failure("下载目录位置已变更或包含符号链接") }
    }

    private func isDirectory(_ value: stat) -> Bool { (value.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) }
    private func isRegular(_ value: stat) -> Bool { (value.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) }
    private func sameFile(_ left: stat, _ right: stat) -> Bool { left.st_dev == right.st_dev && left.st_ino == right.st_ino }

    private func diskError(_ message: String) -> NSError {
        let code = errno
        return NSError(
            domain: "io.legado.web-book.file.storage", code: Int(code),
            userInfo: [
                NSLocalizedDescriptionKey: message, NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(code)),
            ])
    }
}
