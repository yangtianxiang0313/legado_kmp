import Foundation
import shared

@MainActor
protocol CacheDownloadBackend {
    // Returning must mean the download has unwound, not merely acknowledged a stop request.
    func download(
        bookURL: String,
        startIndex: Int32,
        endIndex: Int32,
        onProgress: @escaping (CacheProgress) -> Void
    ) async throws -> BookDownloadSummary

    func downloadAutomatically(
        bookURL: String, startIndex: Int32, endIndex: Int32,
        onProgress: @escaping (CacheProgress) -> Void
    ) async throws -> BookDownloadSummary

    func stop(bookURL: String)
}

extension CacheDownloadBackend {
    func downloadAutomatically(
        bookURL: String, startIndex: Int32, endIndex: Int32,
        onProgress: @escaping (CacheProgress) -> Void
    ) async throws -> BookDownloadSummary {
        try await download(bookURL: bookURL, startIndex: startIndex, endIndex: endIndex, onProgress: onProgress)
    }
}

@MainActor
protocol CacheAutomaticDownloadObserver: AnyObject {
    func cacheManualDownloadWillStart(bookURL: String)
    func cacheDownloadStopRequested(bookURL: String?)
    func cacheAutomaticDownloadDidFinish(bookURL: String)
}

@MainActor
final class SharedCacheDownloadBackend: CacheDownloadBackend {
    private var facade: CacheFacade?

    func download(
        bookURL: String,
        startIndex: Int32,
        endIndex: Int32,
        onProgress: @escaping (CacheProgress) -> Void
    ) async throws -> BookDownloadSummary {
        try Task.checkCancellation()
        let facade = try resolveSharedRuntime()
        try Task.checkCancellation()
        try await facade.startDownload(
            bookUrl: bookURL,
            startIndex: startIndex,
            endIndex: endIndex,
            onProgress: onProgress
        )
        // Do not discard a real final summary just because stop was requested meanwhile.
        return try await facade.getDownloadSummaryForBook(bookUrl: bookURL)
    }

    func stop(bookURL: String) {
        facade?.stopDownload(bookUrl: bookURL)
    }

    func downloadAutomatically(
        bookURL: String, startIndex: Int32, endIndex: Int32,
        onProgress: @escaping (CacheProgress) -> Void
    ) async throws -> BookDownloadSummary {
        try Task.checkCancellation()
        let facade = try resolveSharedRuntime()
        let terminal = CacheDownloadTerminalRequest()
        return try await withTaskCancellationHandler {
            try await SharedAsync.value { completion in
                terminal.install(
                    AutomaticBookCacheRequest(facade: facade).download(
                        bookUrl: bookURL, startIndex: startIndex, endIndex: endIndex,
                        onProgress: onProgress
                    ) { result in
                        terminal.finish()
                        if result.isCancelled {
                            completion(nil, CancellationError())
                        } else if let summary = result.summary {
                            completion(summary, nil)
                        } else {
                            completion(
                                nil,
                                NSError(
                                    domain: "io.legado.automatic-cache", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: result.errorMessage ?? "自动缓存失败，请重试"]))
                        }
                    })
            }
        } onCancel: {
            terminal.cancel()
        }
    }

    private func resolveSharedRuntime() throws -> CacheFacade {
        if let facade { return facade }
        // SharedRuntime.cacheFacade() resolves a factory, not a singleton.
        let resolved = try SharedRuntime.cacheFacade().get()
        facade = resolved
        return resolved
    }
}

private final class CacheDownloadTerminalRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var subscription: FlowSubscription?
    private var cancelled = false
    private var finished = false

    func install(_ subscription: FlowSubscription) {
        lock.lock()
        if !finished { self.subscription = subscription }
        let shouldCancel = cancelled && !finished
        lock.unlock()
        if shouldCancel { subscription.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let active = finished ? nil : subscription
        lock.unlock()
        active?.cancel()
    }

    func finish() {
        lock.lock()
        finished = true
        subscription = nil
        lock.unlock()
    }
}
