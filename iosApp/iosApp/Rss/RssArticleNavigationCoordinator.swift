import Foundation
import shared
import WebKit

@MainActor
final class RssArticleNavigationCoordinator {
    private final class Decision {
        let id = UUID()
        let generation: UUID
        private var callback: ((WKNavigationActionPolicy) -> Void)?

        init(generation: UUID, callback: @escaping (WKNavigationActionPolicy) -> Void) {
            self.generation = generation
            self.callback = callback
        }

        func resolve(_ policy: WKNavigationActionPolicy) {
            guard let callback else { return }
            self.callback = nil
            callback(policy)
        }
    }

    private struct ProgrammaticRequest {
        let url: String
        let method: String
        let body: Data?

        init?(_ request: URLRequest) {
            guard let url = request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                request.httpBodyStream == nil
            else { return nil }
            self.url = url.absoluteString
            method = request.httpMethod ?? "GET"
            body = request.httpBody
        }

        func matches(_ request: URLRequest) -> Bool {
            request.httpBodyStream == nil && request.url?.absoluteString == url
                && (request.httpMethod ?? "GET") == method && request.httpBody == body
        }
    }

    private enum Outcome {
        case allow
        case cancel
        case load(URLRequest)
        case external(URL)

        var policy: WKNavigationActionPolicy {
            if case .allow = self { return .allow }
            return .cancel
        }
    }

    private let article: RssArticle
    private let browser: RssArticleWebSession
    private let isActive: @MainActor () -> Bool
    private let canUseActions: @MainActor () -> Bool
    private let allowsMainDocument: @MainActor (String) -> Bool
    private let onActions: @MainActor ([RssArticleNavigationAction]) -> Void
    private let onMessage: @MainActor (String) -> Void
    private let onLoad: @MainActor (URLRequest) -> Void
    private let onLinkActivated: @MainActor () -> Void
    private let onExternal: @MainActor (URL) -> Void
    private var generation = UUID()
    private var programmaticRequest: ProgrammaticRequest?
    private var pending: [UUID: Decision] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var isCancelling = false
    private static let maximumTasks = 64

    /// isActive covers page/scene/lock lifetime, not modal presentation availability.
    /// onExternal routes legado/yuedu to linkActions.open and other schemes to offerExternal.
    init(
        article: RssArticle,
        browser: RssArticleWebSession,
        isActive: @escaping @MainActor () -> Bool,
        canUseActions: @escaping @MainActor () -> Bool,
        allowsMainDocument: @escaping @MainActor (String) -> Bool,
        onActions: @escaping @MainActor ([RssArticleNavigationAction]) -> Void,
        onMessage: @escaping @MainActor (String) -> Void,
        onLoad: @escaping @MainActor (URLRequest) -> Void,
        onLinkActivated: @escaping @MainActor () -> Void,
        onExternal: @escaping @MainActor (URL) -> Void
    ) {
        self.article = article
        self.browser = browser
        self.isActive = isActive
        self.canUseActions = canUseActions
        self.allowsMainDocument = allowsMainDocument
        self.onActions = onActions
        self.onMessage = onMessage
        self.onLoad = onLoad
        self.onLinkActivated = onLinkActivated
        self.onExternal = onExternal
    }

    /// Call immediately before a programmatic webView.load, never from createWebViewWith.
    func markProgrammatic(_ request: URLRequest) {
        programmaticRequest = isActive() ? ProgrammaticRequest(request) : nil
    }

    /// The owner calls this on page replacement, disappearance, suspension or app locking.
    func cancel() {
        generation = UUID()
        programmaticRequest = nil
        cancelPending()
    }

    func decide(
        _ action: WKNavigationAction,
        in webView: WKWebView,
        decision: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard !isCancelling, isActive(), let url = action.request.url else {
            decision(.cancel)
            return
        }
        let isMainFrame = action.targetFrame?.isMainFrame == true
        let isPopup = action.targetFrame == nil
        let replacesMain = isMainFrame || (isPopup && action.sourceFrame.isMainFrame)
        var bypassHook = false
        if replacesMain {
            // A popup cannot consume the programmatic main-frame exemption, even at the same URL.
            bypassHook = isMainFrame && action.sourceFrame.isMainFrame && action.navigationType == .other
                && programmaticRequest?.matches(action.request) == true
            programmaticRequest = nil
            generation = UUID()
            cancelPending()
        }
        let record = Decision(generation: generation, callback: decision)
        guard !isCancelling, isActive() else { record.resolve(.cancel); return }
        if url.scheme?.lowercased() == "about" {
            record.resolve(url.absoluteString == "about:blank" && !isPopup ? .allow : .cancel)
            return
        }
        guard tasks.count < Self.maximumTasks else {
            record.resolve(.cancel)
            return
        }
        pending[record.id] = record
        if replacesMain, action.navigationType == .linkActivated {
            onLinkActivated()
        }
        guard isCurrent(record) else { discard(record); return }
        let article = article
        let browser = browser
        tasks[record.id] = Task { @MainActor [weak self, weak webView] in
            // Do not retain the owner across source scripts or asynchronous cookie preparation.
            defer {
                self?.taskFinished(record)
                record.resolve(.cancel)
            }
            var actions: [RssArticleNavigationAction] = []
            var messages: [String] = []
            do {
                guard self?.isCurrent(record) == true else { return }
                if !bypassHook {
                    let facade = try RssArticleNavigationFacade.companion.create()
                    let result: RssArticleNavigationResult = try await SharedCancellableAsync.value { completion in
                        facade.evaluateRequest(article: article, targetUrl: url.absoluteString) { result in
                            completion(result.isCancelled ? nil : result, result.isCancelled ? CancellationError() : nil)
                        }
                    }
                    try Task.checkCancellation()
                    guard self?.isCurrent(record) == true else { return }
                    actions = result.actions
                    if let message = result.errorMessage { messages.append(message) }
                    // Script errors do not imply override; their already-issued actions survive.
                    if result.isOverridden {
                        self?.complete(record, outcome: .cancel, actions: actions, messages: messages)
                        return
                    }
                }
                guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                    self?.complete(record, outcome: .external(url), actions: actions, messages: messages)
                    return
                }
                guard self?.allowsMainDocument(url.absoluteString) == true else {
                    messages.append("订阅源的内容规则已拦截此链接")
                    self?.complete(record, outcome: .cancel, actions: actions, messages: messages)
                    return
                }
                // An iframe's new-window request must not replace the article's main document.
                guard !isPopup || replacesMain else {
                    self?.complete(record, outcome: .cancel, actions: actions, messages: messages)
                    return
                }
                guard let webView, self?.isCurrent(record) == true else { return }
                let outcome: Outcome
                if isPopup {
                    let request = try await browser.prepareNavigation(action.request, webView: webView)
                    outcome = .load(request)
                } else if let request = try await browser.prepareNavigation(action, webView: webView) {
                    outcome = isMainFrame ? .load(request) : .cancel
                } else {
                    outcome = .allow
                }
                try Task.checkCancellation()
                self?.complete(record, outcome: outcome, actions: actions, messages: messages)
            } catch {
                guard !(error is CancellationError), self?.isCurrent(record) == true else { return }
                messages.append(error.userFacingMessage)
                self?.complete(record, outcome: .cancel, actions: actions, messages: messages)
            }
        }
    }

    private func isCurrent(_ record: Decision) -> Bool {
        pending[record.id] === record && canContinue(record)
    }

    private func canContinue(_ record: Decision) -> Bool {
        !isCancelling && !Task.isCancelled && generation == record.generation && isActive()
    }

    private func complete(
        _ record: Decision,
        outcome: Outcome,
        actions: [RssArticleNavigationAction],
        messages: [String]
    ) {
        guard isCurrent(record) else { discard(record); return }
        pending.removeValue(forKey: record.id)
        // Resolve WebKit's original popup before issuing any replacement main navigation.
        record.resolve(outcome.policy)
        for message in messages {
            guard canContinue(record) else { return }
            onMessage(message)
        }
        guard canContinue(record) else { return }
        if !actions.isEmpty {
            if canUseActions() { onActions(actions) }
        } else if case let .external(url) = outcome, canUseActions() {
            onExternal(url)
        }
        guard canContinue(record) else { return }
        if case let .load(request) = outcome {
            markProgrammatic(request)
            onLoad(request)
        }
    }

    private func discard(_ record: Decision) {
        pending.removeValue(forKey: record.id)
        record.resolve(.cancel)
    }

    private func taskFinished(_ record: Decision) {
        tasks.removeValue(forKey: record.id)
        discard(record)
    }

    private func cancelPending() {
        let wasCancelling = isCancelling
        isCancelling = true
        let records = Array(pending.values)
        pending.removeAll(keepingCapacity: true)
        // Keep cancelled tasks counted until they actually exit; cancellation need not end cookie I/O immediately.
        for task in tasks.values { task.cancel() }
        for record in records { record.resolve(.cancel) }
        isCancelling = wasCancelling
    }
}
