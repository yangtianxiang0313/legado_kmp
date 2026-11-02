import UIKit
import shared

@MainActor
final class ReaderChapterListMenuCoordinator {
    private enum Setting {
        case useReplace
        case countWords

        var title: String { self == .useReplace ? ReaderChapterListMenuText.useReplace : ReaderChapterListMenuText.countWords }
    }

    private final class MenuSession {
        let generation: UUID
        let presentation: ReaderOverflowPresentationContext
        let stateIsCurrent: () -> Bool
        let ownerIsCurrent: () -> Bool
        weak var menu: ReaderOverflowMenuView?
        var isDismissed = false
        var isConsumed = false

        init(
            generation: UUID, presentation: ReaderOverflowPresentationContext,
            ownerIsCurrent: @escaping () -> Bool, stateIsCurrent: @escaping () -> Bool
        ) {
            self.generation = generation
            self.presentation = presentation
            self.stateIsCurrent = stateIsCurrent
            self.ownerIsCurrent = ownerIsCurrent
        }
    }

    var canUpdate: (() -> Bool)?
    var onTitlesReloaded: (([ReaderChapterListItem]) -> Void)?
    var onWordCountChanged: (() -> Void)?
    var onMessage: ((String) -> Void)?

    private(set) var showWordCount: Bool
    var isUpdating: Bool { requestTask != nil }
    var hasPresentedMenu: Bool { overflowMenu != nil }

    private var useReplace: Bool
    private var facade: SettingsFacade?
    private var subscription: FlowSubscription?
    private var hasConfirmedConfig = false
    private var isActive = false
    private var generation = UUID()
    private var titleRevision = UUID()
    private var needsTitleReload = false
    private var isReloadingTitles = false
    private var requestID: UUID?
    private var requestTask: Task<Void, Never>?
    private weak var overflowMenu: ReaderOverflowMenuView?
    private var menuSession: MenuSession?
    private weak var presentationOwner: UIViewController?
    private weak var presentationWindow: UIWindow?
    private weak var presentationRoot: UIViewController?
    private weak var presentationSource: UIViewController?
    private var appSuspended = false
    private var sceneSuspended = false
    private var windowSuspended = false
    private var environmentObservers: [NSObjectProtocol] = []
    private let onReloadTitles: (() async throws -> [ReaderChapterListItem])?
    private let onShowLogs: ((UIViewController) -> Void)?

    init(
        initialRuntimeConfig: AppRuntimeConfig?,
        onReloadTitles: (() async throws -> [ReaderChapterListItem])?,
        onShowLogs: ((UIViewController) -> Void)?
    ) {
        useReplace = initialRuntimeConfig?.tocUiUseReplace ?? false
        showWordCount = initialRuntimeConfig?.tocCountWords ?? true
        self.onReloadTitles = onReloadTitles
        self.onShowLogs = onShowLogs
        for name in [
            UIApplication.willResignActiveNotification, UIApplication.didBecomeActiveNotification,
            UIScene.willDeactivateNotification, UIScene.didActivateNotification,
            UIWindow.didResignKeyNotification, UIWindow.didBecomeKeyNotification,
        ] {
            environmentObservers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] notification in
                    MainActor.assumeIsolated { self?.environmentChanged(notification) }
                })
        }
    }

    deinit {
        requestTask?.cancel()
        subscription?.cancel()
        for observer in environmentObservers { NotificationCenter.default.removeObserver(observer) }
    }

    func activate() {
        guard !isActive else { return }
        isActive = true
        generation = UUID()
        hasConfirmedConfig = false
        switch SharedRuntime.settingsFacade() {
        case .success(let facade):
            self.facade = facade
            let generation = generation
            subscription = facade.watchRuntimeConfig { [weak self] config in
                DispatchQueue.main.async {
                    self?.receive(config, generation: generation)
                }
            }
        case .failure(let error):
            facade = nil
            if canUpdate?() == true { onMessage?(error.userFacingMessage) }
        }
    }

    func deactivate() {
        isActive = false
        generation = UUID()
        hasConfirmedConfig = false
        subscription?.cancel()
        subscription = nil
        dismissMenu()
        if isReloadingTitles { needsTitleReload = true }
        // Shared writes can commit after cancellation. Keep the flight until completion.
        requestTask?.cancel()
    }

    func dismissMenu() {
        menuSession = nil
        overflowMenu?.dismiss()
    }

    func canUsePresentation(_ controller: UIViewController) -> Bool {
        guard !appSuspended, !sceneSuspended, !windowSuspended,
            let window = controller.viewIfLoaded?.window, !window.isHidden, window.alpha > 0, window.isKeyWindow,
            UIApplication.shared.applicationState == .active, window.windowScene?.activationState == .foregroundActive,
            AppLockManager.shared.isUnlocked(in: window), let root = window.rootViewController
        else { return false }
        let owner = controller.parent ?? controller.presentingViewController ?? controller
        let source = currentSource(owner)
        if presentationOwner == nil {
            presentationOwner = controller
            presentationWindow = window
            presentationRoot = root
            presentationSource = source
        }
        guard presentationOwner === controller, presentationWindow === window,
            presentationRoot === root, presentationSource === source
        else { return false }
        // A fullScreen TOC removes reader.view from the window. Validate its owned-modal
        // chain and selected controllers without requiring covered ancestor views to remain attached.
        var current: UIViewController? = controller
        var expected: UIViewController?
        var last: UIViewController?
        while let candidate = current {
            guard !candidate.isBeingPresented, !candidate.isBeingDismissed,
                !candidate.isMovingFromParent, !candidate.isMovingToParent
            else { return false }
            if let presented = candidate.presentedViewController, presented !== expected { return false }
            if let navigation = candidate.parent as? UINavigationController, navigation.topViewController !== candidate {
                return false
            }
            if let tabs = candidate.parent as? UITabBarController, tabs.selectedViewController !== candidate { return false }
            last = candidate
            if let parent = candidate.parent {
                expected = nil
                current = parent
            } else {
                expected = candidate
                current = candidate.presentingViewController
            }
        }
        return last === root
    }

    private func currentSource(_ controller: UIViewController) -> UIViewController {
        var current = controller
        while true {
            if let navigation = current as? UINavigationController, let top = navigation.topViewController {
                current = top
            } else if let tabs = current as? UITabBarController, let selected = tabs.selectedViewController {
                current = selected
            } else {
                return current
            }
        }
    }

    private func environmentChanged(_ notification: Notification) {
        if let window = notification.object as? UIWindow, window !== presentationWindow { return }
        if let scene = notification.object as? UIScene, scene !== presentationWindow?.windowScene { return }
        switch notification.name {
        case UIApplication.willResignActiveNotification: appSuspended = true
        case UIApplication.didBecomeActiveNotification: appSuspended = false
        case UIScene.willDeactivateNotification: sceneSuspended = true
        case UIScene.didActivateNotification: sceneSuspended = false
        case UIWindow.didResignKeyNotification: windowSuspended = true
        case UIWindow.didBecomeKeyNotification: windowSuspended = false
        default: break
        }
        if appSuspended || sceneSuspended || windowSuspended { dismissMenu() } else { resumeUpdates() }
    }

    func resumeUpdates() {
        guard isActive, hasConfirmedConfig, canUpdate?() == true else { return }
        onWordCountChanged?()
        reloadTitlesIfNeeded()
    }

    func presentMenu(
        in presenter: UIViewController,
        anchorView: UIView,
        showingChapters: Bool,
        canReverse: Bool,
        isCurrentState: @escaping () -> Bool = { true },
        onExportBookmarks: ((Bool) -> Void)? = nil,
        onReverse: @escaping () -> Void
    ) {
        guard isActive, canUpdate?() == true, canUsePresentation(presenter), isCurrentState() else { return }
        if hasPresentedMenu {
            dismissMenu()
            return
        }
        menuSession = nil
        let replace = useReplace
        let count = showWordCount
        let request = requestID
        let revision = titleRevision
        let session = MenuSession(
            generation: generation, presentation: ReaderOverflowPresentationContext(anchor: anchorView, host: presenter.view),
            ownerIsCurrent: { [weak self, weak presenter] in
                guard let self, let presenter else { return false }
                return self.canUsePresentation(presenter) && isCurrentState()
            },
            stateIsCurrent: { [weak self, weak presenter] in
                guard let self, let presenter else { return false }
                return self.canUsePresentation(presenter) && isCurrentState() && self.useReplace == replace
                    && self.showWordCount == count && self.requestID == request && self.titleRevision == revision
            })
        menuSession = session
        func item(
            _ identifier: String, _ title: String, checked: Bool? = nil, enabled: Bool = true,
            action: @escaping () -> Void
        ) -> ReaderOverflowMenuView.Item {
            .init(identifier: identifier, title: title, isChecked: checked, isEnabled: enabled) { [weak self, weak session] in
                guard enabled, let self, let session, self.consume(session) else { return }
                action()
            }
        }
        var items: [ReaderOverflowMenuView.Item] = []
        if showingChapters {
            let canChangeSettings = hasConfirmedConfig && facade != nil && !isUpdating
            items = [
                item(
                    UIIdentifiers.ReaderChapterList.reverseButton, ReaderChapterListMenuText.reverse,
                    enabled: canReverse && !isUpdating, action: onReverse),
                item(
                    "reader.chapterList.useReplace", ReaderChapterListMenuText.useReplace, checked: useReplace,
                    enabled: canChangeSettings && onReloadTitles != nil
                ) { [weak self] in self?.toggle(.useReplace, session: session) },
                item(
                    "reader.chapterList.loadWordCount", ReaderChapterListMenuText.countWords, checked: showWordCount,
                    enabled: canChangeSettings
                ) { [weak self] in self?.toggle(.countWords, session: session) },
            ]
        } else {
            items = [
                item("reader.chapterList.exportBookmarks", L10n.SourceManagement.exportAction, enabled: onExportBookmarks != nil) {
                    onExportBookmarks?(false)
                },
                item("reader.chapterList.exportMarkdown", L10n.AllBookmark.exportMarkdown, enabled: onExportBookmarks != nil) {
                    onExportBookmarks?(true)
                },
            ]
        }
        items.append(
            item("reader.chapterList.logs", L10n.Bookshelf.logTitle, enabled: onShowLogs != nil) { [weak self, weak presenter] in
                guard let self, let presenter, self.isActive, self.canUpdate?() == true else { return }
                self.onShowLogs?(presenter)
            })
        let menu = ReaderOverflowMenuView(
            items: items, anchorView: anchorView, interfaceStyle: presenter.traitCollection.userInterfaceStyle)
        session.menu = menu
        menu.canActivateItem = { [weak self, weak session] in
            guard let self, let session else { return false }
            return !session.isDismissed && self.accepts(session)
        }
        menu.onDismiss = { [weak self, weak menu] in
            guard let self, let menu, self.overflowMenu === menu else { return }
            self.overflowMenu = nil
            session.isDismissed = true
            // ReaderOverflowMenuView dismisses synchronously before invoking the selected item.
            DispatchQueue.main.async { [weak self, weak session] in
                guard let self, let session, self.menuSession === session else { return }
                self.menuSession = nil
            }
        }
        overflowMenu = menu
        menu.present(in: presenter.view)
        if menu.superview == nil { menuSession = nil }
    }

    private func accepts(_ session: MenuSession) -> Bool {
        isActive && menuSession === session && generation == session.generation && !session.isConsumed
            && session.presentation.isCurrent && session.stateIsCurrent() && canUpdate?() == true
    }

    private func consume(_ session: MenuSession) -> Bool {
        guard session.isDismissed, let menu = session.menu, menu.superview == nil, accepts(session) else { return false }
        session.isConsumed = true
        menuSession = nil
        return true
    }

    private func receive(_ config: AppRuntimeConfig, generation: UUID) {
        guard isActive, self.generation == generation else { return }
        let titlesChanged = useReplace != config.tocUiUseReplace
        let countChanged = showWordCount != config.tocCountWords
        let firstConfirmation = !hasConfirmedConfig
        useReplace = config.tocUiUseReplace
        showWordCount = config.tocCountWords
        hasConfirmedConfig = true
        if titlesChanged {
            titleRevision = UUID()
            needsTitleReload = true
        }
        if titlesChanged || countChanged || firstConfirmation { dismissMenu() }
        if countChanged, canUpdate?() == true { onWordCountChanged?() }
        reloadTitlesIfNeeded()
    }

    private func toggle(_ setting: Setting, session: MenuSession) {
        guard isActive, hasConfirmedConfig, !isUpdating, canUpdate?() == true, let facade else { return }
        if setting == .useReplace, onReloadTitles == nil { return }
        let enabled = setting == .useReplace ? !useReplace : !showWordCount
        let generation = generation
        let id = UUID()
        requestID = id
        dismissMenu()
        requestTask = Task { @MainActor [weak self] in
            defer { self?.finishRequest(id) }
            do {
                try Task.checkCancellation()
                guard let self, self.isCurrentRequest(id, generation: generation), session.presentation.isCurrent,
                    session.ownerIsCurrent()
                else { throw CancellationError() }
                try await SharedAsync.void { completion in
                    switch setting {
                    case .useReplace:
                        facade.setTocUiUseReplace(enabled: enabled, completionHandler: completion)
                    case .countWords:
                        facade.setTocCountWords(enabled: enabled, completionHandler: completion)
                    }
                }
                // The runtime-config flow, not the requested value, confirms the stored state.
                if setting == .useReplace { self.needsTitleReload = true }
            } catch {
                guard !Task.isCancelled, !(error is CancellationError), let self,
                    self.isCurrentRequest(id, generation: generation)
                else { return }
                guard session.presentation.isCurrent, session.ownerIsCurrent() else { return }
                self.onMessage?(ReaderChapterListMenuText.saveFailed(setting.title, error: error))
            }
        }
    }

    private func reloadTitlesIfNeeded() {
        guard isActive, hasConfirmedConfig, needsTitleReload, !isUpdating,
            canUpdate?() == true, let onReloadTitles
        else { return }
        let generation = generation
        let revision = titleRevision
        let id = UUID()
        requestID = id
        needsTitleReload = false
        isReloadingTitles = true
        requestTask = Task { @MainActor [weak self] in
            defer { self?.finishRequest(id) }
            do {
                try Task.checkCancellation()
                let items = try await onReloadTitles()
                guard let self else { return }
                guard !Task.isCancelled, self.isCurrentRequest(id, generation: generation), self.titleRevision == revision else {
                    if self.titleRevision == revision, self.canUpdate?() != true { self.needsTitleReload = true }
                    return
                }
                self.onTitlesReloaded?(items)
            } catch {
                guard let self else { return }
                guard !Task.isCancelled, !(error is CancellationError), self.isCurrentRequest(id, generation: generation),
                    self.titleRevision == revision
                else {
                    if self.titleRevision == revision, self.canUpdate?() != true { self.needsTitleReload = true }
                    return
                }
                self.onMessage?(ReaderChapterListMenuText.reloadFailed(error))
            }
        }
    }

    private func isCurrentRequest(_ id: UUID, generation: UUID) -> Bool {
        isActive && self.generation == generation && requestID == id && canUpdate?() == true
    }

    private func finishRequest(_ id: UUID) {
        guard requestID == id else { return }
        requestID = nil
        requestTask = nil
        isReloadingTitles = false
        reloadTitlesIfNeeded()
    }
}

enum ReaderChapterListMenuText {
    static var reverse: String { NSLocalizedString("reader.chapter_list.reverse", value: "反转目录", comment: "") }
    static var useReplace: String { NSLocalizedString("reader.chapter_list.use_replace", value: "使用替换", comment: "") }
    static var countWords: String { NSLocalizedString("reader.chapter_list.count_words", value: "加载字数", comment: "") }
    static var reversing: String { NSLocalizedString("reader.chapter_list.reversing", value: "正在反转目录", comment: "") }

    static func reverseFailed(_ error: Error) -> String {
        String(
            format: NSLocalizedString(
                "reader.chapter_list.reverse_failed", value: "反转目录失败: %@", comment: ""), error.userFacingMessage)
    }

    static func saveFailed(_ setting: String, error: Error) -> String {
        String(
            format: NSLocalizedString(
                "reader.chapter_list.setting_save_failed", value: "保存%1$@设置失败: %2$@", comment: ""),
            setting, error.userFacingMessage)
    }

    static func reloadFailed(_ error: Error) -> String {
        String(
            format: NSLocalizedString(
                "reader.chapter_list.title_reload_failed", value: "刷新目录标题失败，已保存的设置保持不变: %@", comment: ""),
            error.userFacingMessage)
    }
}
