import Foundation

/// A URLSession-owned download file keeps large responses off the main thread and out of memory.
final class ReaderPresetTransferDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    private let limit: Int

    init(limit: Int = ReaderPresetTransferResources.archiveLimit) {
        self.limit = limit
    }

    func load(_ url: URL) async throws -> Data {
        guard Self.accepts(url) else {
            throw ReaderPresetTransferResources.error(
                NSLocalizedString("reader.preset.consumer.invalid_url", value: "请输入有效的 HTTP 或 HTTPS 地址", comment: ""))
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !cancelled else {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard self.continuation == nil, session == nil else {
                    lock.unlock()
                    continuation.resume(
                        throwing: ReaderPresetTransferResources.error(
                            NSLocalizedString("reader.preset.consumer.download_started", value: "下载已经开始", comment: "")))
                    return
                }
                self.continuation = continuation
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 60
                configuration.timeoutIntervalForResource = 120
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.downloadTask(with: url)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        finish(.failure(CancellationError()))
    }

    func urlSession(
        _: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesWritten > Int64(limit) || totalBytesExpectedToWrite > Int64(limit) {
            finish(
                .failure(
                    ReaderPresetTransferResources.error(
                        NSLocalizedString("reader.preset.consumer.download_too_large", value: "阅读配置下载超过 64 MiB", comment: ""))))
        }
    }

    func urlSession(_: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let result: Result<Data, Error> = Result {
            guard let response = downloadTask.response as? HTTPURLResponse,
                let url = response.url, Self.accepts(url)
            else {
                throw ReaderPresetTransferResources.error(
                    NSLocalizedString("reader.preset.consumer.download_invalid_response", value: "下载响应无效", comment: ""))
            }
            guard (200..<300).contains(response.statusCode) else {
                throw ReaderPresetTransferResources.error(
                    String.localizedStringWithFormat(
                        NSLocalizedString("reader.preset.consumer.download_http_error", value: "下载失败：HTTP %ld", comment: ""),
                        response.statusCode))
            }
            guard response.expectedContentLength <= Int64(limit) else {
                throw ReaderPresetTransferResources.error(
                    NSLocalizedString("reader.preset.consumer.download_too_large", value: "阅读配置下载超过 64 MiB", comment: ""))
            }
            return try ReaderBackgroundTextFiles.read(location, limit: limit)
        }
        finish(result)
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }

    func urlSession(
        _: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if let url = request.url, Self.accepts(url) {
            completionHandler(request)
        } else {
            completionHandler(nil)
            finish(
                .failure(
                    ReaderPresetTransferResources.error(
                        NSLocalizedString("reader.preset.consumer.download_redirect_unsupported", value: "不支持的下载重定向", comment: ""))))
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        let session = session
        self.session = nil
        task = nil
        lock.unlock()
        continuation?.resume(with: result)
        session?.invalidateAndCancel()
    }

    private static func accepts(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            && url.host?.isEmpty == false && url.user == nil && url.password == nil
    }
}
