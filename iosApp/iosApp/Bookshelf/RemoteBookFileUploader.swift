import Foundation

struct RemoteBookFileUploadReceipt: Sendable {
    let responseURL: String
    let statusCode: Int
    let bytesSent: Int64
}

struct RemoteBookFileUploadFailure: LocalizedError, Sendable {
    let wasDispatched: Bool
    let wasConfirmed: Bool
    let statusCode: Int?
    let receipt: RemoteBookFileUploadReceipt?
    private let message: String

    var errorDescription: String? { message }

    /// Shared completion/validation must not turn a native acknowledgement into an unconfirmed failure.
    static func completionValidationFailed(receipt: RemoteBookFileUploadReceipt) -> Self {
        Self(
            wasDispatched: true, wasConfirmed: true, statusCode: receipt.statusCode, receipt: receipt,
            message: "服务器已确认上传，但上传结果校验未完成。请刷新远程书库确认，勿自动重试。")
    }

    enum Cause: Sendable, Equatable {
        case busy, invalidRequest, invalidFile, invalidSize, validation, cancelled, timedOut
        case fileChanged, redirect, authentication, replay, http, response, incompleteUpload, transport, session

        var description: String {
            switch self {
            case .busy: return "已有文件正在上传"
            case .invalidRequest: return "上传请求不符合安全要求"
            case .invalidFile: return "本地文件不可读取或不是安全的普通文件"
            case .invalidSize: return "上传文件大小必须为 1 字节至 2 GiB"
            case .validation: return "远程书库会话校验未通过"
            case .cancelled: return "上传已取消"
            case .timedOut: return "上传超时"
            case .fileChanged: return "上传期间本地文件发生变化"
            case .redirect: return "已拒绝上传重定向"
            case .authentication: return "服务器身份验证未通过"
            case .replay: return "已拒绝重新发送上传正文"
            case .http: return "服务器未确认上传成功"
            case .response: return "上传响应无效或不完整"
            case .incompleteUpload: return "上传发送长度与文件长度不符"
            case .transport: return "上传连接未正常完成"
            case .session: return "上传会话未正常结束"
            }
        }
    }

    static func make(
        _ cause: Cause, dispatched: Bool = false, receipt: RemoteBookFileUploadReceipt? = nil,
        statusCode: Int? = nil
    ) -> Self {
        let detail = cause.description + (statusCode.map { "（HTTP \($0)）" } ?? "")
        let message: String
        if receipt != nil {
            message = "服务器已确认上传，但未正常完成：\(detail)。请刷新远程书库确认，勿自动重试。"
        } else if dispatched {
            message = "\(detail)。文件可能已上传，请刷新远程书库确认，勿自动重试。"
        } else {
            message = "\(detail)，尚未发送文件。"
        }
        return Self(
            wasDispatched: dispatched || receipt != nil, wasConfirmed: receipt != nil,
            statusCode: receipt?.statusCode ?? statusCode, receipt: receipt, message: message)
    }
}

/// The caller owns the LocalBookFileStore lease until upload returns, including cancellation.
@MainActor
final class RemoteBookFileUploader {
    private var active: RemoteBookFileUploadGate?

    func upload(
        request: URLRequest, fileURL: URL, byteCount: Int64,
        validate: @escaping @MainActor () async throws -> Void,
        onProgress: @escaping @MainActor (Int64, Int64) -> Void
    ) async throws -> RemoteBookFileUploadReceipt {
        guard active == nil else { throw RemoteBookFileUploadFailure.make(.busy) }
        let gate = RemoteBookFileUploadGate()
        let progress = RemoteBookFileUploadProgress(gate: gate, callback: onProgress)
        active = gate
        defer {
            gate.stopProgress()
            gate.detach()
            active = nil
        }

        return try await withTaskCancellationHandler {
            try gate.check()
            let nativeRequest = try RemoteBookFileUploadPolicy.request(request, byteCount: byteCount)
            let source = try RemoteBookFileUploadSource(url: fileURL, byteCount: byteCount)
            // The transfer resumes only after BOTH task completion and session invalidation.
            defer { source.close() }
            let validation = RemoteBookFileUploadValidation(gate: gate)
            gate.attach(validation)
            try await validation.run(validate)
            try gate.check()
            try source.verify()
            let transfer = RemoteBookFileUploadTransfer(
                request: nativeRequest, source: source, gate: gate, progress: progress)
            gate.attach(transfer)
            return try await transfer.upload()
        } onCancel: {
            gate.cancel()
        }
    }

    func cancel() {
        active?.cancel()
    }
}

/// Only this gate is shared between the main actor, cancellation handlers and the delegate queue.
final class RemoteBookFileUploadGate: @unchecked Sendable {
    private let lock = NSLock()
    private let deadline = ProcessInfo.processInfo.systemUptime + RemoteBookFileUploadPolicy.maximumDuration
    private var cancelled = false
    private var progressStopped = false
    private weak var transfer: RemoteBookFileUploadTransfer?
    private weak var validation: RemoteBookFileUploadValidation?

    var remainingDuration: TimeInterval { max(0, deadline - ProcessInfo.processInfo.systemUptime) }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    var allowsProgress: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !cancelled && !progressStopped
    }

    func check() throws {
        lock.lock()
        defer { lock.unlock() }
        try checkLocked()
    }

    private func checkLocked() throws {
        if cancelled { throw RemoteBookFileUploadFailure.make(.cancelled) }
        if remainingDuration <= 0 { throw RemoteBookFileUploadFailure.make(.timedOut) }
    }

    func dispatch(_ start: () -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        try checkLocked()
        // Cancellation either wins before resume, or observes an already-dispatched request.
        start()
    }

    func attach(_ transfer: RemoteBookFileUploadTransfer) {
        lock.lock()
        self.transfer = transfer
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { transfer.cancel() }
    }

    func attach(_ validation: RemoteBookFileUploadValidation) {
        lock.lock()
        self.validation = validation
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { validation.cancel() }
    }

    func detach() {
        lock.lock()
        transfer = nil
        validation = nil
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        progressStopped = true
        let transfer = transfer
        let validation = validation
        lock.unlock()
        validation?.cancel()
        transfer?.cancel()
    }

    func stopProgress() {
        lock.lock()
        progressStopped = true
        lock.unlock()
    }
}

/// A stalled metadata validator cannot consume the whole operation's deadline or launch a late PUT.
/// Cancelling before dispatch can return immediately: this validator never receives the file or its lease.
final class RemoteBookFileUploadValidation: @unchecked Sendable {
    private let gate: RemoteBookFileUploadGate
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: Task<Void, Never>?
    private var timer: DispatchSourceTimer?
    private var result: Result<Void, Error>?

    init(gate: RemoteBookFileUploadGate) { self.gate = gate }

    func run(_ validate: @escaping @MainActor () async throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
                return
            }
            self.continuation = continuation
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + gate.remainingDuration)
            timer.setEventHandler { [weak self] in self?.finish(.failure(RemoteBookFileUploadFailure.make(.timedOut))) }
            self.timer = timer
            task = Task { @MainActor [self] in
                do {
                    try gate.check()
                    try await validate()
                    try gate.check()
                    finish(.success(()))
                } catch {
                    do {
                        try gate.check()
                        finish(.failure(RemoteBookFileUploadFailure.make(.validation)))
                    } catch {
                        finish(.failure(error))
                    }
                }
            }
            timer.resume()
            lock.unlock()
        }
    }

    func cancel() { finish(.failure(RemoteBookFileUploadFailure.make(.cancelled))) }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = continuation
        let task = task
        let timer = timer
        self.continuation = nil
        self.task = nil
        self.timer = nil
        lock.unlock()
        timer?.setEventHandler {}
        timer?.cancel()
        if case .failure = result { task?.cancel() }
        continuation?.resume(with: result)
    }
}

@MainActor
final class RemoteBookFileUploadProgress {
    private let gate: RemoteBookFileUploadGate
    private let callback: @MainActor (Int64, Int64) -> Void
    private var lastBytes: Int64 = -1

    init(gate: RemoteBookFileUploadGate, callback: @escaping @MainActor (Int64, Int64) -> Void) {
        self.gate = gate
        self.callback = callback
    }

    func publish(_ sent: Int64, total: Int64) {
        guard gate.allowsProgress, sent > lastBytes else { return }
        lastBytes = sent
        callback(sent, total)
    }
}
