import Foundation

/// All native task/session state and file inspections are confined to queue.
final class RemoteBookFileUploadTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private typealias Cause = RemoteBookFileUploadFailure.Cause

    private let queue = DispatchQueue(label: "io.legado.remote-book.upload", qos: .utility)
    private let request: URLRequest
    private let source: RemoteBookFileUploadSource
    private let gate: RemoteBookFileUploadGate
    private let progress: RemoteBookFileUploadProgress
    private var continuation: CheckedContinuation<RemoteBookFileUploadReceipt, Error>?
    private var session: URLSession?
    private var task: URLSessionUploadTask?
    private var deadlineTimer: DispatchSourceTimer?
    private var inspectionTimer: DispatchSourceTimer?
    private var started = false
    private var dispatched = false
    private var invalidating = false
    private var taskTerminal = false
    private var sessionTerminal = false
    private var sessionFailed = false
    private var cause: Cause?
    private var statusCode: Int?
    private var acknowledgedResponse: HTTPURLResponse?
    private var responseSeen = false
    private var expectedResponseBytes: Int64?
    private var responseBytes: Int64 = 0
    private var sentBytes: Int64 = 0
    private var lastProgressTime: TimeInterval = -.infinity
    private var result: Result<RemoteBookFileUploadReceipt, Error>?

    init(
        request: URLRequest, source: RemoteBookFileUploadSource, gate: RemoteBookFileUploadGate,
        progress: RemoteBookFileUploadProgress
    ) {
        self.request = request
        self.source = source
        self.gate = gate
        self.progress = progress
        super.init()
    }

    func upload() async throws -> RemoteBookFileUploadReceipt {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { self.start(continuation) }
        }
    }

    func cancel() {
        queue.async { self.stop(.cancelled) }
    }

    private func start(_ continuation: CheckedContinuation<RemoteBookFileUploadReceipt, Error>) {
        guard !started else {
            continuation.resume(throwing: RemoteBookFileUploadFailure.make(.busy))
            return
        }
        started = true
        self.continuation = continuation
        do {
            try gate.check()
            try source.verify()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.httpCookieAcceptPolicy = .never
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = RemoteBookFileUploadPolicy.idleTimeout
            configuration.timeoutIntervalForResource = gate.remainingDuration
            configuration.waitsForConnectivity = false
            configuration.httpMaximumConnectionsPerHost = 1
            let delegateQueue = OperationQueue()
            delegateQueue.maxConcurrentOperationCount = 1
            delegateQueue.underlyingQueue = queue
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
            self.session = session
            let task = session.uploadTask(with: request, fromFile: source.url)
            self.task = task
            installTimers()
            try gate.dispatch {
                dispatched = true
                task.resume()
            }
            publishProgress()
        } catch {
            if let failure = error as? RemoteBookFileUploadFailure {
                if session == nil {
                    result = .failure(failure)
                    taskTerminal = true
                    sessionTerminal = true
                    resolveIfTerminal()
                } else {
                    stop(gate.isCancelled ? .cancelled : .timedOut)
                }
            } else {
                stop(.invalidFile)
            }
        }
    }

    private func installTimers() {
        let deadline = DispatchSource.makeTimerSource(queue: queue)
        deadline.schedule(deadline: .now() + gate.remainingDuration)
        deadline.setEventHandler { [weak self] in self?.stop(.timedOut) }
        deadlineTimer = deadline
        deadline.resume()
        let inspection = DispatchSource.makeTimerSource(queue: queue)
        inspection.schedule(deadline: .now() + 1, repeating: 1)
        inspection.setEventHandler { [weak self] in
            guard let self, !self.taskTerminal, self.cause == nil else { return }
            do { try self.source.verify() } catch { self.stop(.fileChanged) }
        }
        inspectionTimer = inspection
        inspection.resume()
    }

    private func stopTimers() {
        deadlineTimer?.setEventHandler {}
        deadlineTimer?.cancel()
        deadlineTimer = nil
        inspectionTimer?.setEventHandler {}
        inspectionTimer?.cancel()
        inspectionTimer = nil
    }

    private func stop(_ reason: Cause) {
        guard continuation != nil, !taskTerminal else { return }
        // Drain cancellation even while a confirmed server trickles its response body.
        // receipt() retains that acknowledgement, so it is never reported as an unconfirmed cancellation.
        if cause == nil || reason == .fileChanged || reason == .replay { cause = reason }
        gate.stopProgress()
        stopTimers()
        task?.cancel()
        invalidate(cancel: true)
        if session == nil {
            taskTerminal = true
            sessionTerminal = true
            result = .failure(failure(reason))
            resolveIfTerminal()
        }
    }

    private func invalidate(cancel: Bool) {
        guard let session, !invalidating else { return }
        invalidating = true
        if cancel { session.invalidateAndCancel() } else { session.finishTasksAndInvalidate() }
    }

    func urlSession(
        _: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard !taskTerminal, dataTask === task, !responseSeen,
            let response = response as? HTTPURLResponse, response.url == request.url,
            dataTask.currentRequest?.url == request.url, dataTask.currentRequest?.httpMethod == "PUT"
        else {
            completionHandler(.cancel)
            stop(.response)
            return
        }
        responseSeen = true
        statusCode = response.statusCode
        guard [200, 201, 204].contains(response.statusCode) else {
            completionHandler(.cancel)
            stop(.http)
            return
        }
        // Preserve this fact even if the local file, response framing or native terminal later fails.
        acknowledgedResponse = response
        do {
            try source.verify()
        } catch {
            completionHandler(.cancel)
            stop(.fileChanged)
            return
        }
        let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
        let transferEncoding = response.value(forHTTPHeaderField: "Transfer-Encoding")?.lowercased()
        let length = response.value(forHTTPHeaderField: "Content-Length")
        guard response.value(forHTTPHeaderField: "Content-Range") == nil,
            encoding == nil || encoding == "identity",
            transferEncoding == nil || transferEncoding == "chunked",
            transferEncoding == nil || length == nil
        else {
            completionHandler(.cancel)
            stop(.response)
            return
        }
        if let length {
            guard let count = RemoteBookFileUploadPolicy.decimal(length),
                response.statusCode != 204 || count == 0
            else {
                completionHandler(.cancel)
                stop(.response)
                return
            }
            expectedResponseBytes = count
        } else if response.statusCode == 204 {
            expectedResponseBytes = 0
        } else if response.expectedContentLength >= 0 {
            expectedResponseBytes = response.expectedContentLength
        }
        completionHandler(.allow)
    }

    func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !taskTerminal, dataTask === task, cause == nil else { return }
        let count = Int64(data.count)
        guard acknowledgedResponse != nil, count <= Int64.max - responseBytes else {
            stop(.response)
            return
        }
        responseBytes += count
        if let expectedResponseBytes, responseBytes > expectedResponseBytes { stop(.response) }
        // The response body is discarded; neither upload nor response is accumulated in memory.
    }

    func urlSession(
        _: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64, totalBytesExpectedToSend: Int64
    ) {
        guard !taskTerminal, task === self.task, cause == nil else { return }
        guard bytesSent >= 0, totalBytesSent >= sentBytes, totalBytesSent <= source.byteCount,
            totalBytesSent - sentBytes == bytesSent,
            totalBytesExpectedToSend < 0 || totalBytesExpectedToSend == source.byteCount
        else {
            stop(.replay)
            return
        }
        sentBytes = totalBytesSent
        if gate.isCancelled, acknowledgedResponse == nil {
            stop(.cancelled)
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastProgressTime >= 0.2 {
            do { try source.verify() } catch { stop(.fileChanged); return }
            publishProgress()
        }
    }

    private func publishProgress() {
        guard !taskTerminal, cause == nil, gate.allowsProgress else { return }
        lastProgressTime = ProcessInfo.processInfo.systemUptime
        let sent = sentBytes
        let total = source.byteCount
        Task { @MainActor [progress] in progress.publish(sent, total: total) }
    }

    func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === self.task, !taskTerminal else { return }
        taskTerminal = true
        gate.stopProgress()
        stopTimers()
        sentBytes = max(sentBytes, task.countOfBytesSent)
        do { try source.verify() } catch { cause = .fileChanged }
        if cause == nil, let error {
            if (error as? URLError)?.code == .timedOut {
                cause = .timedOut
            } else {
                cause = gate.isCancelled && acknowledgedResponse == nil ? .cancelled : .transport
            }
        }
        if cause == nil, acknowledgedResponse == nil { cause = .response }
        if cause == nil, sentBytes != source.byteCount { cause = .incompleteUpload }
        if cause == nil, let expectedResponseBytes, responseBytes != expectedResponseBytes { cause = .response }
        if cause == nil, sessionFailed { cause = .session }
        if let cause {
            result = .failure(failure(cause))
        } else if let receipt = receipt() {
            result = .success(receipt)
        } else {
            result = .failure(failure(.response))
        }
        invalidate(cancel: false)
        resolveIfTerminal()
    }

    func urlSession(_: URLSession, didBecomeInvalidWithError error: Error?) {
        sessionTerminal = true
        sessionFailed = error != nil
        stopTimers()
        gate.stopProgress()
        if error != nil { result = .failure(failure(cause ?? .session)) }
        if task == nil { taskTerminal = true }
        resolveIfTerminal()
    }

    private func receipt() -> RemoteBookFileUploadReceipt? {
        guard let response = acknowledgedResponse, let url = response.url else { return nil }
        return RemoteBookFileUploadReceipt(responseURL: url.absoluteString, statusCode: response.statusCode, bytesSent: sentBytes)
    }

    private func failure(_ reason: Cause) -> RemoteBookFileUploadFailure {
        RemoteBookFileUploadFailure.make(reason, dispatched: dispatched, receipt: receipt(), statusCode: statusCode)
    }

    private func resolveIfTerminal() {
        guard taskTerminal, sessionTerminal, let continuation else { return }
        do { try source.verify() } catch { result = .failure(failure(.fileChanged)) }
        self.continuation = nil
        session = nil
        task = nil
        // No file access survives this point; the uploader can now release its descriptor and caller's lease.
        continuation.resume(with: result ?? .failure(failure(cause ?? .session)))
    }

    func urlSession(
        _: URLSession, task _: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest _: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        statusCode = response.statusCode
        completionHandler(nil)
        stop(.redirect)
    }

    func urlSession(
        _: URLSession, task _: URLSessionTask, needNewBodyStream completionHandler: @escaping (InputStream?) -> Void
    ) {
        completionHandler(nil)
        stop(.replay)
    }

    @available(iOS 17.0, *)
    func urlSession(
        _: URLSession, task _: URLSessionTask, needNewBodyStreamFrom offset: Int64,
        completionHandler: @escaping (InputStream?) -> Void
    ) {
        completionHandler(nil)
        stop(.replay)
    }

    func urlSession(_: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard task === self.task else { return }
        // Detect a native resend even when no replacement-stream callback was requested for fromFile.
        if metrics.transactionMetrics.count > 1 {
            if taskTerminal {
                result = .failure(failure(.replay))
            } else {
                stop(.replay)
            }
        }
    }

    func urlSession(
        _: URLSession, task _: URLSessionTask, willBeginDelayedRequest _: URLRequest,
        completionHandler: @escaping (URLSession.DelayedRequestDisposition, URLRequest?) -> Void
    ) {
        completionHandler(.cancel, nil)
        stop(.replay)
    }

    func urlSession(
        _: URLSession, task _: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        respond(to: challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _: URLSession, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        respond(to: challenge, completionHandler: completionHandler)
    }

    private func respond(
        to challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            challenge.previousFailureCount == 0
        {
            completionHandler(.performDefaultHandling, nil)
        } else {
            // Never consult credential storage, synthesize credentials, or answer an HTTP auth retry.
            completionHandler(.cancelAuthenticationChallenge, nil)
            stop(.authentication)
        }
    }
}
