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
        subscription = facade.watchDownloads { [weak self] tasks in
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.onChange?(tasks)
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

    func clear() async throws {
        let facade = try requiredFacade()
        try await SharedAsync.void { facade.clearDownloads(completionHandler: $0) }
        try await refresh()
    }

    func completedFile(_ task: FileDownloadTask) async throws -> URL {
        guard task.status == .completed, let path = task.localPath else {
            throw Self.error("文件尚未下载完成")
        }
        // Resolve again at delivery time, without reading the file into memory.
        return try await Task.detached(priority: .userInitiated) {
            let manager = FileManager.default
            let documents = try manager.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
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
        case .queued: return "等待下载"
        case .downloading: return "正在下载"
        case .paused: return "已暂停"
        case .completed: return "已完成"
        case .failed: return "下载失败"
        case .cancelled: return "已取消"
        default: return "未知状态"
        }
    }

    var downloadSizeText: String {
        let received = ByteCountFormatter.string(fromByteCount: bytesDownloaded, countStyle: .file)
        guard let total = totalBytes?.int64Value, total > 0 else { return received }
        let expected = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        if status == .completed { return received }
        return "\(received) / \(expected)"
    }

    var downloadSourceHost: String? {
        guard let url else { return nil }
        return URLComponents(string: url)?.host
    }
}
