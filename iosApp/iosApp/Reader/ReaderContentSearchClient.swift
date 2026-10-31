import Foundation
import shared

final class ReaderContentSearchClient {
    private typealias Binding = (bookURL: String, generation: UUID)

    private let binding: @MainActor () -> Binding
    private let facade: @MainActor () -> ReaderFacade?
    private let lock = NSLock()
    private var requests: [UUID: ReaderContentSearchRequest] = [:]

    init(
        binding: @escaping @MainActor () -> (bookURL: String, generation: UUID),
        facade: @escaping @MainActor () -> ReaderFacade?
    ) {
        self.binding = binding
        self.facade = facade
    }

    @MainActor
    func searchInBook(keyword: String, onResult: @escaping (ContentSearchResult) -> Void) async throws {
        try await search(keyword: keyword, replaceEnabled: nil, onResult: onResult)
    }

    @MainActor
    func searchInBook(
        keyword: String,
        options: ReaderContentSearchOptions,
        onResult: @escaping (ContentSearchResult) -> Void
    ) async throws {
        try await search(keyword: keyword, replaceEnabled: options.replaceEnabled, onResult: onResult)
    }

    func invalidate() {
        lock.lock()
        let subscriptions = requests.values.compactMap { $0.invalidate() }
        requests.removeAll()
        lock.unlock()
        // Kotlin cancellation may synchronously deliver the terminal callback.
        subscriptions.forEach { $0.cancel() }
    }

    @MainActor
    private func search(
        keyword: String,
        replaceEnabled: Bool?,
        onResult: @escaping (ContentSearchResult) -> Void
    ) async throws {
        try Task.checkCancellation()
        let snapshot = binding()
        guard !snapshot.bookURL.isEmpty else { throw CancellationError() }
        guard let facade = facade() else {
            throw NSError(
                domain: "io.legado.kmp.ios", code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Reader.unavailable])
        }
        let token = ReaderContentSearchRequest.Token(bookURL: snapshot.bookURL, generation: snapshot.generation)
        let request = begin(token)
        defer { remove(request) }

        try await withTaskCancellationHandler {
            do {
                try check(request)
                // Both APIs are prepare-only requests whose terminal callback follows job completion.
                let result: ReaderContentSearchCompletion = try await SharedCancellableAsync.value(
                    awaitCancellationCompletion: true
                ) { completion in
                    request.start(
                        facade: facade, keyword: keyword, replaceEnabled: replaceEnabled,
                        onResult: onResult, completion: completion)
                }
                try check(request)
                if result.isCancelled { throw CancellationError() }
                if result.errorCode != nil || result.errorMessage != nil {
                    throw Self.searchError(result)
                }
            } catch {
                try check(request)
                throw error
            }
        } onCancel: {
            request.cancel()
        }
    }

    private func begin(_ token: ReaderContentSearchRequest.Token) -> ReaderContentSearchRequest {
        let request = ReaderContentSearchRequest(token: token)
        lock.lock()
        // Also reject an old binding if a caller starts work before an explicit invalidation.
        let outdated = requests.values.filter {
            $0.token.bookURL != token.bookURL || $0.token.generation != token.generation
        }
        let subscriptions = outdated.compactMap { $0.invalidate() }
        outdated.forEach { requests.removeValue(forKey: $0.token.requestID) }
        requests[token.requestID] = request
        lock.unlock()
        subscriptions.forEach { $0.cancel() }
        return request
    }

    private func remove(_ request: ReaderContentSearchRequest) {
        lock.lock()
        if requests[request.token.requestID] === request {
            requests.removeValue(forKey: request.token.requestID)
        }
        lock.unlock()
        request.cancel()
    }

    @MainActor
    private func check(_ request: ReaderContentSearchRequest) throws {
        try Task.checkCancellation()
        let current = binding()
        lock.lock()
        let registered = requests[request.token.requestID] === request
        lock.unlock()
        guard registered, !request.isCancelled,
            current.bookURL == request.token.bookURL, current.generation == request.token.generation
        else { throw CancellationError() }
    }

    private static func searchError(_ result: ReaderContentSearchCompletion) -> NSError {
        var userInfo: [String: Any] = [
            NSLocalizedDescriptionKey: result.errorMessage ?? result.errorCode ?? L10n.Shared.emptyValue
        ]
        if let code = result.errorCode { userInfo["errorCode"] = code }
        if let message = result.errorMessage { userInfo["errorMessage"] = message }
        return NSError(domain: "io.legado.kmp.ios", code: -1, userInfo: userInfo)
    }
}

private final class ReaderContentSearchRequest: @unchecked Sendable {
    struct Token: Equatable, Sendable {
        let bookURL: String
        let generation: UUID
        let requestID = UUID()
    }

    let token: Token
    private let lock = NSLock()
    private var cancelled = false
    private var finished = false
    private var subscription: FlowSubscription?

    init(token: Token) {
        self.token = token
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    // Create Kotlin callbacks outside MainActor; consumers keep ownership of their UI dispatch.
    func start(
        facade: ReaderFacade,
        keyword: String,
        replaceEnabled: Bool?,
        onResult: @escaping (ContentSearchResult) -> Void,
        completion: @escaping @Sendable (ReaderContentSearchCompletion?, Error?) -> Void
    ) -> FlowSubscription {
        let token = token
        let forward: (ContentSearchResult) -> Void = { [self] result in
            deliver(result, for: token, onResult: onResult)
        }
        let finish: (ReaderContentSearchCompletion) -> Void = { [self] result in
            self.finish(for: token) { completion(result, nil) }
        }
        let subscription: FlowSubscription
        if let replaceEnabled {
            subscription = facade.searchInBookWithOptionsRequest(
                bookUrl: token.bookURL, keyword: keyword, replaceEnabled: replaceEnabled,
                onResult: forward, onFinished: finish)
        } else {
            // Do not turn the legacy null/default option into an explicit false.
            subscription = facade.searchInBookRequest(
                bookUrl: token.bookURL, keyword: keyword, onResult: forward, onFinished: finish)
        }
        install(subscription)
        return subscription
    }

    private func install(_ subscription: FlowSubscription) {
        lock.lock()
        let shouldCancel = cancelled
        if !cancelled, !finished { self.subscription = subscription }
        lock.unlock()
        if shouldCancel { subscription.cancel() }
    }

    private func deliver(
        _ result: ContentSearchResult,
        for token: Token,
        onResult: (ContentSearchResult) -> Void
    ) {
        lock.lock()
        let accepted = self.token == token && !cancelled && !finished
        lock.unlock()
        // Admission is synchronous on Kotlin's callback thread. An admitted callback may finish
        // during cancellation; never wait for UI code or hold a lock while calling the consumer.
        if accepted { onResult(result) }
    }

    private func finish(for token: Token, completion: () -> Void) {
        lock.lock()
        guard self.token == token, !finished else {
            lock.unlock()
            return
        }
        finished = true
        let subscription = self.subscription
        self.subscription = nil
        lock.unlock()
        withExtendedLifetime(subscription) { completion() }
    }

    func invalidate() -> FlowSubscription? {
        lock.lock()
        cancelled = true
        let subscription = self.subscription
        self.subscription = nil
        lock.unlock()
        return subscription
    }

    func cancel() {
        invalidate()?.cancel()
    }
}
