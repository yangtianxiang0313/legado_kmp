import Foundation
import UniformTypeIdentifiers
import shared

protocol WebBookFileLoading: AnyObject, Sendable {
    func cancel()
}

struct WebBookFileReceipt: Sendable {
    let url: URL
    let bytes: Int64
    let total: Int64?
}

@MainActor
final class WebBookFileLoader {
    private var active: (any WebBookFileLoading)?

    deinit { active?.cancel() }

    func load(
        _ prepared: WebBookFileRequest,
        prepareRedirect: @escaping @MainActor (WebBookFileRequest, URL) async throws -> [String: String],
        recordResponseCookies: (@MainActor (WebBookFileRequest, URL, [String]) async throws -> Void)? = nil,
        onResponseHeaders: (@MainActor () -> Void)? = nil,
        onProgress: @escaping @MainActor (Int64, Int64?) -> Void
    ) async throws -> URL {
        guard active == nil else { throw WebBookFilePolicy.failure("文件下载已经开始") }
        try Task.checkCancellation()
        let input = try WebBookFilePolicy.Input(prepared)
        let progress = WebBookFileProgress(onProgress)
        let operation = WebBookFileHTTPOperation()
        active = operation
        defer {
            progress.stop()
            operation.finish { [weak self, weak operation] in
                guard let self, let operation, self.active === operation else { return }
                self.active = nil
            }
        }
        let receipt = try await withTaskCancellationHandler {
            do {
                var request = input.request
                var retriesRemaining = input.retryCount
                while true {
                    try operation.check()
                    let transfer = WebBookFileTransfer(
                        input: input, request: request, gate: operation.gate,
                        remainingDuration: operation.remainingDuration,
                        prepareRedirect: prepareRedirect, recordResponseCookies: recordResponseCookies,
                        onResponseHeaders: onResponseHeaders, progress: progress)
                    try operation.attach(transfer)
                    do {
                        let receipt = try await transfer.load()
                        operation.detach(transfer)
                        return receipt
                    } catch {
                        operation.detach(transfer)
                        try operation.check()
                        // Only an actual final non-2xx response permits replay, including an explicit POST retry.
                        guard error is WebBookFileHTTPFailure, retriesRemaining > 0 else { throw error }
                        retriesRemaining -= 1
                        let headers = try await operation.refreshHeaders {
                            // Always scope the original prepared intent, never the failed redirect's private headers.
                            try await prepareRedirect(prepared, input.initialURL)
                        }
                        try operation.check()
                        request = try WebBookFilePolicy.request(
                            url: input.initialURL, method: input.request.httpMethod ?? "GET", body: input.request.httpBody,
                            headers: headers, timeout: input.request.timeoutInterval,
                            allowsPrivate: WebBookFilePolicy.sameOrigin(input.headerOrigin, input.initialURL))
                    }
                }
            } catch {
                throw operation.failure(or: error)
            }
        } onCancel: {
            operation.cancel()
        }
        // Publication is the cancellation linearization point. Never throw after a successful commit.
        progress.report(receipt.bytes, receipt.total)
        return receipt.url
    }

    func loadInline(
        _ data: WebBookFileInlineData,
        onProgress: @escaping @MainActor (Int64, Int64?) -> Void
    ) async throws -> URL {
        guard active == nil else { throw WebBookFilePolicy.failure("文件下载已经开始") }
        try Task.checkCancellation()
        let progress = WebBookFileProgress(onProgress)
        let transfer = WebBookFileInlineLoader(data: data, progress: progress)
        active = transfer
        defer {
            progress.stop()
            if active === transfer { active = nil }
        }
        let receipt = try await transfer.load()
        // As with HTTP, a late Task cancellation cannot undo successful publication.
        progress.report(receipt.bytes, receipt.total)
        return receipt.url
    }

    func cancel() { active?.cancel() }
}

@MainActor
final class WebBookFileProgress {
    private let callback: @MainActor (Int64, Int64?) -> Void
    private var lastBytes: Int64 = -1
    private var stopped = false

    init(_ callback: @escaping @MainActor (Int64, Int64?) -> Void) { self.callback = callback }

    func report(_ bytes: Int64, _ total: Int64?) {
        guard !stopped, bytes >= lastBytes else { return }
        lastBytes = bytes
        callback(bytes, total)
    }

    func stop() { stopped = true }
}

private struct WebBookFileHTTPFailure: LocalizedError, Sendable {
    let statusCode: Int

    var errorDescription: String? { "文件下载失败：HTTP \(statusCode)" }
}

/// One reservation, publication gate and monotonic deadline cover every transfer and header refresh.
private final class WebBookFileHTTPOperation: WebBookFileLoading, @unchecked Sendable {
    let gate = WebBookFileCancellation()
    private let lock = NSLock()
    private let deadline = DispatchTime.now() + WebBookFilePolicy.maximumDuration
    private let timer: DispatchSourceTimer
    private var terminalError: Error?
    private var transfer: WebBookFileTransfer?
    private var preparation:
        (
            id: UUID, task: Task<Void, Never>, continuation: CheckedContinuation<[String: String], Error>?
        )?
    private var releaseReservation: (@MainActor () -> Void)?

    init() {
        timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: deadline)
        timer.setEventHandler { [weak self] in
            self?.stop(WebBookFilePolicy.failure("文件下载超过 24 小时"))
        }
        timer.resume()
    }

    deinit { timer.cancel() }

    var remainingDuration: TimeInterval {
        let now = DispatchTime.now().uptimeNanoseconds
        let end = deadline.uptimeNanoseconds
        return end > now ? Double(end - now) / 1_000_000_000 : 0.001
    }

    func check() throws {
        if DispatchTime.now().uptimeNanoseconds >= deadline.uptimeNanoseconds {
            stop(WebBookFilePolicy.failure("文件下载超过 24 小时"))
        }
        lock.lock()
        let error = terminalError
        lock.unlock()
        if let error { throw error }
        try gate.check()
    }

    func failure(or error: Error) -> Error {
        lock.lock()
        defer { lock.unlock() }
        return terminalError ?? error
    }

    func attach(_ transfer: WebBookFileTransfer) throws {
        lock.lock()
        defer { lock.unlock() }
        if let terminalError { throw terminalError }
        self.transfer = transfer
    }

    func detach(_ transfer: WebBookFileTransfer) {
        lock.lock()
        defer { lock.unlock() }
        if self.transfer === transfer { self.transfer = nil }
    }

    @MainActor
    func refreshHeaders(
        _ callback: @escaping @MainActor () async throws -> [String: String]
    ) async throws -> [String: String] {
        try check()
        return try await withCheckedThrowingContinuation { continuation in
            let id = UUID()
            let task = Task { @MainActor [weak self] in
                do {
                    try Task.checkCancellation()
                    let headers = try await callback()
                    try Task.checkCancellation()
                    self?.completePreparation(id, result: .success(headers))
                } catch {
                    self?.completePreparation(id, result: .failure(error))
                }
            }
            lock.lock()
            if let terminalError {
                lock.unlock()
                task.cancel()
                continuation.resume(throwing: terminalError)
            } else {
                preparation = (id, task, continuation)
                lock.unlock()
            }
        }
    }

    @MainActor
    private func completePreparation(_ id: UUID, result: Result<[String: String], Error>) {
        lock.lock()
        guard let pending = preparation, pending.id == id else { lock.unlock(); return }
        preparation = nil
        let error = terminalError
        let release = releaseReservation
        releaseReservation = nil
        lock.unlock()
        pending.continuation?.resume(with: error.map { .failure($0) } ?? result)
        release?()
    }

    func cancel() { stop(CancellationError()) }

    private func stop(_ error: Error) {
        lock.lock()
        // The same gate protects the atomic file rename; a late cancel cannot overwrite success.
        guard terminalError == nil, gate.cancel() else { lock.unlock(); return }
        terminalError = error
        let transfer = transfer
        let pending = preparation
        // Resume cancellation promptly, but reserve the loader until the callback actually exits.
        preparation?.continuation = nil
        lock.unlock()
        transfer?.cancel()
        pending?.task.cancel()
        pending?.continuation?.resume(throwing: error)
    }

    @MainActor
    func finish(release: @escaping @MainActor () -> Void) {
        timer.cancel()
        lock.lock()
        transfer = nil
        let pending = preparation != nil
        if pending { releaseReservation = release }
        lock.unlock()
        if !pending { release() }
    }
}

/// A fresh session and a serial writer per invocation; only the cancellation gate crosses queues.
private final class WebBookFileTransfer: NSObject, URLSessionDataDelegate, WebBookFileLoading, @unchecked Sendable {
    private struct RedirectPlan: Sendable {
        let target: URL
        let method: String
        let body: Data?
        let sameOrigin: Bool
        let allowsPrivate: Bool
        let strippedEntity: Bool
    }

    private let queue = DispatchQueue(label: "io.legado.web-book.file", qos: .userInitiated)
    private let gate: WebBookFileCancellation
    private let input: WebBookFilePolicy.Input
    private let remainingDuration: TimeInterval
    private let progress: WebBookFileProgress
    private var prepareRedirect: (@MainActor (WebBookFileRequest, URL) async throws -> [String: String])?
    private var recordResponseCookies: (@MainActor (WebBookFileRequest, URL, [String]) async throws -> Void)?
    private var onResponseHeaders: (@MainActor () -> Void)?

    // Confined to queue, including all URLSession delegate callbacks and disk operations.
    private var continuation: CheckedContinuation<WebBookFileReceipt, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var currentRequest: URLRequest
    private var currentPrepared: WebBookFileRequest
    private var file: WebBookFileOutput?
    private var response: HTTPURLResponse?
    private var expectedBytes: Int64?
    private var receivedBytes: Int64 = 0
    private var redirects = 0
    private var failure: Error?
    private var result: Result<WebBookFileReceipt, Error>?
    private var invalidating = false
    private var started = false
    private var lastProgressTime: TimeInterval = 0
    private var redirectID: UUID?
    private var redirectTask: Task<Void, Never>?
    private var redirectCompletion: ((URLRequest?) -> Void)?
    private var responsePreparationID: UUID?
    private var responsePreparationTask: Task<Void, Never>?
    private var responseCompletion: ((URLSession.ResponseDisposition) -> Void)?

    init(
        input: WebBookFilePolicy.Input,
        request: URLRequest,
        gate: WebBookFileCancellation,
        remainingDuration: TimeInterval,
        prepareRedirect: @escaping @MainActor (WebBookFileRequest, URL) async throws -> [String: String],
        recordResponseCookies: (@MainActor (WebBookFileRequest, URL, [String]) async throws -> Void)?,
        onResponseHeaders: (@MainActor () -> Void)?,
        progress: WebBookFileProgress
    ) {
        self.input = input
        self.gate = gate
        self.remainingDuration = remainingDuration
        self.prepareRedirect = prepareRedirect
        self.recordResponseCookies = recordResponseCookies
        self.onResponseHeaders = onResponseHeaders
        self.progress = progress
        currentRequest = request
        currentPrepared = input.snapshot(url: input.initialURL, request: request, explicitCookie: input.explicitCookie)
        super.init()
    }

    func load() async throws -> WebBookFileReceipt {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { self.start(continuation) }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        guard gate.cancel() else { return }
        queue.async { self.stop(CancellationError()) }
    }

    private func start(_ continuation: CheckedContinuation<WebBookFileReceipt, Error>) {
        guard !started else {
            continuation.resume(throwing: WebBookFilePolicy.failure("文件下载已经开始"))
            return
        }
        started = true
        self.continuation = continuation
        do {
            try gate.check()
            file = try WebBookFileOutput()
            try gate.check()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.httpCookieAcceptPolicy = .never
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            // URLSession resets the request's idle timeout when data arrives, not at file-size intervals.
            configuration.timeoutIntervalForRequest = input.request.timeoutInterval
            configuration.timeoutIntervalForResource = remainingDuration
            configuration.waitsForConnectivity = false
            configuration.httpMaximumConnectionsPerHost = 1
            let delegateQueue = OperationQueue()
            delegateQueue.maxConcurrentOperationCount = 1
            delegateQueue.underlyingQueue = queue
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
            self.session = session
            let task = session.dataTask(with: currentRequest)
            self.task = task
            task.resume()
        } catch {
            result = .failure(error)
            resolve()
        }
    }

    private func stop(_ error: Error) {
        guard continuation != nil, result == nil else { return }
        if failure == nil { failure = error }
        endRedirect(nil)
        endResponsePreparation(.cancel)
        task?.cancel()
        if let session {
            if !invalidating {
                invalidating = true
                session.invalidateAndCancel()
            }
        } else {
            result = .failure(failure ?? error)
            resolve()
        }
    }

    func urlSession(
        _: URLSession, dataTask _: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        do {
            try gate.check()
            guard failure == nil, result == nil, self.response == nil, responseCompletion == nil,
                let response = response as? HTTPURLResponse, let url = response.url, url == currentRequest.url
            else { throw WebBookFilePolicy.failure("文件响应无效") }
            let cookies = try WebBookFilePolicy.setCookieHeaders(response)
            let recorder = try cookieRecorder(for: cookies)
            let current = currentPrepared
            let onResponseHeaders = onResponseHeaders
            let id = UUID()
            responsePreparationID = id
            responseCompletion = completionHandler
            responsePreparationTask = Task { @MainActor [weak self] in
                do {
                    if let recorder { try await recorder(current, url, cookies) }
                    try Task.checkCancellation()
                    let expectedBytes = try Self.validateFinalResponse(response)
                    guard let self else { return }
                    try self.gate.check()
                    onResponseHeaders?()
                    try Task.checkCancellation()
                    try self.gate.check()
                    self.queue.async {
                        guard self.responsePreparationID == id, self.failure == nil, self.result == nil else { return }
                        do {
                            try self.gate.check()
                            self.expectedBytes = expectedBytes
                            self.response = response
                            self.publishProgress(force: true)
                            self.endResponsePreparation(.allow)
                        } catch {
                            self.endResponsePreparation(.cancel)
                            self.stop(error)
                        }
                    }
                } catch {
                    guard let self else { return }
                    self.queue.async {
                        guard self.responsePreparationID == id else { return }
                        self.endResponsePreparation(.cancel)
                        self.stop(error)
                    }
                }
            }
        } catch {
            completionHandler(.cancel)
            stop(error)
        }
    }

    private static func validateFinalResponse(_ response: HTTPURLResponse) throws -> Int64? {
        // Record cookies even on an error response, but never publish a partial/conditional file.
        guard (200..<300).contains(response.statusCode) else {
            throw WebBookFileHTTPFailure(statusCode: response.statusCode)
        }
        guard response.statusCode == 200 else {
            throw WebBookFilePolicy.failure("文件下载失败：HTTP \(response.statusCode)")
        }
        guard response.value(forHTTPHeaderField: "Content-Range") == nil else {
            throw WebBookFilePolicy.failure("不支持分段文件响应")
        }
        let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard encoding == nil || encoding == "identity" else {
            throw WebBookFilePolicy.failure("服务器忽略 identity 编码，无法可靠校验文件长度")
        }
        let length = response.expectedContentLength
        guard length <= WebBookFilePolicy.maximumBytes else { throw WebBookFilePolicy.failure("文件超过 2 GiB 下载上限") }
        guard length != 0 else { throw WebBookFilePolicy.failure("服务器返回了空文件") }
        return length >= 0 ? length : nil
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil, result == nil else { return }
        do {
            try gate.check()
            guard response != nil, let file else { throw WebBookFilePolicy.failure("文件响应无效") }
            let count = Int64(data.count)
            guard count <= WebBookFilePolicy.maximumBytes - receivedBytes else {
                throw WebBookFilePolicy.failure("文件流超过 2 GiB 下载上限")
            }
            if let expectedBytes, count > expectedBytes - receivedBytes {
                throw WebBookFilePolicy.failure("文件流超出服务器声明长度")
            }
            try file.write(data, cancellation: gate)
            receivedBytes += count
            publishProgress()
        } catch {
            stop(error)
        }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        guard result == nil, continuation != nil else { return }
        endRedirect(nil)
        endResponsePreparation(.cancel)
        do {
            try gate.check()
            if let failure { throw failure }
            if let error { throw error }
            guard let response, let file, receivedBytes > 0 else {
                throw WebBookFilePolicy.failure("服务器未返回完整文件")
            }
            if let expectedBytes, receivedBytes != expectedBytes {
                throw WebBookFilePolicy.failure("文件下载不完整，实际长度与声明不符")
            }
            try file.synchronizeAndClose(bytes: receivedBytes)
            let name = WebBookFilePolicy.filename(response: response, fallback: input.fileName)
            let url = try file.commit(name: name, cancellation: gate)
            result = .success(WebBookFileReceipt(url: url, bytes: receivedBytes, total: expectedBytes))
        } catch {
            result = .failure(error)
        }
        file?.cleanup()
        file = nil
        if !invalidating {
            invalidating = true
            session?.finishTasksAndInvalidate()
        }
        // Even cancellation waits for didBecomeInvalid: no writes or delegates outlive load().
    }

    func urlSession(_: URLSession, didBecomeInvalidWithError error: Error?) {
        guard continuation != nil else { return }
        if result == nil {
            result = .failure(
                gate.isCancelled
                    ? CancellationError()
                    : failure ?? error ?? WebBookFilePolicy.failure("文件下载会话提前终止"))
        }
        resolve()
    }

    func urlSession(
        _: URLSession, task _: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest proposed: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        do {
            try gate.check()
            guard failure == nil, result == nil, redirectCompletion == nil, responseCompletion == nil,
                let from = currentRequest.url, response.url == from,
                let prepareRedirect
            else { throw WebBookFilePolicy.failure("文件重定向地址不安全") }
            let cookies = try WebBookFilePolicy.setCookieHeaders(response)
            let recorder = try cookieRecorder(for: cookies)
            // Record this actual response even if its proposed next hop will be refused.
            let plan = Result { try redirectPlan(from: from, response: response, proposed: proposed) }
            let current = currentPrepared
            let id = UUID()
            redirectID = id
            redirectCompletion = completionHandler
            redirectTask = Task { [weak self] in
                do {
                    if let recorder { try await recorder(current, from, cookies) }
                    try Task.checkCancellation()
                    let plan = try plan.get()
                    // This callback must only scope headers/cookies, never rerun a source script.
                    let headers = try await prepareRedirect(current, plan.target)
                    try Task.checkCancellation()
                    guard let self else { return }
                    self.queue.async {
                        guard self.redirectID == id, self.failure == nil, self.result == nil else { return }
                        do {
                            try self.gate.check()
                            // Never adopt URLSession's synthesized headers, Authorization, cookies, or body.
                            let next = try WebBookFilePolicy.request(
                                url: plan.target, method: plan.method, body: plan.body, headers: headers,
                                timeout: self.input.request.timeoutInterval, allowsPrivate: plan.allowsPrivate,
                                strippedEntity: plan.strippedEntity)
                            self.currentRequest = next
                            self.currentPrepared = self.input.snapshot(
                                url: plan.target, request: next,
                                explicitCookie: plan.sameOrigin ? current.explicitCookie : nil)
                            self.endRedirect(next)
                        } catch {
                            self.endRedirect(nil)
                            self.stop(error)
                        }
                    }
                } catch {
                    guard let self else { return }
                    self.queue.async {
                        guard self.redirectID == id else { return }
                        self.endRedirect(nil)
                        self.stop(error)
                    }
                }
            }
        } catch {
            completionHandler(nil)
            stop(error)
        }
    }

    private func redirectPlan(from: URL, response: HTTPURLResponse, proposed: URLRequest) throws -> RedirectPlan {
        guard let proposedURL = proposed.url, let target = try? WebBookFilePolicy.networkURL(proposedURL),
            !(from.scheme?.lowercased() == "https" && target.scheme?.lowercased() != "https")
        else { throw WebBookFilePolicy.failure("文件重定向地址不安全") }
        guard redirects < 10 else { throw WebBookFilePolicy.failure("文件重定向超过 10 次") }
        guard [301, 302, 303, 307, 308].contains(response.statusCode) else {
            throw WebBookFilePolicy.failure("不支持的文件重定向类型")
        }
        let rewritten =
            response.statusCode == 303
            || ([301, 302].contains(response.statusCode) && currentRequest.httpMethod == "POST")
        let method = rewritten ? "GET" : (currentRequest.httpMethod ?? "GET")
        let body = rewritten ? nil : currentRequest.httpBody
        let sameOrigin = WebBookFilePolicy.sameOrigin(from, target)
        // Even an empty POST can encode source-specific state; never replay it across origins.
        guard sameOrigin || (method == "GET" && body == nil) else {
            throw WebBookFilePolicy.failure("拒绝向其他站点重发原请求正文或 POST")
        }
        redirects += 1
        return RedirectPlan(
            target: target, method: method, body: body, sameOrigin: sameOrigin,
            allowsPrivate: sameOrigin && WebBookFilePolicy.sameOrigin(input.headerOrigin, target), strippedEntity: rewritten)
    }

    func urlSession(
        _: URLSession, task _: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        Self.authenticate(challenge, completionHandler)
    }

    func urlSession(
        _: URLSession, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        Self.authenticate(challenge, completionHandler)
    }

    func urlSession(
        _: URLSession, dataTask _: URLSessionDataTask, willCacheResponse _: CachedURLResponse,
        completionHandler: @escaping (CachedURLResponse?) -> Void
    ) {
        completionHandler(nil)
    }

    private static func authenticate(
        _ challenge: URLAuthenticationChallenge,
        _ completion: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        completion(
            challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }

    private func publishProgress(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastProgressTime >= 0.1 else { return }
        lastProgressTime = now
        let bytes = receivedBytes
        let total = expectedBytes
        Task { @MainActor [weak progress] in progress?.report(bytes, total) }
    }

    private func endRedirect(_ request: URLRequest?) {
        let completion = redirectCompletion
        redirectCompletion = nil
        redirectID = nil
        let task = redirectTask
        redirectTask = nil
        task?.cancel()
        completion?(request)
    }

    private func endResponsePreparation(_ disposition: URLSession.ResponseDisposition) {
        let completion = responseCompletion
        responseCompletion = nil
        responsePreparationID = nil
        let task = responsePreparationTask
        responsePreparationTask = nil
        task?.cancel()
        completion?(disposition)
    }

    private func cookieRecorder(
        for cookies: [String]
    ) throws -> (@MainActor (WebBookFileRequest, URL, [String]) async throws -> Void)? {
        guard cookies.isEmpty || recordResponseCookies != nil else {
            throw WebBookFilePolicy.failure("响应包含 Cookie，但未提供书源 Cookie 回写回调")
        }
        return recordResponseCookies
    }

    private func resolve() {
        endRedirect(nil)
        endResponsePreparation(.cancel)
        file?.cleanup()
        file = nil
        prepareRedirect = nil
        recordResponseCookies = nil
        onResponseHeaders = nil
        task = nil
        session = nil
        let continuation = continuation
        self.continuation = nil
        let result = result ?? .failure(WebBookFilePolicy.failure("文件下载未完成"))
        continuation?.resume(with: result)
    }
}

enum WebBookFilePolicy {
    static let maximumBytes: Int64 = 2 * 1024 * 1024 * 1024
    static let maximumDuration: TimeInterval = 24 * 60 * 60
    private static let maximumBodyBytes = 1024 * 1024
    private static let publicHeaders: Set<String> = ["accept", "accept-language", "user-agent"]
    private static let managedHeaders: Set<String> = [
        "host", "content-length", "transfer-encoding", "connection", "keep-alive", "te", "trailer", "upgrade",
        "accept-encoding", "cookie2", "proxy-authorization", "proxy-authenticate",
    ]
    private static let unsupportedHeaders: Set<String> = [
        "range", "if-range", "content-range", "if-match", "if-none-match", "if-modified-since", "if-unmodified-since",
        "x-http-method-override", "proxy", "cookiejar",
    ]

    struct Input: Sendable {
        let request: URLRequest
        let initialURL: URL
        let headerOrigin: URL
        let fileName: String
        let bodyBase64: String?
        let explicitCookie: String?
        let retryCount: Int32
        private let sourceURL: String
        private let headerOriginURL: String
        private let enabledCookieJar: Bool

        init(_ prepared: WebBookFileRequest) throws {
            guard prepared.retryCount >= 0 else { throw failure("文件请求重试次数不能为负数") }
            retryCount = prepared.retryCount
            let url = try WebBookFilePolicy.url(prepared.url)
            initialURL = url
            headerOrigin = try WebBookFilePolicy.url(prepared.headerOriginUrl)
            let timeout = Double(prepared.timeoutMillis) / 1000
            guard timeout.isFinite, timeout > 0 else { throw failure("文件请求超时配置无效") }
            let method = prepared.method.uppercased()
            guard ["GET", "POST"].contains(method) else { throw failure("文件下载仅支持 GET 或 POST") }
            var body: Data?
            if let encoded = prepared.bodyBase64 {
                guard encoded.utf8.count <= ((maximumBodyBytes + 2) / 3) * 4,
                    let decoded = Data(base64Encoded: encoded), decoded.count <= maximumBodyBytes
                else { throw failure("文件请求正文无效或超过 1 MiB") }
                body = decoded
            }
            // URLSession rejects GET bodies on iOS 13+; never silently drop bytes or change the method.
            guard method != "GET" || body == nil else {
                throw failure("iOS URLSession 不支持携带正文的 GET，请调整书源请求规则")
            }
            let scoped = sameOrigin(headerOrigin, url)
            guard scoped || (method == "GET" && body == nil) else {
                throw failure("拒绝向其他站点发送源请求正文或 POST")
            }
            request = try WebBookFilePolicy.request(
                url: url, method: method, body: body, headers: prepared.headers,
                timeout: max(1, min(3600, timeout)), allowsPrivate: scoped)
            // Cookie/explicitCookie/enabledCookieJar are already scoped by common. Never merge them again here.
            fileName = prepared.fileName
            bodyBase64 = prepared.bodyBase64
            explicitCookie = scoped ? prepared.explicitCookie : nil
            sourceURL = prepared.sourceUrl
            headerOriginURL = prepared.headerOriginUrl
            enabledCookieJar = prepared.enabledCookieJar
        }

        func snapshot(url: URL, request: URLRequest, explicitCookie: String?) -> WebBookFileRequest {
            WebBookFileRequest(
                url: url.absoluteString, method: request.httpMethod ?? "GET",
                headers: request.allHTTPHeaderFields ?? [:], bodyBase64: request.httpBody == nil ? nil : bodyBase64,
                fileName: fileName, timeoutMillis: Int64(request.timeoutInterval * 1000), sourceUrl: sourceURL,
                headerOriginUrl: headerOriginURL, explicitCookie: explicitCookie, enabledCookieJar: enabledCookieJar,
                retryCount: retryCount)
        }
    }

    static func setCookieHeaders(_ response: HTTPURLResponse) throws -> [String] {
        var values: [String] = []
        for (name, value) in response.allHeaderFields {
            guard let name = name.base as? String, name.caseInsensitiveCompare("Set-Cookie") == .orderedSame else { continue }
            if let raw = value as? String {
                values.append(raw)
            } else if let raw = value as? [String] {
                values.append(contentsOf: raw)
            } else {
                throw failure("无法读取服务器响应 Cookie")
            }
        }
        if values.isEmpty, let raw = response.value(forHTTPHeaderField: "Set-Cookie") { values.append(raw) }
        var bytes = 0
        for value in values {
            guard value.utf8.count <= 64 * 1024 - bytes else { throw failure("文件响应 Cookie 超过 64 KiB") }
            bytes += value.utf8.count
        }
        guard values.count <= 128 else { throw failure("文件响应 Cookie 数量超过限制") }
        // Foundation may fold fields into one value. common's withSplitSetCookieHeaders handles Expires commas.
        return values
    }

    static func request(
        url: URL, method: String, body: Data?, headers: [String: String], timeout: TimeInterval,
        allowsPrivate: Bool, strippedEntity: Bool = false
    ) throws -> URLRequest {
        guard headers.count <= 128 else { throw failure("文件请求头数量超过限制") }
        var result = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        result.httpMethod = method
        result.httpBody = body
        result.httpShouldHandleCookies = false
        var seen = Set<String>()
        var headerBytes = 0
        for (name, value) in headers {
            let size = name.utf8.count + value.utf8.count
            guard value.utf8.count <= 16 * 1024, size <= 64 * 1024 - headerBytes else {
                throw failure("文件请求头超过大小限制")
            }
            headerBytes += size
            let key = name.lowercased()
            guard validHeaderName(name), !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
                seen.insert(key).inserted
            else { throw failure("文件请求包含无效或重复请求头") }
            guard !unsupportedHeaders.contains(key) else { throw failure("文件下载不支持分段、条件请求或代理选项") }
            if managedHeaders.contains(key) || key.hasPrefix("proxy-") { continue }
            if strippedEntity && (key.hasPrefix("content-") || key == "digest" || key == "expect") { continue }
            // Cookie is exclusively the callback's target-scoped value, never the previous hop's header.
            if !allowsPrivate && key != "cookie" && !publicHeaders.contains(key) { continue }
            result.setValue(value, forHTTPHeaderField: name)
        }
        result.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return result
    }

    static func accepts(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host?.isEmpty == false
            && url.user == nil && url.password == nil && (url.port.map { (1...65535).contains($0) } ?? true)
    }

    private static func url(_ string: String?) throws -> URL {
        guard let string, let url = URL(string: string), accepts(url) else { throw failure("文件请求地址无效") }
        return try networkURL(url)
    }

    static func networkURL(_ url: URL) throws -> URL {
        guard accepts(url), var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw failure("文件请求地址无效")
        }
        components.fragment = nil
        guard let result = components.url else { throw failure("文件请求地址无效") }
        return result
    }

    static func sameOrigin(_ left: URL, _ right: URL) -> Bool {
        left.scheme?.lowercased() == right.scheme?.lowercased()
            && left.host?.lowercased() == right.host?.lowercased()
            && (left.port ?? (left.scheme?.lowercased() == "https" ? 443 : 80))
                == (right.port ?? (right.scheme?.lowercased() == "https" ? 443 : 80))
    }

    private static func validHeaderName(_ name: String) -> Bool {
        !name.isEmpty
            && name.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    || "!#$%&'*+-.^_`|~".utf8.contains($0)
            }
    }

    static func filename(response: HTTPURLResponse, fallback: String?) -> String {
        // Foundation parses Content-Disposition (including filename*) and the response URL for us.
        let suggested = basename(response.suggestedFilename)
        let urlName = basename(response.url?.lastPathComponent)
        let fallback = basename(fallback)
        let hasDisposition = response.value(forHTTPHeaderField: "Content-Disposition") != nil
        let responseNames = hasDisposition ? [suggested, urlName] : [urlName, suggested]
        let responseSuffix = responseNames.compactMap { usefulSuffix($0) }.first
        let mimeSuffix = response.mimeType.flatMap { UTType(mimeType: $0)?.preferredFilenameExtension }
            .flatMap { usefulSuffix("file.\($0)") }
        let genericSuffix = [suggested, urlName, fallback].compactMap { safeSuffix($0) }
            .first { ["bin", "dat"].contains($0) }
        let suffix = responseSuffix ?? mimeSuffix ?? usefulSuffix(fallback) ?? genericSuffix ?? "bin"
        let proposed =
            responseNames.compactMap { $0 }.first { usefulSuffix($0) != nil }
            ?? fallback ?? suggested ?? "download"
        return filename(proposed: proposed, suffix: suffix)
    }

    static func filename(fallback: String?) -> String {
        let fallback = basename(fallback)
        let genericSuffix = safeSuffix(fallback).flatMap { ["bin", "dat"].contains($0) ? $0 : nil }
        let suffix = usefulSuffix(fallback) ?? genericSuffix ?? "bin"
        return filename(proposed: fallback ?? "download", suffix: suffix)
    }

    private static func filename(proposed: String, suffix: String) -> String {
        let stem = (proposed as NSString).deletingPathExtension
            .trimmingCharacters(in: CharacterSet(charactersIn: " ._-"))
        var shortStem = ""
        for character in stem {
            let next = String(character)
            guard shortStem.utf8.count + next.utf8.count <= 160 else { break }
            shortStem += next
        }
        return "\(shortStem.isEmpty ? "download" : shortStem).\(suffix)"
    }

    private static func basename(_ proposed: String?) -> String? {
        guard let proposed else { return nil }
        let component =
            (proposed.precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
        let allowed = CharacterSet.alphanumerics.union(.nonBaseCharacters)
            .union(CharacterSet(charactersIn: " -_().[]"))
        let result = String(component.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" })
            .trimmingCharacters(in: CharacterSet(charactersIn: " ._-"))
        return result.isEmpty ? nil : result
    }

    private static func usefulSuffix(_ name: String?) -> String? {
        guard let suffix = safeSuffix(name) else { return nil }
        let placeholders: Set<String> = ["bin", "dat", "php", "asp", "aspx", "jsp", "cgi", "do", "action"]
        return placeholders.contains(suffix) ? nil : suffix
    }

    private static func safeSuffix(_ name: String?) -> String? {
        guard let name else { return nil }
        let suffix = (name as NSString).pathExtension.lowercased()
        guard !suffix.isEmpty, suffix.utf8.count <= 16,
            suffix.utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) })
        else { return nil }
        return suffix
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "io.legado.web-book.file", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
