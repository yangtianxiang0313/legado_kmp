import Foundation
import shared

@MainActor
final class DownloadManagementClient {
    private var facade: RuntimeFacade?
    private var subscription: FlowSubscription?
    private var generation = UUID()
    var onChange: (([FileDownloadTask]) -> Void)?

    deinit { subscription?.cancel() }

    func bind() throws {
        unbind()
        let facade = try SharedRuntime.runtimeFacade().get()
        self.facade = facade
        let generation = generation
        subscription = facade.watchDownloads { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.generation == generation, let facade = self.facade else { return }
                // A queued notification must not replay an older state after a command has finished.
                self.onChange?(facade.getDownloads())
            }
        }
    }

    func unbind() {
        generation = UUID()
        subscription?.cancel()
        subscription = nil
    }

    func refresh() async throws {
        let facade = try requiredFacade()
        try await SharedAsync.void { facade.refreshDownloads(completionHandler: $0) }
    }

    func start(url: String, fileName: String) async throws {
        let facade = try requiredFacade()
        try await SharedAsync.void { facade.startDownload(url: url, fileName: fileName, completionHandler: $0) }
    }

    func pause(id: String) async throws {
        let facade = try requiredFacade()
        try await SharedAsync.void { facade.pauseDownloadTask(taskId: id, completionHandler: $0) }
    }

    func resume(id: String) async throws {
        let facade = try requiredFacade()
        try await SharedAsync.void { facade.resumeDownloadTask(taskId: id, completionHandler: $0) }
    }

    func cancel(id: String) async throws {
        let facade = try requiredFacade()
        try await SharedAsync.void { facade.cancelDownloadTask(taskId: id, completionHandler: $0) }
    }

    func retry(id: String) async throws {
        let facade = try requiredFacade()
        try await SharedAsync.void { facade.retryDownload(taskId: id, completionHandler: $0) }
    }

    func currentTasks() throws -> [FileDownloadTask] {
        try requiredFacade().getDownloads()
    }

    func currentTask(_ original: FileDownloadTask, action: DownloadTaskAction) throws -> FileDownloadTask? {
        try currentTasks().first { $0.matchesDownloadAction(original, action: action) }
    }

    func clear(expectedTaskIDs: Set<String>, canClear: @MainActor () -> Bool) async throws {
        let facade = try requiredFacade()
        // Wait for restoration before comparing the batch the user actually confirmed.
        try await SharedAsync.void { facade.refreshDownloads(completionHandler: $0) }
        guard canClear() else { return }
        guard Set(facade.getDownloads().map(\.id)) == expectedTaskIDs else {
            throw Self.error("下载列表已变化，请重新确认清空")
        }
        try await SharedAsync.void { facade.clearDownloads(completionHandler: $0) }
        try await SharedAsync.void { facade.refreshDownloads(completionHandler: $0) }
    }

    func completedFile(_ task: FileDownloadTask) async throws -> URL {
        guard task.status == .completed, let path = task.localPath else {
            throw Self.error("文件尚未下载完成")
        }
        let expectedSize = task.bytesDownloaded
        // Resolve again at delivery time, without reading the file into memory.
        return try await Task.detached(priority: .userInitiated) {
            let manager = FileManager.default
            let documents = try manager.url(
                for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false
            )
            .resolvingSymlinksInPath()
            let root = documents.appendingPathComponent("Downloads", isDirectory: true).standardizedFileURL
            let original = URL(fileURLWithPath: path).standardizedFileURL
            let candidate = original.resolvingSymlinksInPath()
            guard candidate.deletingLastPathComponent().path == root.path,
                root.resolvingSymlinksInPath().path == root.path,
                original.deletingLastPathComponent().resolvingSymlinksInPath().path == root.path
            else {
                throw Self.error("下载文件位置已变更，请刷新列表")
            }
            let attributes = try manager.attributesOfItem(atPath: original.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw Self.error("下载文件已不存在，请刷新列表")
            }
            guard (attributes[.size] as? NSNumber)?.int64Value == expectedSize else {
                throw Self.error("下载文件已变更，请刷新列表")
            }
            return candidate
        }.value
    }

    private func requiredFacade() throws -> RuntimeFacade {
        guard let facade else { throw Self.error("下载服务尚未就绪") }
        return facade
    }

    private nonisolated static func error(_ message: String) -> NSError {
        NSError(domain: "io.legado.downloads", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

extension FileDownloadTask {
    var downloadStatusText: String {
        switch status {
        case .queued: return DownloadPresentationText.queued
        case .downloading: return DownloadPresentationText.downloading
        case .paused: return DownloadPresentationText.paused
        case .completed: return DownloadPresentationText.completed
        case .failed: return L10n.Reader.downloadProgressFailed
        case .cancelled: return DownloadPresentationText.cancelled
        default: return DownloadPresentationText.unknownStatus
        }
    }

    var downloadSizeText: String {
        let received = ByteCountFormatter.string(fromByteCount: bytesDownloaded, countStyle: .file)
        guard let total = totalBytes?.int64Value, total > 0 else { return received }
        let expected = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        if status == .completed { return received }
        return DownloadPresentationText.sizeProgress(received, expected)
    }

    var downloadSourceHost: String? {
        guard let url else { return nil }
        return URLComponents(string: url)?.host
    }

    func matchesDownloadAction(_ original: FileDownloadTask, action: DownloadTaskAction) -> Bool {
        guard id == original.id, url == original.url, fileName == original.fileName,
            localPath == original.localPath, action.accepts(self), action.accepts(original)
        else { return false }
        if action == .open || action == .share {
            return updatedAt == original.updatedAt && bytesDownloaded == original.bytesDownloaded
                && totalBytes?.int64Value == original.totalBytes?.int64Value
        }
        if isActive && original.isActive { return true }
        return status == original.status && updatedAt == original.updatedAt
    }
}

enum DownloadTaskAction {
    case pause, resume, cancel, retry, open, share

    var title: String {
        switch self {
        case .pause: return DownloadPresentationText.pause
        case .resume: return DownloadPresentationText.resume
        case .cancel: return DownloadPresentationText.cancelDownload
        case .retry: return DownloadPresentationText.retry
        case .open: return DownloadPresentationText.open
        case .share: return L10n.Reader.selectionShare
        }
    }

    var symbol: String {
        switch self {
        case .pause: return "pause.circle"
        case .resume: return "play.circle"
        case .cancel: return "xmark.circle"
        case .retry: return "arrow.clockwise"
        case .open: return "doc"
        case .share: return "square.and.arrow.up"
        }
    }

    func accepts(_ task: FileDownloadTask) -> Bool {
        switch self {
        case .pause: return task.canPause
        case .resume: return task.canResume
        case .cancel: return task.canPause || task.canResume
        case .retry: return task.canRetry
        case .open, .share: return task.status == .completed
        }
    }
}

enum DownloadPresentationText {
    static let title = text("title", "下载管理")
    static let serviceRetry = text("service_retry", "下载服务暂不可用，请刷新重试")
    static let serviceUnavailable = text("service_unavailable", "下载服务暂不可用")
    static let empty = text("empty", "暂无下载")
    static let add = text("add", "新建下载")
    static let more = text("more", "下载操作")
    static let clear = text("clear", "清空任务记录")
    static let clearMessage = text("clear_message", "进行中的下载将取消，已下载文件不会删除。")
    static let clearChanged = text("clear_changed", "下载列表已变化，请重新确认清空")
    static let directoryUnavailable = text("directory_unavailable", "无法读取下载目录，请刷新重试")
    static let urlPlaceholder = text("url_placeholder", "HTTP / HTTPS 地址")
    static let fileNamePlaceholder = text("file_name_placeholder", "文件名（含扩展名）")
    static let operationFailed = text("operation_failed", "下载操作未完成，请检查输入、网络或存储空间后重试")
    static let fileUnavailable = text("file_unavailable", "下载文件已移动或无法访问，请刷新列表")
    static let shareFailed = text("share_failed", "分享未完成，请重试")
    static let openFailed = text("open_failed", "文件未能打开，请重试")
    static let pause = text("pause", "暂停下载")
    static let resume = text("resume", "继续下载")
    static let cancelDownload = text("cancel", "取消下载")
    static let retry = text("retry", "重新下载")
    static let open = text("open", "打开 / 导入")
    static let shareFile = text("share_file", "分享文件")
    static let queued = text("status.queued", "等待下载")
    static let downloading = text("status.downloading", "正在下载")
    static let paused = text("status.paused", "已暂停")
    static let completed = text("status.completed", "已完成")
    static let cancelled = text("status.cancelled", "已取消")
    static let unknownStatus = text("status.unknown", "未知状态")

    static func statusAndSize(_ status: String, _ size: String) -> String {
        String(format: text("status_size", "%1$@ · %2$@"), locale: Locale.current, status, size)
    }

    static func sizeProgress(_ received: String, _ expected: String) -> String {
        String(format: text("size_progress", "%1$@ / %2$@"), locale: Locale.current, received, expected)
    }

    static func commandError(_ error: Error) -> String {
        let sharedError = (error as NSError).userInfo["KotlinException"] as? RecoverableSharedException
        let message = sharedError?.message ?? error.userFacingMessage
        return knownError(message) ?? (isSafeUnknownError(message) ? message : operationFailed)
    }

    static func detailError(_ message: String?) -> String? {
        guard let message, !message.isEmpty else { return nil }
        return knownError(message) ?? (isSafeUnknownError(message) ? message : nil)
    }

    // These are exact shared payloads, not substring replacements or changes to error codes/data.
    private static func knownError(_ message: String) -> String? {
        switch message {
        case "文件尚未下载完成": return text("error.not_completed", "文件尚未下载完成")
        case "下载文件位置已变更，请刷新列表": return text("error.location_changed", "下载文件位置已变更，请刷新列表")
        case "下载文件已不存在，请刷新列表": return text("error.file_missing", "下载文件已不存在，请刷新列表")
        case "下载文件已变更，请刷新列表": return text("error.file_changed", "下载文件已变更，请刷新列表")
        case "下载服务尚未就绪": return text("error.not_ready", "下载服务尚未就绪")
        case "下载列表已变化，请重新确认清空": return clearChanged
        case "请输入有效下载地址": return text("error.invalid_url", "请输入有效下载地址")
        case "仅支持不含账号密码的 HTTP 或 HTTPS 下载地址":
            return text("error.url_credentials", "仅支持不含账号密码的 HTTP 或 HTTPS 下载地址")
        case "文件名不能为空、以点开头或超过 180 字节":
            return text("error.file_name_length", "文件名不能为空、以点开头或超过 180 字节")
        case "文件名不能包含路径分隔符或控制字符":
            return text("error.file_name_characters", "文件名不能包含路径分隔符或控制字符")
        case "下载任务过多，请先清空已完成的任务记录":
            return text("error.too_many_tasks", "下载任务过多，请先清空已完成的任务记录")
        case "该地址已在下载列表中": return text("error.duplicate", "该地址已在下载列表中")
        case "任务已不存在": return text("error.task_missing", "任务已不存在")
        case "此任务无法暂停": return text("error.cannot_pause", "此任务无法暂停")
        case "系统下载任务暂不可用": return text("error.system_unavailable", "系统下载任务暂不可用")
        case "此任务尚未暂停完成": return text("error.pause_pending", "此任务尚未暂停完成")
        case "此任务无法重试": return text("error.cannot_retry", "此任务无法重试")
        case "任务地址已不存在": return text("error.task_url_missing", "任务地址已不存在")
        case "系统下载任务已中断，可重试": return text("error.interrupted", "系统下载任务已中断，可重试")
        case "服务器未提供断点，继续时将从头下载":
            return text("error.no_resume_data", "服务器未提供断点，继续时将从头下载")
        case "断点保存失败，继续时将从头下载":
            return text("error.resume_save_failed", "断点保存失败，继续时将从头下载")
        case "文件响应无效": return text("error.invalid_response", "文件响应无效")
        case "下载文件不存在": return text("error.download_missing", "下载文件不存在")
        case "无法读取下载文件长度": return text("error.file_size_unavailable", "无法读取下载文件长度")
        case "分段下载未形成完整文件": return text("error.partial_file", "分段下载未形成完整文件")
        case "下载文件长度与服务器声明不符": return text("error.size_mismatch", "下载文件长度与服务器声明不符")
        case "当前离线，可联网后继续重试": return text("error.offline", "当前离线，可联网后继续重试")
        case "下载未完成，请检查网络或存储后重试":
            return text("error.incomplete", "下载未完成，请检查网络或存储后重试")
        case "下载完成，但文件校验或保存失败，请重试":
            return text("error.save_failed", "下载完成，但文件校验或保存失败，请重试")
        case "下载任务记录无法读取或已损坏，请重新载入已完成文件":
            return text("error.records_unreadable", "下载任务记录无法读取或已损坏，请重新载入已完成文件")
        case "下载任务记录无法安全保存，请检查存储空间":
            return text("error.records_save_failed", "下载任务记录无法安全保存，请检查存储空间")
        case "下载续传缓存无法安全保存，请从头重试":
            return text("error.resume_cache_failed", "下载续传缓存无法安全保存，请从头重试")
        case "下载文件无效或无法安全保存": return text("error.unsafe_file", "下载文件无效或无法安全保存")
        case "已完成下载目录无法安全读取": return text("error.unsafe_directory", "已完成下载目录无法安全读取")
        default:
            let prefix = "服务器返回 HTTP "
            let suffix = "，文件未保存"
            guard message.hasPrefix(prefix), message.hasSuffix(suffix) else { return nil }
            let digits = String(message.dropFirst(prefix.count).dropLast(suffix.count))
            guard let status = Int(digits), (100...599).contains(status), digits == String(status) else { return nil }
            return String(format: text("error.http_status", "服务器返回 HTTP %d，文件未保存"), locale: Locale.current, status)
        }
    }

    private static func isSafeUnknownError(_ message: String) -> Bool {
        guard message.count <= 160, !message.isEmpty,
            message.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\:@?=#%&").union(.controlCharacters)) == nil
        else { return false }
        let sensitive = [
            "password", "passwd", "token", "secret", "authorization", "cookie", "credential", "bearer", "apikey",
            "api_key",
            "密码", "凭据", "令牌", "口令", "账号", "用户名",
        ]
        return !sensitive.contains { message.localizedCaseInsensitiveContains($0) }
    }

    private static func text(_ key: String, _ fallback: String) -> String {
        Bundle.main.localizedString(forKey: "download.consumer.\(key)", value: fallback, table: nil)
    }
}
