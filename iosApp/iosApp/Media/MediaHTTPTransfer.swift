import Foundation

enum MediaAudioError: LocalizedError {
    case invalidRequest, unsupportedRedirect, unsupportedFormat, network, empty, cancelled, storage, tooLarge
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "音频请求无效或包含不支持的网络选项"
        case .unsupportedRedirect: return "音频重定向不安全，或需要跨站重发 POST 正文"
        case .unsupportedFormat: return "音频响应不是可渐进播放的单文件媒体，不支持 HLS、DRM 或自定义解密"
        case .network: return "音频网络请求失败，请检查连接后重试"
        case .empty: return "音频服务返回了空内容"
        case .cancelled: return "音频加载已取消"
        case .storage: return "音频临时存储不可用"
        case .tooLarge: return "音频超过本次加载的大小上限"
        case let .http(status): return "音频请求失败：HTTP \(status)"
        }
    }
}

protocol MediaHTTPTransferDelegate: AnyObject {
    func mediaTransfer(received response: HTTPURLResponse, contentLength: Int64?)
    func mediaTransfer(received data: Data)
    func mediaTransfer(completed error: MediaAudioError?)
}

/// One bounded response. All delegate calls and cancellation run on the supplied serial queue.
/// No ambient cookies/credentials, cache, TLS overrides, or URL-bearing errors escape this layer.
final class MediaHTTPTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private static let maximumTransferDuration: TimeInterval = 900

    weak var receiver: MediaHTTPTransferDelegate?

    /// Read only on the supplied serial queue; reflects redirect-isolated URL and headers.
    var effectiveRequest: URLRequest { currentRequest }

    private let queue: DispatchQueue
    private let maximumBytes: Int64
    private let byteRange: MediaHTTPByteRange?
    private var expectedRangeBytes: Int64?
    private var currentRequest: URLRequest
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var deadline: DispatchSourceTimer?
    private var receivedBytes: Int64 = 0
    private var redirects = 0
    private var ended = false

    static func validated(_ request: URLRequest) throws -> URLRequest {
        guard let url = request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
            url.host?.isEmpty == false, url.user == nil, url.password == nil,
            ["GET", "POST"].contains(request.httpMethod?.uppercased() ?? "GET"),
            request.httpBodyStream == nil, (request.httpBody?.count ?? 0) <= 1_048_576,
            request.timeoutInterval.isFinite, request.timeoutInterval > 0
        else { throw MediaAudioError.invalidRequest }
        let unsupported = ["proxy", "proxy-authorization", "cookiejar", "range", "if-range", "content-range"]
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            guard !unsupported.contains(name.lowercased()),
                !name.contains("\r"), !name.contains("\n"), !value.contains("\r"), !value.contains("\n")
            else {
                throw MediaAudioError.invalidRequest
            }
        }
        if let encoding = request.value(forHTTPHeaderField: "Accept-Encoding"), encoding.lowercased() != "identity" {
            throw MediaAudioError.invalidRequest
        }
        var result = request
        result.httpMethod = request.httpMethod?.uppercased() ?? "GET"
        result.httpShouldHandleCookies = false
        result.cachePolicy = .reloadIgnoringLocalCacheData
        result.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return result
    }

    init(request: URLRequest, maximumBytes: Int64, queue: DispatchQueue, byteRange: MediaHTTPByteRange? = nil) throws {
        currentRequest = try Self.validated(request)
        if let byteRange {
            guard currentRequest.httpMethod == "GET", currentRequest.httpBody == nil,
                byteRange.start >= 0, byteRange.end >= byteRange.start, byteRange.end < Int64.max,
                byteRange.count <= maximumBytes
            else { throw MediaAudioError.invalidRequest }
            currentRequest.setValue("bytes=\(byteRange.start)-\(byteRange.end)", forHTTPHeaderField: "Range")
            currentRequest.setValue(byteRange.validator, forHTTPHeaderField: "If-Range")
        }
        self.byteRange = byteRange
        self.maximumBytes = maximumBytes
        self.queue = queue
        super.init()
    }

    func start() {
        guard !ended, session == nil else { return }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // The source timeout bounds idle time; the resource and deadline cap the entire transfer.
        configuration.timeoutIntervalForRequest = currentRequest.timeoutInterval
        configuration.timeoutIntervalForResource = Self.maximumTransferDuration
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = queue
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        self.session = session
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.maximumTransferDuration)
        timer.setEventHandler { [weak self] in self?.finish(.network) }
        deadline = timer
        timer.resume()
        let task = session.dataTask(with: currentRequest)
        self.task = task
        task.resume()
    }

    func cancel() { finish(.cancelled) }

    private func finish(_ error: MediaAudioError?) {
        guard !ended else { return }
        ended = true
        deadline?.cancel()
        deadline = nil
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        receiver?.mediaTransfer(completed: error)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard !ended else { completionHandler(.cancel); return }
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel); finish(.network); return
        }
        guard response.statusCode == 200 || response.statusCode == 206 && byteRange != nil else {
            completionHandler(.cancel); finish(.http(response.statusCode)); return
        }
        if response.statusCode == 206, let byteRange {
            do {
                let range = try byteRange.responseRange(response)
                expectedRangeBytes = range.end - byteRange.start + 1
            } catch {
                completionHandler(.cancel); finish(.network); return
            }
        }
        let mime = response.mimeType?.lowercased() ?? "application/octet-stream"
        let permitted =
            mime.hasPrefix("audio/")
            || ["application/octet-stream", "binary/octet-stream", "application/mp4", "video/mp4"].contains(mime)
        guard permitted, !mime.contains("mpegurl"), !mime.contains("dash") else {
            completionHandler(.cancel); finish(.unsupportedFormat); return
        }
        // URLSession may transparently decode an encoded body; its wire length is then not the asset length.
        let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
        let length =
            response.expectedContentLength >= 0 && (encoding == nil || encoding == "identity")
            ? response.expectedContentLength : nil
        if response.statusCode == 200, byteRange != nil {
            // The range loader must discard the probe and start one sequential response, never mix representations.
            receiver?.mediaTransfer(received: response, contentLength: length)
            completionHandler(.cancel)
            if !ended { finish(.network) }
            return
        }
        if let length, length > maximumBytes { completionHandler(.cancel); finish(.tooLarge); return }
        receiver?.mediaTransfer(received: response, contentLength: length)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !ended else { return }
        let limit = min(maximumBytes, expectedRangeBytes ?? maximumBytes)
        guard Int64(data.count) <= limit - receivedBytes else { finish(.tooLarge); return }
        receivedBytes += Int64(data.count)
        receiver?.mediaTransfer(received: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !ended else { return }
        let incompleteRange = expectedRangeBytes.map { $0 != receivedBytes } ?? false
        finish(error == nil ? (receivedBytes == 0 ? .empty : incompleteRange ? .network : nil) : .network)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard !ended, let from = response.url, let target = request.url,
            ["http", "https"].contains(target.scheme?.lowercased() ?? ""),
            target.host?.isEmpty == false, target.user == nil, target.password == nil,
            !(from.scheme?.lowercased() == "https" && target.scheme?.lowercased() != "https"), redirects < 20
        else {
            completionHandler(nil); finish(.unsupportedRedirect); return
        }
        redirects += 1
        let sameOrigin = Self.origin(from) == Self.origin(target)
        let method = request.httpMethod?.uppercased() ?? "GET"
        // 307/308 must not replay source credentials embedded in a POST body at a different origin.
        guard sameOrigin || (method == "GET" && request.httpBody == nil) else {
            completionHandler(nil); finish(.unsupportedRedirect); return
        }
        // URLRequest's header dictionary setter merges fields; an empty dictionary does not remove secrets.
        var redirected =
            sameOrigin
            ? request
            : URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: currentRequest.timeoutInterval)
        if sameOrigin {
            redirected.allHTTPHeaderFields = currentRequest.allHTTPHeaderFields
            if method == "GET" && currentRequest.httpMethod != "GET" {
                redirected.httpBody = nil
                for name in ["Content-Type", "Content-Length", "Transfer-Encoding", "X-HTTP-Method-Override"] {
                    redirected.setValue(nil, forHTTPHeaderField: name)
                }
            } else {
                redirected.httpBody = currentRequest.httpBody
            }
        } else {
            // A denylist cannot know which custom source header carries a secret.
            redirected.setValue("audio/*, application/octet-stream", forHTTPHeaderField: "Accept")
            if let byteRange {
                redirected.setValue("bytes=\(byteRange.start)-\(byteRange.end)", forHTTPHeaderField: "Range")
            }
        }
        redirected.httpShouldHandleCookies = false
        redirected.timeoutInterval = currentRequest.timeoutInterval
        redirected.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        currentRequest = redirected
        completionHandler(redirected)
    }

    private static func origin(_ url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? ""
        return "\(scheme)://\(url.host?.lowercased() ?? ""):\(url.port ?? (scheme == "https" ? 443 : 80))"
    }
}
