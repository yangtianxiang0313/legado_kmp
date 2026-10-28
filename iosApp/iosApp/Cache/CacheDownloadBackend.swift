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

    func stop(bookURL: String)
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

    private func resolveSharedRuntime() throws -> CacheFacade {
        if let facade { return facade }
        // SharedRuntime.cacheFacade() resolves a factory, not a singleton.
        let resolved = try SharedRuntime.cacheFacade().get()
        facade = resolved
        return resolved
    }
}
