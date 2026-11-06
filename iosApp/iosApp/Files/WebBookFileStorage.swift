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

enum WebBookFileErrorCopy {
    static func message(_ error: Error) -> String {
        if let failure = error as? WebBookFileHTTPFailure {
            guard (100...599).contains(failure.statusCode) else { return error.userFacingMessage }
            return httpMessage(failure.statusCode)
        }
        let failure = error as NSError
        guard let description = failure.userInfo[NSLocalizedDescriptionKey] as? String else {
            return error.userFacingMessage
        }
        switch failure.domain {
        case "io.legado.web-book.file":
            if let key = policyKeys[description] { return L10n.text(key, description) }
            let prefix = "文件下载失败：HTTP "
            // Round-trip equality accepts only the complete canonical decimal status message.
            if description.hasPrefix(prefix), let status = Int(description.dropFirst(prefix.count)),
                (100...599).contains(status), description == "\(prefix)\(status)"
            {
                return httpMessage(status)
            }
        case "io.legado.web-book.file.storage":
            if let key = storageKeys[description] { return L10n.text(key, description) }
        default:
            break
        }
        return error.userFacingMessage
    }

    private static func httpMessage(_ status: Int) -> String {
        L10n.format("web_file.error.http_status", "文件下载失败：HTTP %ld", status)
    }

    private static let policyKeys: [String: String] = [
        "文件下载已经开始": "web_file.error.already_started",
        "文件下载超过 24 小时": "web_file.error.duration_limit",
        "文件响应无效": "web_file.error.invalid_response",
        "不支持分段文件响应": "web_file.error.partial_response_unsupported",
        "服务器忽略 identity 编码，无法可靠校验文件长度": "web_file.error.content_encoding_unsupported",
        "文件超过 2 GiB 下载上限": "web_file.error.response_size_limit",
        "服务器返回了空文件": "web_file.error.empty_response",
        "文件流超过 2 GiB 下载上限": "web_file.error.stream_size_limit",
        "文件流超出服务器声明长度": "web_file.error.stream_length_exceeded",
        "服务器未返回完整文件": "web_file.error.incomplete_response",
        "文件下载不完整，实际长度与声明不符": "web_file.error.download_length_mismatch",
        "文件下载会话提前终止": "web_file.error.session_terminated",
        "文件重定向地址不安全": "web_file.error.unsafe_redirect",
        "文件重定向超过 10 次": "web_file.error.redirect_limit",
        "不支持的文件重定向类型": "web_file.error.redirect_type_unsupported",
        "拒绝向其他站点重发原请求正文或 POST": "web_file.error.cross_origin_replay",
        "响应包含 Cookie，但未提供书源 Cookie 回写回调": "web_file.error.cookie_callback_missing",
        "文件下载未完成": "web_file.error.download_unfinished",
        "文件请求重试次数不能为负数": "web_file.error.invalid_retry_count",
        "文件请求超时配置无效": "web_file.error.invalid_timeout",
        "文件下载仅支持 GET 或 POST": "web_file.error.method_unsupported",
        "文件请求正文无效或超过 1 MiB": "web_file.error.invalid_request_body",
        "iOS URLSession 不支持携带正文的 GET，请调整书源请求规则": "web_file.error.get_body_unsupported",
        "拒绝向其他站点发送源请求正文或 POST": "web_file.error.cross_origin_request",
        "无法读取服务器响应 Cookie": "web_file.error.response_cookie_unreadable",
        "文件响应 Cookie 超过 64 KiB": "web_file.error.response_cookie_size_limit",
        "文件响应 Cookie 数量超过限制": "web_file.error.response_cookie_count_limit",
        "文件请求头数量超过限制": "web_file.error.request_header_count_limit",
        "文件请求头超过大小限制": "web_file.error.request_header_size_limit",
        "文件请求包含无效或重复请求头": "web_file.error.invalid_request_headers",
        "文件下载不支持分段、条件请求或代理选项": "web_file.error.request_options_unsupported",
        "文件请求地址无效": "web_file.error.invalid_request_url",
        "内嵌文件为空或声明长度无效": "web_file.error.inline_invalid_length",
        "内嵌文件超过 64 MiB 解码上限": "web_file.error.inline_decoded_size_limit",
        "内嵌文件编码超过 96 MiB 上限": "web_file.error.inline_encoded_size_limit",
        "内嵌文件 Base64 padding 无效": "web_file.error.inline_invalid_padding",
        "内嵌文件 Base64 padding 后存在数据": "web_file.error.inline_data_after_padding",
        "内嵌文件包含非法 Base64 字符": "web_file.error.inline_invalid_base64_character",
        "内嵌文件 Base64 padding 不完整": "web_file.error.inline_incomplete_padding",
        "内嵌文件 Base64 长度无效": "web_file.error.inline_invalid_base64_length",
        "内嵌文件为空": "web_file.error.inline_empty",
        "内嵌文件实际长度与声明不符": "web_file.error.inline_length_mismatch",
        "内嵌文件 Base64 解码失败": "web_file.error.inline_decode_failed",
        "内嵌文件实际长度超出声明": "web_file.error.inline_length_exceeded",
        "下载暂存目录位置已变更": "web_file.error.storage_staging_directory_changed",
        "文件写入已结束": "web_file.error.storage_write_finished",
        "文件落盘长度或类型校验失败": "web_file.error.storage_file_mismatch",
        "下载临时文件尚未完成": "web_file.error.storage_temporary_file_unfinished",
        "下载暂存文件位置已变更": "web_file.error.storage_staging_file_changed",
        "同名文件过多，请更换文件名": "web_file.error.storage_filename_collisions",
        "下载目录位置已变更或包含符号链接": "web_file.error.storage_download_directory_changed",
    ]

    private static let storageKeys: [String: String] = [
        "无法打开文稿目录": "web_file.error.storage_open_documents_failed",
        "无法创建下载目录": "web_file.error.storage_create_download_directory_failed",
        "下载目录不是安全文件夹": "web_file.error.storage_unsafe_download_directory",
        "无法创建下载暂存目录": "web_file.error.storage_create_staging_directory_failed",
        "无法读取下载暂存目录": "web_file.error.storage_read_staging_directory_failed",
        "无法打开下载暂存目录": "web_file.error.storage_open_staging_directory_failed",
        "无法创建下载临时文件": "web_file.error.storage_create_temporary_file_failed",
        "临时文件无效": "web_file.error.storage_invalid_temporary_file",
        "文件写入失败，请检查存储空间": "web_file.error.storage_write_failed",
        "文件同步失败，请检查存储空间": "web_file.error.storage_sync_failed",
        "文件关闭失败": "web_file.error.storage_close_failed",
        "下载完成，但保存文件失败": "web_file.error.storage_save_failed",
    ]
}
