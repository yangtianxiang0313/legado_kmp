import Foundation
import shared

/// All mutable session state and body accumulation are confined to queue.
final class HLSResourceHTTPTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct RedirectPlan: Sendable {
        let target: URL
        let method: String
        let body: Data?
        let sameOrigin: Bool
        let allowsPrivate: Bool
        let strippedEntity: Bool
    }

    private enum Preparation: Sendable {
        case initial([String: String])
        case response(HTTPURLResponse)
        case redirect(RedirectPlan, [String: String])
    }

    private let queue = DispatchQueue(label: "io.legado.hls.resource", qos: .userInitiated)
    private let cancellation = HLSResourceHTTPCancellation()
    private let input: HLSResourceHTTPPolicy.Input
    private var facade: MediaResourceFacade?
    private var currentRequest: URLRequest
    private var currentPrepared: PreparedMediaRequest
    private var continuation: CheckedContinuation<HLSResourceResponse, Error>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var deadline: DispatchSourceTimer?
    private var preparationID: UUID?
    private var preparationTask: Task<Preparation, Error>?
    private var redirectCompletion: ((URLRequest?) -> Void)?
    private var responseCompletion: ((URLSession.ResponseDisposition) -> Void)?
    private var response: HLSResourceHTTPPolicy.Response?
    private var body = Data()
    private var redirects = 0
    private var failure: Error?
    private var result: Result<HLSResourceResponse, Error>?
    private var started = false
    private var invalidating = false
    private var sessionInvalidated = true
    private var finished = false

    init(input: HLSResourceHTTPPolicy.Input) {
        self.input = input
        currentRequest = input.request
        currentPrepared = input.initialPrepared
        super.init()
    }

    func load() async throws -> HLSResourceResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { self.start(continuation) }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        guard cancellation.cancel() else { return }
        queue.async { self.stop(CancellationError()) }
    }

    func waitUntilFinished() async {
        await withCheckedContinuation { continuation in
            queue.async {
                if self.finished { continuation.resume() } else { self.waiters.append(continuation) }
            }
        }
    }

    private func start(_ continuation: CheckedContinuation<HLSResourceResponse, Error>) {
        guard !started else {
            continuation.resume(throwing: HLSResourceHTTPError.invalidRequest)
            return
        }
        started = true
        self.continuation = continuation
        do {
            try cancellation.check()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + HLSResourceHTTPPolicy.maximumDuration)
            timer.setEventHandler { [weak self] in self?.stop(HLSResourceHTTPError.timeout) }
            deadline = timer
            timer.resume()
            let current = currentPrepared
            let target = currentRequest.url!
            let facade = try MediaResourceFacade.companion.create()
            self.facade = facade
            prepare {
                try Task.checkCancellation()
                let headers = try await facade.headersForURL(request: current, targetUrl: target.absoluteString)
                try Task.checkCancellation()
                return .initial(headers)
            }
        } catch {
            stop(error)
        }
    }

    private func beginSession() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = currentRequest.timeoutInterval
        configuration.timeoutIntervalForResource = HLSResourceHTTPPolicy.maximumDuration
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 1
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = queue
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        self.session = session
        sessionInvalidated = false
        let task = session.dataTask(with: currentRequest)
        self.task = task
        task.resume()
    }

    private func prepare(_ operation: @escaping () async throws -> Preparation) {
        let id = UUID()
        preparationID = id
        let task = Task { try await operation() }
        preparationTask = task
        // Await the worker's terminal state, not just an enqueued callback from inside that worker.
        Task { [weak self] in
            let result = await task.result
            guard let self else { return }
            self.queue.async { self.preparationEnded(id, result: result) }
        }
    }

    private func preparationEnded(_ id: UUID, result: Result<Preparation, Error>) {
        guard preparationID == id else { return }
        preparationID = nil
        preparationTask = nil
        guard failure == nil, self.result == nil, !finished else {
            resolveIfFinished()
            return
        }
        do {
            try cancellation.check()
            switch try result.get() {
            case let .initial(headers):
                let url = currentRequest.url!
                currentRequest = try HLSResourceHTTPPolicy.request(
                    url: url, method: currentRequest.httpMethod ?? "GET", body: currentRequest.httpBody,
                    headers: headers, timeout: input.request.timeoutInterval,
                    allowsPrivate: HLSResourceHTTPPolicy.sameOrigin(input.headerOrigin, url), range: input.range)
                currentPrepared = input.snapshot(currentRequest, explicitCookie: currentPrepared.resourceContext?.explicitCookie)
                beginSession()
            case let .response(response):
                self.response = try HLSResourceHTTPPolicy.Response(response, request: currentRequest, range: input.range)
                endResponse(.allow)
            case let .redirect(plan, headers):
                let next = try HLSResourceHTTPPolicy.request(
                    url: plan.target, method: plan.method, body: plan.body, headers: headers,
                    timeout: input.request.timeoutInterval, allowsPrivate: plan.allowsPrivate,
                    range: input.range, strippedEntity: plan.strippedEntity)
                currentRequest = next
                currentPrepared = input.snapshot(
                    next, explicitCookie: plan.sameOrigin ? currentPrepared.resourceContext?.explicitCookie : nil)
                redirects += 1
                endRedirect(next)
            }
        } catch {
            stop(error)
        }
    }

    private func stop(_ error: Error) {
        guard !finished else { return }
        if failure == nil { failure = safeError(error) }
        preparationTask?.cancel()
        endRedirect(nil)
        endResponse(.cancel)
        body = Data()
        result = nil
        task?.cancel()
        if let session, !invalidating {
            invalidating = true
            session.invalidateAndCancel()
        }
        resolveIfFinished()
    }

    private func resolveIfFinished() {
        guard started, !finished, sessionInvalidated, preparationTask == nil,
            failure != nil || result != nil
        else { return }
        endRedirect(nil)
        endResponse(.cancel)
        deadline?.cancel()
        deadline = nil
        task = nil
        session = nil
        facade = nil
        body = Data()
        let outcome = cancellation.publish(result ?? .failure(failure ?? HLSResourceHTTPError.network))
        result = nil
        finished = true
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(with: outcome)
        let waiters = waiters
        self.waiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func urlSession(
        _: URLSession, dataTask _: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        do {
            try cancellation.check()
            guard failure == nil, result == nil, !finished, self.response == nil,
                preparationTask == nil, responseCompletion == nil, redirectCompletion == nil,
                let response = response as? HTTPURLResponse, let url = response.url, url == currentRequest.url,
                let facade
            else { throw HLSResourceHTTPError.invalidResponse }
            let cookies = try HLSResourceHTTPPolicy.setCookieHeaders(response)
            let current = currentPrepared
            responseCompletion = completionHandler
            prepare {
                try Task.checkCancellation()
                // Record the actual response even if its status, encoding or size will be refused.
                try await facade.recordResponseCookies(
                    request: current, responseUrl: url.absoluteString, setCookieHeaders: cookies)
                try Task.checkCancellation()
                return .response(response)
            }
        } catch {
            completionHandler(.cancel)
            stop(error)
        }
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil, result == nil, !finished else { return }
        do {
            try cancellation.check()
            guard let response else { throw HLSResourceHTTPError.invalidResponse }
            guard data.count <= HLSResourceHTTPPolicy.maximumBytes - body.count else {
                throw HLSResourceHTTPError.tooLarge
            }
            if let expected = response.expectedBytes, data.count > expected - body.count {
                throw HLSResourceHTTPError.invalidResponse
            }
            body.append(data)
        } catch {
            stop(error)
        }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        guard !finished else { return }
        do {
            try cancellation.check()
            if let failure { throw failure }
            if let error { throw error }
            guard preparationTask == nil, let response else { throw HLSResourceHTTPError.invalidResponse }
            guard !body.isEmpty else { throw HLSResourceHTTPError.empty }
            if let expected = response.expectedBytes, body.count != expected { throw HLSResourceHTTPError.invalidResponse }
            var headers = response.headers
            headers["Content-Length"] = String(body.count)
            result = .success(
                HLSResourceResponse(
                    url: response.url, statusCode: response.statusCode, headers: headers, body: body,
                    finalRequest: currentPrepared))
            body = Data()
            if !invalidating {
                invalidating = true
                session?.finishTasksAndInvalidate()
            }
        } catch {
            stop(error)
        }
    }

    func urlSession(_: URLSession, didBecomeInvalidWithError error: Error?) {
        guard !finished else { return }
        sessionInvalidated = true
        if let error, failure == nil { failure = safeError(error); result = nil }
        if failure == nil, result == nil { failure = HLSResourceHTTPError.network }
        preparationTask?.cancel()
        endRedirect(nil)
        endResponse(.cancel)
        resolveIfFinished()
    }

    func urlSession(
        _: URLSession, task _: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest proposed: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        do {
            try cancellation.check()
            guard failure == nil, result == nil, !finished, preparationTask == nil,
                redirectCompletion == nil, responseCompletion == nil,
                let from = currentRequest.url, response.url == from, let facade
            else { throw HLSResourceHTTPError.unsupportedRedirect }
            let cookies = try HLSResourceHTTPPolicy.setCookieHeaders(response)
            let plan = Result { try redirectPlan(response: response, proposed: proposed, from: from) }
            let current = currentPrepared
            redirectCompletion = completionHandler
            prepare {
                try Task.checkCancellation()
                try await facade.recordResponseCookies(
                    request: current, responseUrl: from.absoluteString, setCookieHeaders: cookies)
                try Task.checkCancellation()
                let next = try plan.get()
                let headers = try await facade.headersForURL(request: current, targetUrl: next.target.absoluteString)
                try Task.checkCancellation()
                return .redirect(next, headers)
            }
        } catch {
            completionHandler(nil)
            stop(error)
        }
    }

    private func redirectPlan(response: HTTPURLResponse, proposed: URLRequest, from: URL) throws -> RedirectPlan {
        guard redirects < 10, [301, 302, 303, 307, 308].contains(response.statusCode),
            let proposedURL = proposed.url, let target = try? HLSResourceHTTPPolicy.networkURL(proposedURL),
            !(from.scheme?.lowercased() == "https" && target.scheme?.lowercased() != "https")
        else { throw HLSResourceHTTPError.unsupportedRedirect }
        let rewritten =
            response.statusCode == 303
            || ([301, 302].contains(response.statusCode) && currentRequest.httpMethod == "POST")
        let method = rewritten ? "GET" : (currentRequest.httpMethod ?? "GET")
        let body = rewritten ? nil : currentRequest.httpBody
        let sameOrigin = HLSResourceHTTPPolicy.sameOrigin(from, target)
        guard sameOrigin || (method == "GET" && body == nil) else { throw HLSResourceHTTPError.unsupportedRedirect }
        return RedirectPlan(
            target: target, method: method, body: body, sameOrigin: sameOrigin,
            allowsPrivate: sameOrigin && HLSResourceHTTPPolicy.sameOrigin(input.headerOrigin, target), strippedEntity: rewritten)
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

    private func endRedirect(_ request: URLRequest?) {
        let completion = redirectCompletion
        redirectCompletion = nil
        completion?(request)
    }

    private func endResponse(_ disposition: URLSession.ResponseDisposition) {
        let completion = responseCompletion
        responseCompletion = nil
        completion?(disposition)
    }

    private func safeError(_ error: Error) -> Error {
        if cancellation.isCancelled || error is CancellationError { return CancellationError() }
        if let error = error as? HLSResourceHTTPError { return error }
        let native = error as NSError
        if native.domain == NSURLErrorDomain {
            if native.code == NSURLErrorCancelled { return CancellationError() }
            if native.code == NSURLErrorTimedOut { return HLSResourceHTTPError.timeout }
        }
        // Do not expose NSError userInfo, which can contain signed URLs or source credentials.
        return HLSResourceHTTPError.network
    }
}

private final class HLSResourceHTTPCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var published = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !published else { return false }
        cancelled = true
        return true
    }

    func check() throws {
        if isCancelled { throw CancellationError() }
    }

    func publish(_ result: Result<HLSResourceResponse, Error>) -> Result<HLSResourceResponse, Error> {
        lock.lock()
        defer { lock.unlock() }
        published = true
        return cancelled ? .failure(CancellationError()) : result
    }
}
