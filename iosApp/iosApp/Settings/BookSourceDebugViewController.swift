import UIKit
import shared

/// BookSourceDebugActivity at Legado 5f5d314; requests belong to this page, not a global logger.
@MainActor
final class BookSourceDebugViewController: UIViewController, UITextFieldDelegate, NavigationContentChromeProviding,
    @preconcurrency NavigationBackActionHandling
{
    private let provider: BookSourceDebugProviding
    private let page = BookSourceDebugPageView()
    private let menu = SearchOverflowMenuView()
    private lazy var logDelivery = BookSourceDebugLogDelivery(table: page.tableView)
    private var requestTask: Task<Void, Never>?
    private var helpTask: Task<Void, Never>?
    private var requestID = UUID()
    private var helpID = UUID()
    private let sessionID = UUID()
    private var queryRevision = UUID()
    private var actionEpoch = UUID()
    private var isVisible = false
    private var environmentActive = true
    private var controlsActive: Bool?
    private weak var boundWindow: UIWindow?
    private weak var ownedController: UIViewController?
    private weak var ownedScanner: QRCodeScannerViewController?
    private var pendingScan: (context: ActionContext, text: String)?
    private var pendingExplore: (context: ActionContext, help: UUID, index: Int)?
    private var pendingHelpFailure: (help: UUID, request: UUID, query: UUID, message: String)?
    private var report: BookSourceDebugReport?
    private var rawPages: [Int32: String] = [:]
    private var kinds: [ExploreKind] = []
    private var selectedKind = 0
    private var checkKeyword = "我的"
    private var exploreError: String?
    private var didFocusInput = false
    private var isClosed = false

    private struct ActionContext {
        let session: UUID
        let request: UUID
        let query: UUID
        let epoch: UUID
        let window: ObjectIdentifier
        let scene: ObjectIdentifier
    }

    init(sourceUrl: String, screen: BookSourceEditingProviding) {
        provider = BookSourceDebugScreenAdapter(sourceURL: sourceUrl, sourceEditor: screen)
        super.init(nibName: nil, bundle: nil)
    }

    init(provider: BookSourceDebugProviding) {
        self.provider = provider
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit {
        requestTask?.cancel()
        helpTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    override func loadView() { view = page }
    override var preferredStatusBarStyle: UIStatusBarStyle {
        ReaderPaletteColor.isLight(AndroidReplicaTheme.toolbarBackground.resolvedColor(with: traitCollection))
            ? .darkContent : .lightContent
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.SourceManagement.debugAction
        page.toolbar.accessibilityIdentifier = "sourceDebug.toolbar"
        page.toolbar.searchField.accessibilityIdentifier = "sourceDebug.query"
        page.toolbar.backButton.accessibilityIdentifier = "sourceDebug.back"
        page.toolbar.moreButton.accessibilityIdentifier = "sourceDebug.more"
        page.toolbar.submitButton.accessibilityIdentifier = "sourceDebug.submit"
        page.toolbar.searchField.delegate = self
        page.toolbar.searchField.addTarget(self, action: #selector(queryDidChange), for: .editingChanged)
        page.toolbar.onBack = { [weak self] in self?.handleBack() }
        page.toolbar.onSubmit = { [weak self] in self?.submitQuery() }
        page.toolbar.onMore = { [weak self] in self?.showMenu() }
        page.scanButton.addTarget(self, action: #selector(openScanner), for: .touchUpInside)
        page.helpView.onAction = { [weak self] action in self?.activateHelp(action) }
        logDelivery.canDeliver = { [weak self] in self?.canDeliverLogs == true }
        page.onLayout = { [weak self] in self?.refreshPresentation() }
        page.onViewportWillChange = { [weak self] in self?.logDelivery.prepareForViewportChange() }
        page.onViewportDidChange = { [weak self] in self?.logDelivery.finishViewportChange() }
        menu.onVisibilityChange = { [weak self] _ in self?.refreshPresentation() }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(refreshPalette), name: .androidReplicaThemeDidChange, object: nil)
        for name in [
            UIScene.didActivateNotification, UIScene.willDeactivateNotification,
            UIScene.didEnterBackgroundNotification, UIScene.didDisconnectNotification,
            UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification,
            UIApplication.didEnterBackgroundNotification, UIWindow.didBecomeKeyNotification,
            UIWindow.didResignKeyNotification,
        ] {
            center.addObserver(self, selector: #selector(environmentChanged(_:)), name: name, object: nil)
        }
        page.showHelp(true)
        loadHelp(refresh: false)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
        transitionCoordinator?.animate(alongsideTransition: nil) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.refreshPresentation() }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isVisible = true
        boundWindow = view.window
        refreshPresentation()
        DispatchQueue.main.async { [weak self] in self?.refreshPresentation() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        let ownsDeparture =
            (ownedScanner != nil && navigationController?.topViewController === ownedScanner)
            || (ownedController != nil && presentedViewController === ownedController)
        if !ownsDeparture {
            actionEpoch = UUID()
            pendingScan = nil
            pendingExplore = nil
        }
        menu.dismiss()
        page.helpView.invalidatePendingActions()
        refreshPresentation()
        transitionCoordinator?.animate(alongsideTransition: nil) { [weak self] context in
            guard let self, context.isCancelled else { return }
            self.isVisible = true
            DispatchQueue.main.async { [weak self] in self?.refreshPresentation() }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        menu.dismiss()
        var container: UIViewController? = self
        while let current = container {
            if current.isBeingDismissed {
                closeSession()
                break
            }
            container = current.parent
        }
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if parent == nil, isViewLoaded { closeSession() }
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        menu.dismiss()
        page.toolbar.updateQueryControls()
        page.showHelp(true)
        refreshPresentation()
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        page.toolbar.updateQueryControls()
        page.showHelp(false)
        refreshPresentation()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        guard textField.markedTextRange == nil else { return false }
        submitQuery()
        return false
    }

    private var canPresent: Bool {
        ownerAvailable && !menu.isPresented
    }

    // This intentionally excludes the owned popup flag: menu rows must remain actionable.
    private var ownerAvailable: Bool {
        guard !isClosed, isVisible, environmentActive, let window = viewIfLoaded?.window,
            window.isKeyWindow, window.windowScene?.activationState == .foregroundActive,
            UIApplication.shared.applicationState == .active,
            !view.isHidden, view.alpha > 0.01
        else { return false }
        var child: UIViewController? = self
        while let current = child {
            guard !current.isMovingFromParent, !current.isBeingDismissed, !current.isBeingPresented,
                current.presentedViewController == nil, current.transitionCoordinator == nil
            else { return false }
            if let navigation = current.parent as? UINavigationController,
                navigation.topViewController !== current
            {
                return false
            }
            if let tabs = current.parent as? UITabBarController,
                tabs.selectedViewController !== current
            {
                return false
            }
            child = current.parent
        }
        return true
    }

    private var canDeliverLogs: Bool {
        canPresent && page.helpView.isHidden && !page.toolbar.searchField.isFirstResponder
    }

    private func actionContext() -> ActionContext? {
        guard let window = viewIfLoaded?.window, let scene = window.windowScene else { return nil }
        boundWindow = window
        return ActionContext(
            session: sessionID, request: requestID, query: queryRevision, epoch: actionEpoch,
            window: ObjectIdentifier(window), scene: ObjectIdentifier(scene))
    }

    private func matches(_ context: ActionContext, includingEpoch: Bool = true, in actionWindow: UIWindow? = nil) -> Bool {
        let window = actionWindow ?? viewIfLoaded?.window
        guard !isClosed, sessionID == context.session, requestID == context.request,
            queryRevision == context.query, !includingEpoch || actionEpoch == context.epoch,
            let window, let scene = window.windowScene
        else { return false }
        return ObjectIdentifier(window) == context.window && ObjectIdentifier(scene) == context.scene
    }

    private func refreshPresentation() {
        guard isViewLoaded else { return }
        let active = canPresent
        if controlsActive != active {
            controlsActive = active
            page.toolbar.setPresentationActive(active)
            page.toolbar.setInteractionEnabled(active)
            page.scanButton.isEnabled = active
        }
        page.helpView.setActionsActive(active)
        page.setPresentationActive(active)
        logDelivery.setPresentationActive(canDeliverLogs)
        if active, let failure = pendingHelpFailure {
            pendingHelpFailure = nil
            if failure.help == helpID, failure.request == requestID, failure.query == queryRevision {
                didFocusInput = true
                page.showHelp(false)
                view.endEditing(true)
                logDelivery.append(error: failure.message)
                logDelivery.setPresentationActive(canDeliverLogs)
                return
            }
        }
        if active, let scan = pendingScan {
            pendingScan = nil
            ownedScanner = nil
            if matches(scan.context) { setQuery(scan.text, submit: true) }
        } else if active, let explore = pendingExplore {
            pendingExplore = nil
            if matches(explore.context), helpID == explore.help, kinds.indices.contains(explore.index) {
                selectedKind = explore.index
                updateHelp()
                if let query = exploreQuery, !query.hasPrefix("ERROR:") { setQuery(query, submit: true) }
            }
        } else if active, !didFocusInput {
            didFocusInput = true
            page.toolbar.searchField.becomeFirstResponder()
        }
    }

    @objc private func queryDidChange() {
        queryRevision = UUID()
        pendingScan = nil
        pendingExplore = nil
        pendingHelpFailure = nil
        page.helpView.invalidatePendingActions()
        menu.dismiss()
        refreshPresentation()
    }

    @objc private func refreshPalette() {
        setNeedsStatusBarAppearanceUpdate()
        navigationController?.setNeedsStatusBarAppearanceUpdate()
        menu.refreshAppearance(interfaceStyle: traitCollection.userInterfaceStyle)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard isViewLoaded else { return }
        refreshPalette()
    }

    @objc private func environmentChanged(_ notification: Notification) {
        let ownerWindow = viewIfLoaded?.window ?? boundWindow
        if let scene = notification.object as? UIScene, scene !== ownerWindow?.windowScene { return }
        if let window = notification.object as? UIWindow, window !== ownerWindow { return }
        let suspended = [
            UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification,
            UIScene.didDisconnectNotification, UIApplication.willResignActiveNotification,
            UIApplication.didEnterBackgroundNotification, UIWindow.didResignKeyNotification,
        ]
        .contains(notification.name)
        environmentActive = !suspended
        if suspended {
            actionEpoch = UUID()
            pendingScan = nil
            pendingExplore = nil
            page.helpView.invalidatePendingActions()
            menu.dismiss()
        }
        refreshPresentation()
        if !suspended { DispatchQueue.main.async { [weak self] in self?.refreshPresentation() } }
    }

    private func submitQuery() {
        guard canPresent, page.toolbar.searchField.markedTextRange == nil else { return }
        let query = page.toolbar.searchField.text ?? ""
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        view.endEditing(true)
        page.showHelp(false)
        refreshPresentation()
        run(query)
    }

    private func run(_ query: String) {
        cancelRequest()
        let id = requestID
        report = nil
        rawPages.removeAll()
        logDelivery.reset()
        page.setLoading(true)
        requestTask = Task { [weak self, provider] in
            // Empty reports, errors and cancellation all leave the same non-loading surface.
            defer {
                if let self, self.requestID == id, !self.isClosed {
                    self.page.setLoading(false)
                    self.requestTask = nil
                }
            }
            do {
                let report = try await provider.run(query: query) { [weak self] line in
                    let message = line.message
                    let state = line.state
                    let elapsed = line.elapsedMs
                    DispatchQueue.main.async {
                        guard let self, self.requestID == id, self.requestTask != nil, !self.isClosed else { return }
                        if [10, 20, 30, 40].contains(state) {
                            if let old = self.rawPages[state], !old.isEmpty {
                                self.rawPages[state] = old + "\n\n----- next page -----\n\n" + message
                            } else {
                                self.rawPages[state] = message
                            }
                        } else {
                            self.logDelivery.append(state: state, message: message, elapsed: elapsed)
                            if state == -1 || state == 1000 { self.page.setLoading(false) }
                        }
                    }
                }
                await Self.drainLogCallbacks()
                try Task.checkCancellation()
                guard let self, self.requestID == id, !self.isClosed else { return }
                self.report = report
                self.logDelivery.finish(report.logs)
            } catch is CancellationError {
                await Self.drainLogCallbacks()
            } catch {
                await Self.drainLogCallbacks()
                guard let self, self.requestID == id, !self.isClosed else { return }
                self.logDelivery.append(error: error.userFacingMessage)
            }
        }
    }

    private static func drainLogCallbacks() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func cancelRequest() {
        requestID = UUID()
        pendingHelpFailure = nil
        requestTask?.cancel()
        requestTask = nil
        page.setLoading(false)
    }

    private func closeSession() {
        guard !isClosed else { return }
        isClosed = true
        actionEpoch = UUID()
        cancelRequest()
        helpID = UUID()
        helpTask?.cancel()
        helpTask = nil
        menu.dismiss()
        refreshPresentation()
    }

    private func loadHelp(refresh: Bool) {
        helpTask?.cancel()
        helpID = UUID()
        let id = helpID
        pendingHelpFailure = nil
        if refresh {
            cancelRequest()
            report = nil
            rawPages.removeAll()
            logDelivery.reset()
            page.showHelp(true)
            refreshPresentation()
        }
        let request = requestID
        let query = queryRevision
        helpTask = Task { [weak self, provider] in
            do {
                let keyword = try await provider.loadCheckKeyword()
                try Task.checkCancellation()
                guard let self, self.helpID == id, !self.isClosed else { return }
                self.checkKeyword = keyword
                self.updateHelp()
                let values = try await provider.loadKinds(refresh: refresh)
                try Task.checkCancellation()
                guard self.helpID == id, !self.isClosed else { return }
                self.kinds = values.filter { $0.url?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
                self.selectedKind = 0
                self.exploreError = nil
                self.updateHelp()
                if let first = self.kinds.first, first.title.hasPrefix("ERROR:") {
                    self.exploreError = self.exploreQuery
                    self.updateHelp()
                    self.enqueueHelpFailure("获取发现出错\n\(first.url ?? "")", help: id, request: request, query: query)
                }
            } catch is CancellationError {
            } catch {
                guard let self, self.helpID == id, !self.isClosed else { return }
                self.exploreError = error.userFacingMessage
                self.kinds = []
                self.updateHelp()
                self.enqueueHelpFailure("获取发现出错\n\(error.userFacingMessage)", help: id, request: request, query: query)
            }
        }
    }

    private func enqueueHelpFailure(_ message: String, help: UUID, request: UUID, query: UUID) {
        // A late discovery failure must not hide input or replace a newer debug request's logs.
        guard !isClosed, helpID == help, requestID == request, queryRevision == query else { return }
        pendingHelpFailure = (help, request, query, message)
        refreshPresentation()
    }

    private var exploreQuery: String? {
        guard kinds.indices.contains(selectedKind) else { return nil }
        let kind = kinds[selectedKind]
        return "\(kind.title)::\(kind.url ?? "")"
    }

    private func updateHelp() {
        page.helpView.configure(checkKeyword: checkKeyword, exploreTitle: exploreQuery, exploreError: exploreError)
        page.helpView.onExploreLongPress = kinds.isEmpty ? nil : { [weak self] in self?.chooseExploreKind() }
    }

    private func activateHelp(_ action: BookSourceDebugHelpView.Action) {
        guard canPresent else { return }
        switch action {
        case .keyword(let value): setQuery(value, submit: true)
        case .explore:
            let query = exploreQuery ?? "系统::http://xxx"
            if exploreError == nil, !query.hasPrefix("ERROR:") { setQuery(query, submit: true) }
        case .detail:
            if let query = page.toolbar.searchField.text, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                setQuery(query, submit: true)
            }
        case .toc: completePrefix("++")
        case .content: completePrefix("--")
        }
    }

    private func completePrefix(_ prefix: String) {
        let query = page.toolbar.searchField.text ?? ""
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || query.utf16.count <= 2 {
            setQuery(prefix, submit: false)
        } else {
            setQuery(query.hasPrefix(prefix) ? query : prefix + query, submit: true)
        }
    }

    private func setQuery(_ query: String, submit: Bool) {
        page.toolbar.searchField.text = query
        queryDidChange()
        page.toolbar.updateQueryControls()
        if submit { submitQuery() } else { page.toolbar.searchField.becomeFirstResponder() }
    }

    private func chooseExploreKind() {
        guard canPresent, !kinds.isEmpty, let context = actionContext() else { return }
        let help = helpID
        let values = kinds
        let choices = ReaderBookChoiceDialogViewController(
            title: "选择发现",
            choices: values.enumerated().map { index, kind in
                .init(title: kind.title, accessibilityValue: String(index))
            }, identifierPrefix: "sourceDebug.exploreChoice"
        ) { [weak self] index in
            guard let self, self.matches(context), self.helpID == help,
                values.indices.contains(index)
            else { return }
            self.pendingExplore = (context, help, index)
            DispatchQueue.main.async { [weak self] in self?.refreshPresentation() }
        }
        choices.onClose = { [weak self, weak choices] in self?.ownedControllerDidClose(choices) }
        choices.overrideUserInterfaceStyle = traitCollection.userInterfaceStyle
        ownedController = choices
        present(choices, animated: true)
        refreshPresentation()
    }

    private func showMenu() {
        guard canPresent, let context = actionContext() else { return }
        let items: [SearchOverflowMenuView.Item] = [
            .init(id: "search", title: "搜索源码"), .init(id: "detail", title: "书籍源码"),
            .init(id: "toc", title: "目录源码"), .init(id: "content", title: "正文源码"),
            .init(id: "refresh", title: "刷新发现"), .init(id: "help", title: "帮助"),
        ]
        menu.canActivateItem = { [weak self] in
            guard let self else { return false }
            return self.matches(context) && self.ownerAvailable
        }
        menu.refreshAppearance(interfaceStyle: traitCollection.userInterfaceStyle)
        menu.show(in: view, anchor: page.toolbar.moreButton, items: items) { [weak self] action in
            guard let self, self.matches(context), self.canPresent else { return }
            switch action {
            case "refresh": self.loadHelp(refresh: true)
            case "help": self.showText(BookSourceDebugScreenAdapter.helpText, title: "帮助", rendersHelp: true)
            default:
                let pages = self.report?.rawPages
                let text: String?
                switch action {
                case "search": text = pages?.search ?? self.rawPages[10]
                case "detail": text = pages?.detail ?? self.rawPages[20]
                case "toc": text = pages?.toc ?? self.rawPages[30]
                default: text = pages?.content ?? self.rawPages[40]
                }
                self.showText(text ?? "", title: "html")
            }
        }
    }

    private func showText(_ text: String, title: String, rendersHelp: Bool = false) {
        guard canPresent, let context = actionContext() else { return }
        view.endEditing(true)
        let controller = BookSourceDebugRawViewController(text: text, title: title, rendersHelp: rendersHelp)
        controller.isContentCurrent = { [weak self] in self?.matches(context, includingEpoch: false) == true }
        controller.onClose = { [weak self, weak controller] in self?.ownedControllerDidClose(controller) }
        controller.overrideUserInterfaceStyle = traitCollection.userInterfaceStyle
        ownedController = controller
        present(controller, animated: true)
        refreshPresentation()
    }

    private func ownedControllerDidClose(_ controller: UIViewController?) {
        guard let controller, ownedController === controller else { return }
        ownedController = nil
        refreshPresentation()
        DispatchQueue.main.async { [weak self] in self?.refreshPresentation() }
    }

    @objc private func openScanner() {
        guard canPresent, let navigation = navigationController, let context = actionContext() else { return }
        view.endEditing(true)
        menu.dismiss()
        let scanner = QRCodeScannerViewController()
        ownedScanner = scanner
        scanner.onQRCodeScanned = { [weak self, weak scanner, weak navigation] text in
            guard let self, let scanner, let navigation,
                self.matches(context, in: scanner.viewIfLoaded?.window),
                self.ownedScanner === scanner, navigation.topViewController === scanner,
                scanner.navigationController === navigation,
                scanner.presentedViewController == nil, scanner.transitionCoordinator == nil,
                scanner.viewIfLoaded?.window?.isKeyWindow == true,
                scanner.viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive,
                UIApplication.shared.applicationState == .active
            else { return }
            scanner.onQRCodeScanned = nil
            self.pendingScan = (context, text)
            navigation.popViewController(animated: true)
            if let transition = navigation.transitionCoordinator {
                transition.animate(alongsideTransition: nil) { [weak self] transitionContext in
                    if transitionContext.isCancelled { self?.pendingScan = nil }
                    DispatchQueue.main.async { [weak self] in self?.refreshPresentation() }
                }
            } else {
                DispatchQueue.main.async { [weak self] in self?.refreshPresentation() }
            }
        }
        navigation.pushViewController(scanner, animated: true)
    }

    private func handleBack() {
        if menu.isPresented {
            menu.dismiss()
            return
        }
        guard canPresent else { return }
        if page.toolbar.searchField.isFirstResponder {
            view.endEditing(true)
        } else if navigationController?.viewControllers.first !== self {
            navigationController?.popViewController(animated: true)
        } else {
            dismiss(animated: true)
        }
    }

    func interceptNavigationBackGesture() -> Bool {
        if menu.isPresented {
            menu.dismiss()
            return true
        }
        guard page.toolbar.searchField.isFirstResponder else { return false }
        view.endEditing(true)
        return true
    }

    override func accessibilityPerformEscape() -> Bool {
        guard canPresent || menu.isPresented else { return false }
        handleBack()
        return true
    }
}
