import shared
import UIKit

@MainActor
final class RssArticleLinkActionCoordinator: NSObject {
    private weak var owner: UIViewController?
    private let canAct: () -> Bool
    private var bookLink: ExternalBookLinkCoordinator?
    private var ruleImport: ExternalRuleImportCoordinator?
    private var readerConfig: ExternalReaderConfigImportCoordinator?
    private weak var expectedWindow: UIWindow?
    private weak var expectedScene: UIWindowScene?
    private weak var expectedRoot: UIViewController?
    private weak var expectedNavigation: UINavigationController?
    private weak var expectedTop: UIViewController?
    private var requestToken: UUID?
    private var prompt: UIAlertController?
    private var selectionConsumed = false
    private var ownershipMonitor: Task<Void, Never>?
    private var dismissalTask: Task<Void, Never>?

    init(owner: UIViewController, canAct: @escaping () -> Bool) {
        self.owner = owner
        self.canAct = canAct
        super.init()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        ownershipMonitor?.cancel()
        dismissalTask?.cancel()
    }

    func perform(_ actions: [RssArticleNavigationAction]) {
        guard !actions.isEmpty, let token = beginRequest(), let owner else { return }
        if actions.count == 1 {
            perform(actions[0], token: token)
        } else {
            let prompt = UIAlertController(
                title: text("rss.article_link.actions_title", "选择文章操作"), message: nil, preferredStyle: .actionSheet)
            for action in actions {
                let keyword = String(action.value.prefix(24)) + (action.value.count > 24 ? "…" : "")
                let title =
                    action.kind == .searchBook
                    ? String(format: text("rss.article_link.search_format", "搜索：%@"), keyword)
                    : text("rss.article_link.open_book", "打开书籍")
                prompt.addAction(
                    UIAlertAction(title: title, style: .default) { [weak self, weak prompt] _ in
                        self?.afterDismissal(prompt, token: token) { [weak self] in self?.perform(action, token: token)
                        }
                    })
            }
            prompt.addAction(
                UIAlertAction(title: L10n.Common.cancel, style: .cancel) { [weak self] _ in
                    self?.invalidateRequest(token)
                })
            anchor(prompt, owner: owner)
            present(prompt, owner: owner, token: token)
        }
    }

    func open(_ url: URL) {
        guard let token = beginRequest(), let owner = consumeRequest(token) else { return }
        do {
            switch try ExternalOpenRoute.parse(url) {
            case .bookSource(let address):
                let screen = SourceImportScreenAdapter()
                try screen.bootstrap().get()
                let preview = SourceImportPreviewViewController {
                    try await screen.preparePreview(source: .url(address.absoluteString))
                }
                preview.onConfirm = { sources, options in
                    _ = try await screen.importSelected(sources: sources, options: options)
                }
                owner.present(preview, animated: true)
            case .rules(let address, let kind):
                let coordinator = ExternalRuleImportCoordinator(owner: owner)
                ruleImport = coordinator
                coordinator.start(input: .remote(address), expected: kind)
            case .readerConfig(let address):
                let coordinator = ExternalReaderConfigImportCoordinator(owner: owner)
                readerConfig = coordinator
                coordinator.start(input: .remote(address))
            case .bookLink(let address):
                openBook(address, owner: owner)
            case .file:
                owner.showTransientMessage(text("rss.article_link.local_file_blocked", "文章不能直接打开本地文件"))
            }
        } catch {
            owner.showTransientMessage(error.userFacingMessage)
        }
    }

    func offerExternal(_ url: URL) {
        guard !["javascript", "file", "data", "blob", "about", "jsbridge"].contains(url.scheme?.lowercased() ?? ""),
            let token = beginRequest(), let owner
        else { return }
        let prompt = UIAlertController(
            title: text("rss.article_link.external_confirm_title", "在其他应用中打开？"), message: nil, preferredStyle: .alert)
        prompt.addAction(
            UIAlertAction(title: L10n.Common.cancel, style: .cancel) { [weak self] _ in self?.invalidateRequest(token) }
        )
        prompt.addAction(
            UIAlertAction(title: L10n.Common.confirm, style: .default) { [weak self, weak prompt] _ in
                self?.afterDismissal(prompt, token: token) { [weak self] in
                    guard self?.consumeRequest(token) != nil else { return }
                    UIApplication.shared.open(url)
                }
            })
        present(prompt, owner: owner, token: token)
    }

    func cancel() {
        if let token = requestToken { invalidateRequest(token) }
        bookLink?.cancel()
        ruleImport?.cancel()
        readerConfig?.cancel()
        bookLink = nil
        ruleImport = nil
        readerConfig = nil
    }

    private func perform(_ action: RssArticleNavigationAction, token: UUID) {
        guard let owner = consumeRequest(token) else { return }
        if action.kind == .searchBook {
            owner.navigationController?.pushViewController(
                AndroidReplicaSearchViewController(initialKeyword: action.value), animated: true)
        } else if action.kind == .addBook {
            openBook(action.value, owner: owner)
        }
    }

    private func openBook(_ address: String, owner: UIViewController) {
        guard ExternalBookLinkCoordinator.accepts(address) else {
            owner.showTransientMessage(text("rss.article_link.invalid_book_link", "书籍链接无效"))
            return
        }
        let coordinator = ExternalBookLinkCoordinator(owner: owner)
        bookLink = coordinator
        coordinator.start(address: address)
    }

    private func beginRequest() -> UUID? {
        guard requestToken == nil, canAct(), let owner, owner.canPerformNavigationAction,
            let window = owner.viewIfLoaded?.window, let scene = window.windowScene,
            let root = window.rootViewController, let navigation = owner.navigationController,
            let top = navigation.topViewController
        else { return nil }
        let token = UUID()
        requestToken = token
        expectedWindow = window
        expectedScene = scene
        expectedRoot = root
        expectedNavigation = navigation
        expectedTop = top
        guard hasCurrentOwner(token) else { finishRequest(); return nil }

        let center = NotificationCenter.default
        for name in [UIWindow.didResignKeyNotification, .appLockWillCover] {
            center.addObserver(self, selector: #selector(invalidatePendingRequest), name: name, object: window)
        }
        for name in [UIScene.willDeactivateNotification, UIScene.didDisconnectNotification] {
            center.addObserver(self, selector: #selector(invalidatePendingRequest), name: name, object: scene)
        }
        center.addObserver(
            self, selector: #selector(invalidatePendingRequest), name: UIApplication.willResignActiveNotification,
            object: nil)
        return token
    }

    private func present(_ prompt: UIAlertController, owner: UIViewController, token: UUID) {
        self.prompt = prompt
        owner.present(prompt, animated: true)
        ownershipMonitor = Task { @MainActor [weak self, weak prompt] in
            while !Task.isCancelled {
                guard self?.requestToken == token else { return }
                guard self?.hasCurrentOwner(token) == true, let prompt else {
                    self?.invalidateRequest(token)
                    return
                }
                if prompt.presentingViewController == nil, !prompt.isBeingPresented, self?.selectionConsumed == false {
                    self?.invalidateRequest(token)
                    return
                }
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
            }
        }
    }

    private func afterDismissal(_ prompt: UIAlertController?, token: UUID, action: @escaping () -> Void) {
        guard requestToken == token, let prompt, self.prompt === prompt, !selectionConsumed else { return }
        guard hasCurrentOwner(token) else { invalidateRequest(token); return }
        selectionConsumed = true
        if !prompt.isBeingDismissed { prompt.dismiss(animated: true) }
        // UIKit may already be dismissing the alert. Wait for detachment, not an unscoped completion.
        dismissalTask = Task { @MainActor [weak self, weak prompt] in
            for _ in 0..<150 {
                guard !Task.isCancelled, self?.requestToken == token, let prompt else { return }
                guard self?.hasCurrentOwner(token) == true else { self?.invalidateRequest(token); return }
                if prompt.presentingViewController == nil, !prompt.isBeingPresented, !prompt.isBeingDismissed,
                    prompt.transitionCoordinator == nil, self?.owner?.transitionCoordinator == nil,
                    self?.expectedNavigation?.transitionCoordinator == nil,
                    self?.expectedRoot?.transitionCoordinator == nil
                {
                    action()
                    // A failed final canAct gate must not revive when the article returns later.
                    if self?.requestToken == token { self?.invalidateRequest(token) }
                    return
                }
                do { try await Task.sleep(nanoseconds: 20_000_000) } catch { return }
            }
            self?.invalidateRequest(token)
        }
    }

    private func consumeRequest(_ token: UUID) -> UIViewController? {
        guard requestToken == token else { return nil }
        // The article's canAct rejects our own alert, so recheck it only after that alert is gone.
        guard hasCurrentOwner(token), canAct(), let owner, owner.canPerformNavigationAction,
            prompt?.presentingViewController == nil
        else { invalidateRequest(token); return nil }
        finishRequest()
        return owner
    }

    private func hasCurrentOwner(_ token: UUID) -> Bool {
        guard requestToken == token, let owner, let window = expectedWindow, let scene = expectedScene,
            let root = expectedRoot, let navigation = expectedNavigation, let top = expectedTop,
            window.windowScene === scene, window.rootViewController === root,
            window.isKeyWindow, !window.isHidden, window.alpha > 0,
            window.isUserInteractionEnabled, !window.accessibilityElementsHidden,
            scene.activationState == .foregroundActive, UIApplication.shared.applicationState == .active,
            AppLockManager.shared.isUnlocked(in: window), root.viewIfLoaded?.window === window,
            !root.isBeingDismissed, owner.navigationController === navigation,
            navigation.topViewController === top, owner.isVisibleInNavigationStack,
            prompt?.presentedViewController == nil
        else { return false }
        var ancestors: [UIViewController] = []
        var candidate: UIViewController? = owner
        while let controller = candidate {
            guard controller.viewIfLoaded?.window === window,
                controller.viewIfLoaded?.isHidden == false, (controller.viewIfLoaded?.alpha ?? 0) > 0,
                !controller.isBeingPresented, !controller.isBeingDismissed,
                !controller.isMovingFromParent, !controller.isMovingToParent
            else { return false }
            if let tabs = controller.parent as? UITabBarController, tabs.selectedViewController !== controller {
                return false
            }
            if let modal = controller.presentedViewController, modal !== prompt { return false }
            ancestors.append(controller)
            candidate = controller.parent
        }
        if let modal = root.presentedViewController, modal !== prompt,
            !ancestors.contains(where: { $0 === modal })
        {
            return false
        }
        return true
    }

    @objc private func invalidatePendingRequest() {
        if let token = requestToken { invalidateRequest(token) }
    }

    private func invalidateRequest(_ token: UUID) {
        guard requestToken == token else { return }
        let prompt = prompt
        finishRequest()
        if let prompt { Self.dismissOwnedPrompt(prompt) }
    }

    private func finishRequest() {
        requestToken = nil
        ownershipMonitor?.cancel()
        ownershipMonitor = nil
        dismissalTask?.cancel()
        dismissalTask = nil
        NotificationCenter.default.removeObserver(self)
        prompt = nil
        selectionConsumed = false
        expectedWindow = nil
        expectedScene = nil
        expectedRoot = nil
        expectedNavigation = nil
        expectedTop = nil
    }

    private static func dismissOwnedPrompt(_ prompt: UIAlertController) {
        guard prompt.presentingViewController?.presentedViewController === prompt,
            prompt.presentedViewController == nil, !prompt.isBeingDismissed
        else { return }
        if prompt.isBeingPresented {
            Task { @MainActor [weak prompt] in
                for _ in 0..<150 {
                    guard let prompt, prompt.presentingViewController?.presentedViewController === prompt,
                        prompt.presentedViewController == nil, !prompt.isBeingDismissed
                    else { return }
                    if !prompt.isBeingPresented {
                        prompt.dismiss(animated: false)
                        return
                    }
                    do { try await Task.sleep(nanoseconds: 20_000_000) } catch { return }
                }
            }
        } else {
            prompt.dismiss(animated: false)
        }
    }

    private func text(_ key: String, _ fallback: String) -> String {
        NSLocalizedString(key, value: fallback, comment: "")
    }

    private func anchor(_ prompt: UIAlertController, owner: UIViewController) {
        prompt.popoverPresentationController?.sourceView = owner.view
        prompt.popoverPresentationController?.sourceRect = CGRect(
            x: owner.view.bounds.midX, y: owner.view.bounds.midY, width: 1, height: 1)
    }
}
