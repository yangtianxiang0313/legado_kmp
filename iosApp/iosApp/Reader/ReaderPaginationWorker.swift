import Foundation

final class ReaderPaginationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func checkCancellation() throws {
        if isCancelled { throw CancellationError() }
    }

    // Keep only the short cache/continuation commit under this gate, never layout
    // or cost estimation. Cancellation and publication have one linearization point.
    @discardableResult
    func ifNotCancelled(_ action: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        action()
        return true
    }
}

// Admission is lock-protected, not enqueued behind a busy renderer. At most one
// operation and one replaceable pending request can retain a chapter at a time.
final class ReaderPaginationWorker: @unchecked Sendable {
    private typealias PaginationResult = ReaderLayoutEngine.PaginationResult

    private final class Request: @unchecked Sendable {
        let input: ReaderPaginationInput
        let cancellation: ReaderPaginationCancellation
        private let lock = NSLock()
        private var continuation: CheckedContinuation<PaginationResult, Error>?

        init(
            input: ReaderPaginationInput,
            cancellation: ReaderPaginationCancellation,
            continuation: CheckedContinuation<PaginationResult, Error>
        ) {
            self.input = input
            self.cancellation = cancellation
            self.continuation = continuation
        }

        func finish(_ result: Result<PaginationResult, Error>) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            guard let continuation else { return }
            if !cancellation.ifNotCancelled({ continuation.resume(with: result) }) {
                continuation.resume(throwing: CancellationError())
            }
        }

        func cancel() {
            cancellation.cancel()
            finish(.failure(CancellationError()))
        }
    }

    private let queue = DispatchQueue(label: "io.legado.reader.pagination", qos: .userInitiated)
    private let lock = NSLock()
    private let cache: ReaderPaginationCache<ReaderPaginationCacheKey>
    private var active: Request?
    private var pending: Request?

    init(cache: ReaderPaginationCache<ReaderPaginationCacheKey>) {
        self.cache = cache
    }

    @MainActor
    func paginate(_ input: ReaderPaginationInput) async throws -> ReaderLayoutEngine.PaginationResult {
        let cancellation = ReaderPaginationCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<PaginationResult, Error>) in
                enqueue(Request(input: input, cancellation: cancellation, continuation: continuation))
            }
            try Task.checkCancellation()
            return result
        } onCancel: {
            self.cancel(cancellation)
        }
    }

    func cancelAll() {
        lock.lock()
        let running = active
        let waiting = pending
        running?.cancellation.cancel()
        waiting?.cancellation.cancel()
        pending = nil
        lock.unlock()
        running?.cancel()
        waiting?.cancel()
    }

    private func enqueue(_ request: Request) {
        lock.lock()
        guard !request.cancellation.isCancelled else {
            lock.unlock()
            request.cancel()
            return
        }
        let running = active
        let displaced = pending
        running?.cancellation.cancel()
        displaced?.cancellation.cancel()
        if running == nil {
            active = request
        } else {
            pending = request
        }
        lock.unlock()
        running?.cancel()
        displaced?.cancel()
        if running == nil {
            queue.async { self.run(request) }
        }
    }

    private func cancel(_ cancellation: ReaderPaginationCancellation) {
        cancellation.cancel()
        lock.lock()
        let request: Request?
        if pending?.cancellation === cancellation {
            request = pending
            pending = nil
        } else if active?.cancellation === cancellation {
            request = active
        } else {
            request = nil
        }
        lock.unlock()
        request?.cancel()
    }

    private func run(_ request: Request) {
        // The entire operation is synchronous in this one dispatch block. ARC and
        // autoreleased CTFrame/CTLine/CTRun/framesetter objects are drained here;
        // only attributed strings, ranges, rectangles and immutable fonts escape.
        let result: Result<PaginationResult, Error> = autoreleasepool {
            Result { try compute(request) }
        }
        request.finish(result)

        lock.lock()
        let next = pending
        pending = nil
        active = next
        lock.unlock()
        if let next {
            queue.async { self.run(next) }
        }
    }

    private func compute(_ request: Request) throws -> PaginationResult {
        let cancellation = request.cancellation
        try cancellation.checkCancellation()
        let input = request.input
        let imageStyle = input.layout.normalizedImageStyle
        let key = ReaderPaginationCacheKey(
            layout: input.layout,
            bounds: input.bounds,
            pageGeometry: input.pageGeometry,
            theme: input.theme,
            imageStyle: imageStyle,
            isCancelled: { cancellation.isCancelled }
        )
        try cancellation.checkCancellation()
        if let cached = cache.value(for: key) {
            try cancellation.checkCancellation()
            return cached
        }
        let contentSize = CGSize(
            width: max(input.pageGeometry.contentFrame.width, 1),
            height: max(input.pageGeometry.contentFrame.height, 1)
        )
        let renderer = ReaderLayoutRenderer(cancellation: cancellation)
        let pages = renderer.renderMeasuredPages(
            layout: input.layout,
            contentSize: contentSize,
            theme: input.theme,
            imageStyle: imageStyle
        )
        // A cancelled collector may return nil after partial internal work. Never
        // turn that into an empty page, fallback layout, cache entry, or UI result.
        guard !renderer.isCancelled else { throw CancellationError() }
        try cancellation.checkCancellation()
        let result = PaginationResult(
            pages: pages.isEmpty
                ? [ReaderLayoutRenderer.emptyPage(chapterTitle: input.layout.chapterTitle, contentSize: contentSize)]
                : pages
        )
        cache.insert(result, for: key, cancellation: cancellation)
        try cancellation.checkCancellation()
        return result
    }
}
