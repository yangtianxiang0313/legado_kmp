import shared
import UIKit

@MainActor
final class RssDirectoryActionsCoordinator: NSObject {
    let layoutButton = UIButton(type: .system)
    let moreButton = UIButton(type: .system)
    private weak var owner: UIViewController?
    private let screen: RssScreenAdapter
    private let source: RssSource
    private let canUseActions: () -> Bool
    private let isRuntimeReady: () -> Bool
    private let sourceAvailable: () -> Bool
    private let currentStyle: () -> RssArticlePresentationStyle
    private let onStyleChange: (RssArticlePresentationStyle) -> Void
    private let onClearStarted: () -> Void
    private let onClearFinished: (Bool) -> Void
    private let onReturn: () -> Void
    private var presentationID = UUID()
    private var styleRequestID: UUID?
    private var styleTask: Task<Void, Never>?
    private var clearTask: Task<Void, Never>?
    private weak var ownedPresentation: UIViewController?
    private var pendingDelivery: (id: UUID, context: ActionContext, action: () -> Void)?
    private var pendingMessage: (text: String, context: ActionContext)?
    private(set) var isClearingArticles = false

    init(
        owner: UIViewController, screen: RssScreenAdapter, source: RssSource,
        canUseActions: @escaping () -> Bool, isRuntimeReady: @escaping () -> Bool,
        sourceAvailable: @escaping () -> Bool, currentStyle: @escaping () -> RssArticlePresentationStyle,
        onStyleChange: @escaping (RssArticlePresentationStyle) -> Void,
        onClearStarted: @escaping () -> Void, onClearFinished: @escaping (Bool) -> Void,
        onReturn: @escaping () -> Void
    ) {
        self.owner = owner
        self.screen = screen
        self.source = source
        self.canUseActions = canUseActions
        self.isRuntimeReady = isRuntimeReady
        self.sourceAvailable = sourceAvailable
        self.currentStyle = currentStyle
        self.onStyleChange = onStyleChange
        self.onClearStarted = onClearStarted
        self.onClearFinished = onClearFinished
        self.onReturn = onReturn
        super.init()
    }

    deinit { styleTask?.cancel(); clearTask?.cancel() }

    func configureButtons() {
        layoutButton.accessibilityIdentifier = "rss.layoutButton"
        layoutButton.accessibilityLabel = L10n.RSS.switchLayout
        layoutButton.addInteraction(UIToolTipInteraction(defaultToolTip: L10n.RSS.switchLayout))
        layoutButton.addTarget(self, action: #selector(switchLayout), for: .touchUpInside)
        moreButton.setImage(ReaderMenuAndroidIcon.more.image(), for: .normal)
        moreButton.accessibilityIdentifier = "rss.directory.more"
        moreButton.accessibilityLabel = L10n.Bookshelf.moreActions
        moreButton.addInteraction(UIToolTipInteraction(defaultToolTip: L10n.Bookshelf.moreActions))
        moreButton.addTarget(self, action: #selector(showMore), for: .touchUpInside)
        updateButtons()
    }

    func updateButtons() {
        let available = canUseActions() && isRuntimeReady() && !isClearingArticles && pendingDelivery == nil
        layoutButton.setImage(UIImage(systemName: currentStyle().symbolName), for: .normal)
        layoutButton.accessibilityValue = currentStyle().title
        layoutButton.isEnabled = available && sourceAvailable() && styleRequestID == nil
        moreButton.isEnabled = available && styleRequestID == nil
        if canUseActions(), let message = pendingMessage {
            pendingMessage = nil
            if let owner, message.context.matches(owner) { owner.showTransientMessage(message.text) }
        }
        deliverPendingAction()
    }

    func pageWillDisappear() {
        if let owner, let ownedPresentation, !owner.isMovingFromParent, !owner.isBeingDismissed,
            owner.presentedViewController === ownedPresentation || ownedPresentation.isBeingPresented
        {
            cancelStyleUpdate()
        } else {
            suspend()
        }
    }

    func suspend() {
        presentationID = UUID()
        pendingDelivery = nil
        cancelStyleUpdate()
    }

    private func cancelStyleUpdate() {
        styleRequestID = nil
        styleTask?.cancel()
        styleTask = nil
        updateButtons()
    }

    @objc private func switchLayout() {
        guard canUseActions(), isRuntimeReady(), sourceAvailable(), !isClearingArticles,
            styleRequestID == nil, pendingDelivery == nil, let owner, let context = ActionContext(owner)
        else { return }
        let style = currentStyle().next
        let id = UUID()
        styleRequestID = id
        updateButtons()
        styleTask = Task { @MainActor [weak self, screen, source] in
            defer {
                if let self, self.styleRequestID == id {
                    self.styleRequestID = nil
                    self.styleTask = nil
                    self.updateButtons()
                }
            }
            do {
                let updated = try await screen.setArticleStyle(
                    sourceURL: source.sourceUrl, style: Int32(style.rawValue))
                try Task.checkCancellation()
                guard let self, self.styleRequestID == id, self.canUseActions(),
                    let owner = self.owner, context.matches(owner)
                else { return }
                guard let updated else { owner.showTransientMessage(L10n.RSS.unavailable); return }
                self.onStyleChange(RssArticlePresentationStyle(articleStyle: updated.articleStyle))
            } catch is CancellationError {} catch {
                guard let self, !Task.isCancelled, self.styleRequestID == id, self.canUseActions(),
                    let owner = self.owner, context.matches(owner)
                else { return }
                owner.showTransientMessage(error.userFacingMessage)
            }
        }
    }

    @objc private func showMore() {
        guard canUseActions(), isRuntimeReady(), !isClearingArticles, styleRequestID == nil, pendingDelivery == nil,
            let owner, let context = ActionContext(owner)
        else { return }
        let id = UUID()
        presentationID = id
        var options: [AndroidReplicaOptionSheetViewController.Option] = [
            .init(title: L10n.RSS.readRecordsTitle, systemImage: "clock", isSelected: false) { [weak self] in
                self?.enqueueDelivery(id, context: context) { [weak self] in self?.showReadRecords() }
            }
        ]
        if sourceAvailable() {
            options.append(
                .init(
                    title: L10n.RSS.clearArticles, systemImage: "trash", isSelected: false, isDestructive: true
                ) { [weak self] in
                    self?.enqueueDelivery(id, context: context) { [weak self] in
                        self?.confirmClearArticles(context: context)
                    }
                })
        }
        let sheet = AndroidReplicaOptionSheetViewController(titleText: L10n.Bookshelf.moreActions, options: options)
        let presentation = sheet.wrappedInReaderBottomSheet(
            fixedHeight: AndroidReplicaOptionSheetViewController.preferredHeight(optionCount: options.count))
        ownedPresentation = presentation
        owner.present(presentation, animated: true)
    }

    private func canDeliver(_ id: UUID, context: ActionContext) -> Bool {
        guard presentationID == id, !isClearingArticles, isRuntimeReady(), canUseActions(), let owner else {
            return false
        }
        return context.matches(owner)
    }

    private func enqueueDelivery(_ id: UUID, context: ActionContext, action: @escaping () -> Void) {
        guard presentationID == id else { return }
        pendingDelivery = (id, context, action)
        // Dismiss completion may precede clearing the presenter's transitionCoordinator.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let transition = self.owner?.transitionCoordinator
                ?? self.owner?.navigationController?.transitionCoordinator
            {
                if transition.animate(
                    alongsideTransition: nil,
                    completion: { [weak self] result in
                        if result.isCancelled, self?.presentationID == id { self?.pendingDelivery = nil }
                        DispatchQueue.main.async { [weak self] in self?.updateButtons() }
                    })
                {
                    return
                }
            }
            self.updateButtons()
        }
    }

    private func deliverPendingAction() {
        guard let delivery = pendingDelivery else { return }
        guard presentationID == delivery.id, let owner, delivery.context.matches(owner) else {
            pendingDelivery = nil
            return
        }
        guard canDeliver(delivery.id, context: delivery.context) else { return }
        pendingDelivery = nil
        ownedPresentation = nil
        delivery.action()
        updateButtons()
    }

    private func showReadRecords() {
        guard let owner else { return }
        let dialog = RssReadRecordsViewController()
        dialog.onClose = { [weak self] in self?.onReturn() }
        ownedPresentation = dialog
        owner.present(dialog, animated: true)
    }

    private func confirmClearArticles(context: ActionContext) {
        guard sourceAvailable(), let owner else { return }
        let id = UUID()
        presentationID = id
        let dialog = ReaderRestoreProgressDialogViewController(
            title: L10n.RSS.clearArticles, message: L10n.RSS.clearArticlesConfirmMessage,
            accessibilityIdentifierPrefix: "rss.directory.clearArticles"
        ) { [weak self] confirmed in
            guard let self, confirmed else { return }
            self.enqueueDelivery(id, context: context) { [weak self] in
                guard let self, self.sourceAvailable() else { return }
                self.clearArticles(context: context)
            }
        }
        dialog.canConfirm = { [weak self, weak dialog] in
            guard let self, let owner = self.owner, self.presentationID == id, !self.isClearingArticles,
                self.sourceAvailable(), self.isRuntimeReady(), context.matches(owner)
            else { return false }
            return owner.presentedViewController == nil || owner.presentedViewController === dialog
        }
        dialog.onClose = { [weak self] in self?.onReturn() }
        ownedPresentation = dialog
        owner.present(dialog, animated: true)
    }

    private func clearArticles(context: ActionContext) {
        guard !isClearingArticles else { return }
        isClearingArticles = true
        onClearStarted()
        updateButtons()
        // A committed deletion must still invalidate the page if it completes behind the lock.
        clearTask = Task { @MainActor [weak self, screen, source] in
            let result: Result<Void, Error>
            do { try await screen.clearArticles(source: source); result = .success(()) } catch {
                result = .failure(error)
            }
            guard let self else { return }
            self.clearTask = nil
            self.isClearingArticles = false
            switch result {
            case .success:
                self.onClearFinished(true)
                self.pendingMessage = (L10n.RSS.articlesCleared, context)
            case .failure(let error):
                self.onClearFinished(false)
                self.pendingMessage = (error.userFacingMessage, context)
            }
            self.updateButtons()
            self.onReturn()
        }
    }

    @MainActor
    private final class ActionContext {
        private weak var window: UIWindow?
        private weak var root: UIViewController?
        private weak var scene: UIWindowScene?

        init?(_ owner: UIViewController) {
            guard let window = owner.viewIfLoaded?.window, let root = window.rootViewController,
                let scene = window.windowScene
            else { return nil }
            self.window = window
            self.root = root
            self.scene = scene
        }

        func matches(_ owner: UIViewController) -> Bool {
            guard let window, let root, let scene, owner.viewIfLoaded?.window === window,
                window.rootViewController === root, window.windowScene === scene,
                window.isKeyWindow, !window.isHidden, window.alpha > 0.01, window.isUserInteractionEnabled,
                !window.accessibilityElementsHidden, scene.activationState == .foregroundActive,
                UIApplication.shared.applicationState == .active, UIApplication.shared.isProtectedDataAvailable,
                AppLockManager.shared.isUnlocked(in: window), owner.isVisibleInNavigationStack
            else { return false }
            var current: UIViewController? = owner
            while let page = current {
                guard !page.isBeingDismissed, !page.isMovingFromParent,
                    page.viewIfLoaded?.window === window
                else { return false }
                if let navigation = page.parent as? UINavigationController,
                    navigation.topViewController !== page
                {
                    return false
                }
                if let tabs = page.parent as? UITabBarController, tabs.selectedViewController !== page { return false }
                if page === root { return true }
                current = page.parent
            }
            return false
        }
    }
}
