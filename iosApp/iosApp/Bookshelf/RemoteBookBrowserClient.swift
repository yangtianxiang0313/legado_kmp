import Foundation
import shared

struct RemoteBookDownloadedFile {
    let url: URL
    let remoteOrigin: String
}

@MainActor
final class RemoteBookBrowserClient {
    private let facade: RemoteBookTransferFacade
    private var session: RemoteBookSession?
    private var loader: WebBookFileLoader?
    private var uploader: RemoteBookFileUploader?
    private var downloading = false
    private var uploading = false

    init() throws {
        facade = try RemoteBookTransferFacade.companion.create()
    }

    func list(path: String?) async throws -> [RemoteBook] {
        let session = try await currentSession()
        let result = try await request { onResult in
            facade.listRequest(sessionId: session.id, path: path, onResult: onResult)
        }
        try Task.checkCancellation()
        return result.books
    }

    func download(
        _ remoteBook: RemoteBook, onProgress: @escaping @MainActor (Int64, Int64?) -> Void
    ) async throws -> RemoteBookDownloadedFile {
        guard !downloading, !uploading else { throw Self.failure("已有远程文件正在传输") }
        downloading = true
        defer { downloading = false }
        let session = try await currentSession()
        let result = try await request { onResult in
            facade.prepareDownloadRequest(sessionId: session.id, remoteBook: remoteBook, onResult: onResult)
        }
        guard let prepared = result.request else { throw Self.failure("远程文件请求未返回") }
        let origin = try await facade.remoteOrigin(sessionId: session.id, remoteBook: remoteBook)
        try Task.checkCancellation()
        let transfer = WebBookFileLoader()
        loader = transfer
        defer { if loader === transfer { loader = nil } }
        let file = try await transfer.load(
            prepared,
            prepareRedirect: { [facade] current, target in
                try Task.checkCancellation()
                return try await facade.prepareRedirect(
                    sessionId: session.id, request: current, targetUrl: target.absoluteString)
            },
            onProgress: onProgress)
        // Publication has already succeeded. A changed session must not trigger deletion of this file.
        try Task.checkCancellation()
        try await facade.validateSession(sessionId: session.id)
        return RemoteBookDownloadedFile(url: file, remoteOrigin: origin)
    }

    func upload(
        _ url: URL, onProgress: @escaping @MainActor (Int64, Int64) -> Void = { _, _ in }
    ) async throws -> RemoteBook {
        guard !uploading, !downloading else { throw Self.failure("已有远程文件正在传输") }
        uploading = true
        defer { uploading = false }
        let session = try await currentSession()
        let file = try await LocalBookFileStore.prepareForUpload(from: url)
        var prepared: PreparedRemoteBookUpload?
        var serverConfirmed = false
        do {
            try Task.checkCancellation()
            let result = try await request { onResult in
                facade.prepareUploadFileRequest(sessionId: session.id, path: file.url.path, onResult: onResult)
            }
            guard let upload = result.upload else { throw Self.failure("远程上传请求未返回") }
            prepared = upload
            try Task.checkCancellation()
            guard let target = URL(string: upload.url) else { throw Self.failure("远程上传地址无效") }
            var request = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
            request.httpMethod = "PUT"
            for (name, value) in upload.headers { request.setValue(value, forHTTPHeaderField: name) }
            let transfer = RemoteBookFileUploader()
            uploader = transfer
            defer { if uploader === transfer { uploader = nil } }
            let receipt = try await transfer.upload(
                request: request, fileURL: file.url, byteCount: upload.byteCount,
                validate: { [self] in
                    _ = try await self.request { facade.validateUploadFileRequest(upload: upload, onResult: $0) }
                }, onProgress: onProgress)
            serverConfirmed = true
            // Acknowledged PUT wins over a late Swift cancellation; wait for the real shared finish.
            let uploaded: RemoteBook = try await SharedAsync.value {
                facade.finishUploadFile(
                    upload: upload, responseUrl: receipt.responseURL, statusCode: Int32(receipt.statusCode), completionHandler: $0
                )
            }
            try? await SharedAsync.void { facade.discardUploadFile(upload: upload, completionHandler: $0) }
            await LocalBookFileStore.discard(file)
            return uploaded
        } catch {
            if let prepared {
                try? await SharedAsync.void { facade.discardUploadFile(upload: prepared, completionHandler: $0) }
            }
            // The uploader has drained native invalidation before this lease can be released.
            await LocalBookFileStore.discard(file)
            if serverConfirmed { throw RemoteBookUploadOutcomeError(confirmed: true) }
            if let failure = error as? RemoteBookFileUploadFailure, failure.wasDispatched {
                throw RemoteBookUploadOutcomeError(confirmed: failure.wasConfirmed)
            }
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    func delete(_ remoteBook: RemoteBook) async throws {
        let session = try await currentSession()
        _ = try await request { onResult in
            facade.deleteRequest(sessionId: session.id, remoteBook: remoteBook, onResult: onResult)
        }
    }

    func associate(_ book: Book, remoteOrigin: String) async throws -> Book {
        try Task.checkCancellation()
        return try await RemoteBookImportFacade.companion.create().associateImportedBook(
            remoteOrigin: remoteOrigin, expectedLocalBook: book)
    }

    func cancel() {
        // Each Swift task cancels only its own Kotlin request. Parent/child pages share this client.
        loader?.cancel()
        uploader?.cancel()
    }

    private func currentSession() async throws -> RemoteBookSession {
        try Task.checkCancellation()
        if let session {
            try await facade.validateSession(sessionId: session.id)
            return session
        }
        let result = try await request { onResult in facade.openSessionRequest(onResult: onResult) }
        guard let opened = result.session else { throw Self.failure("远程书库会话未返回") }
        try Task.checkCancellation()
        session = opened
        return opened
    }

    private func request(
        _ start: (@escaping (RemoteBookTransferResult) -> Void) -> FlowSubscription
    ) async throws -> RemoteBookTransferResult {
        let state = RemoteBookTerminalRequest()
        let result = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                state.install(continuation)
                let subscription = start { result in state.finish(result) }
                state.attach(subscription)
            }
        } onCancel: {
            state.cancel()
        }
        if result.isCancelled { throw CancellationError() }
        if let message = result.errorMessage { throw Self.failure(message) }
        return result
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "io.legado.remote-book", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

struct RemoteBookUploadOutcomeError: LocalizedError {
    let confirmed: Bool

    var errorDescription: String? {
        confirmed
            ? "服务器已确认上传，但操作未正常返回；请刷新原远程书库确认，勿重复上传。"
            : "上传结果未知，远端可能已写入文件；取消不会撤销上传，请刷新原远程书库确认，勿直接重试。"
    }
}

/// A source lease must outlive cancellation until the Kotlin job's actual terminal callback.
private final class RemoteBookTerminalRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<RemoteBookTransferResult, Error>?
    private var subscription: FlowSubscription?
    private var cancelled = false
    private var completed = false

    func install(_ continuation: CheckedContinuation<RemoteBookTransferResult, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func attach(_ subscription: FlowSubscription) {
        lock.lock()
        let shouldCancel = cancelled && !completed
        if !completed { self.subscription = subscription }
        lock.unlock()
        if shouldCancel { subscription.cancel() }
    }

    func finish(_ result: RemoteBookTransferResult) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let continuation = continuation
        let subscription = subscription
        self.continuation = nil
        self.subscription = nil
        lock.unlock()
        withExtendedLifetime(subscription) { continuation?.resume(returning: result) }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let subscription = subscription
        lock.unlock()
        subscription?.cancel()
    }
}
