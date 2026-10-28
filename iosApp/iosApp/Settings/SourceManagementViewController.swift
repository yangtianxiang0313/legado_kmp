import SnapKit
import UIKit
import shared

final class BookSourceEditViewController: UIViewController, NavigationBackActionHandling {
    var onSourceSaved: ((BookSource) -> Void)?
    private let mode: BookSourceEditMode
    private let screen: BookSourceEditingProviding
    private let persistence: BookSourceEditorPersistence
    private let contentArea = UIView()
    private lazy var toolbar = BookSourceEditorToolbarView(
        title: L10n.SourceEdit.editTitle)
    private let stateView = ContentStateView()
    private let scrollView = UIScrollView()
    private weak var activeEditingView: UIView?
    private let contentStack = UIStackView()
    private let tabControl = BookSourceEditorTabsView()
    private let optionsView = BookSourceEditorOptionsView()
    private var backButton: UIButton { toolbar.backButton }
    private var saveButton: UIButton { toolbar.saveButton }
    private var moreButton: UIButton { toolbar.moreButton }
    private weak var overflowMenu: ReaderOverflowMenuView?
    private var activeMenuSession: UUID?
    private weak var exitDialog: ReaderExitConfirmationDialogViewController?
    private var exitDialogSession: UUID?
    private var sectionViews: [SourceEditorTab: BookSourceEditorFormView] = [:]
    private var draft = BookSourceEditorDraft()
    private var savedDraftPayload: Data?
    private var isDirty = false
    private var originalSourceURL: String?
    private var hasLoadedSource = false
    private var loadTask: Task<Void, Never>?
    private var loadRequestID: UUID?
    private var isSaving = false
    private var saveNavigationID: UUID?
    private var pendingSaveError: (error: Error, context: BookSourceEditorCommandContext)?
    private var isEditorVisible = false
    private var draftRevision = 0
    private var autoComplete = false
    private var commandSession = UUID()
    private var presentationTimer: Timer?
    private var isStartingPresentation = false
    private var observedModal: ObjectIdentifier?
    private var needsInitialLoad = true
    private lazy var commands: BookSourceEditorCommands = BookSourceEditorCommands(
        presenter: self, screen: screen,
        accepts: { [weak self] context, modal in self?.isCurrent(context, modal: modal) == true },
        onDraft: { [weak self] payload in
            guard let self else { return }
            self.populate(with: payload, originalSourceURL: self.originalSourceURL, importedDraft: true)
            self.markDraftChanged()
        },
        onPresentationChange: { [weak self] in
            guard let self else { return }
            if self.hasLoadedSource, !self.isSaving {
                if self.commands.isBusy { self.stateView.showLoading(message: L10n.SourceEdit.loading) } else { self.stateView.hide() }
            }
            self.updateMoreMenu()
        })

    init(mode: BookSourceEditMode, screen: BookSourceEditingProviding) {
        self.mode = mode
        self.screen = screen
        persistence = BookSourceEditorPersistence(screen: screen)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        loadTask?.cancel()
        presentationTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureScaffold()
        configureTabs()
        configureSections()
        configureStateView()
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshPalette), name: .androidReplicaThemeDidChange, object: nil)
        refreshPalette()
        for name in [
            UIApplication.willResignActiveNotification, UIApplication.didBecomeActiveNotification,
            UIScene.willDeactivateNotification, UIScene.didActivateNotification,
            UIWindow.didResignKeyNotification, UIWindow.didBecomeKeyNotification,
        ] {
            NotificationCenter.default.addObserver(self, selector: #selector(applicationActivityChanged(_:)), name: name, object: nil)
        }
        updateMoreMenu()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isEditorVisible = true
        updateMoreMenu()
        if !hasLoadedSource, loadTask == nil { loadSource() }
        if presentationTimer == nil {
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshEditorPresentation()
                }
            }
            presentationTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        presentPendingSaveErrorIfVisible()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        toolbar.updateLayout(availableSize: view.bounds.size)
        revealActiveEditor()
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        ReaderPaletteColor.isLight(AndroidReplicaTheme.toolbarBackground.resolvedColor(with: traitCollection))
            ? .darkContent : .lightContent
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        refreshPalette()
    }

    @objc private func refreshPalette() {
        guard isViewLoaded else { return }
        view.backgroundColor = AndroidReplicaTheme.toolbarBackground.resolvedColor(with: traitCollection)
        contentArea.backgroundColor = AndroidReplicaTheme.background.resolvedColor(with: traitCollection)
        let palette = ReaderTocPalette(traits: traitCollection)
        stateView.backgroundColor = palette.background
        stateView.tintColor = palette.accent
        let items = stateView.subviews.compactMap { $0 as? UIStackView }.flatMap(\.arrangedSubviews)
        for (index, label) in items.compactMap({ $0 as? UILabel }).enumerated() {
            label.textColor = index == 0 ? palette.primaryText : palette.secondaryText
        }
        for case let indicator as UIActivityIndicatorView in items { indicator.color = palette.accent }
        for case let button as UIButton in items {
            button.configuration?.baseBackgroundColor = palette.accent
            button.configuration?.baseForegroundColor = ReaderPaletteColor.primaryText(on: palette.accent)
        }
        setNeedsStatusBarAppearanceUpdate()
        navigationController?.setNeedsStatusBarAppearanceUpdate()
    }

    func interceptNavigationBackGesture() -> Bool {
        if isSaving { return true }
        guard isDirty || overflowMenu != nil else { return false }
        handleBack()
        return true
    }

    override func accessibilityPerformEscape() -> Bool {
        handleBack()
        return true
    }

    override var keyCommands: [UIKeyCommand]? {
        let back = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(handleBack))
        back.wantsPriorityOverSystemBehavior = true
        return [back]
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        overflowMenu?.dismiss()
        isEditorVisible = false
        updateMoreMenu()
        // A full-screen owned dialog may hide the editor without leaving its command session.
        if ownsEditorModal(presentedViewController), !isMovingFromParent, !isBeingDismissed,
            navigationController?.isBeingDismissed != true
        {
            return
        }
        invalidateCommandSession()
        presentationTimer?.invalidate()
        presentationTimer = nil
    }

    override func present(_ viewControllerToPresent: UIViewController, animated flag: Bool, completion: (() -> Void)? = nil) {
        if !ownsEditorModal(viewControllerToPresent) { invalidateCommandSession() }
        observedModal = ObjectIdentifier(viewControllerToPresent)
        isStartingPresentation = true
        updateMoreMenu()
        super.present(viewControllerToPresent, animated: flag) { [weak self] in
            self?.isStartingPresentation = false
            self?.updateMoreMenu()
            completion?()
        }
    }

    private func refreshEditorPresentation() {
        if isStartingPresentation, presentedViewController == nil { isStartingPresentation = false }
        commands.refreshPresentation()
        var current: UIViewController? = self
        var cover: UIViewController?
        while let controller = current {
            if let presented = controller.presentedViewController {
                cover = presented
                break
            }
            current = controller.parent
        }
        let identity = cover.map(ObjectIdentifier.init)
        if identity != observedModal, let cover, !ownsEditorModal(cover) { invalidateCommandSession() }
        observedModal = identity
        updateMoreMenu()
        if needsInitialLoad, !hasLoadedSource, loadTask == nil { loadSource() }
        presentPendingSaveErrorIfVisible()
    }

    private func ownsEditorModal(_ modal: UIViewController?) -> Bool {
        commands.owns(modal) || (modal != nil && modal === exitDialog)
    }

    private func invalidateCommandSession() {
        commandSession = UUID()
        exitDialog?.cancelPresentation()
        activeMenuSession = nil
        saveNavigationID = nil
        pendingSaveError = nil
        loadRequestID = nil
        loadTask?.cancel()
        loadTask = nil
        needsInitialLoad = !hasLoadedSource
        commands.invalidate()
    }

    @objc private func applicationActivityChanged(_ notification: Notification) {
        if let scene = notification.object as? UIScene, scene !== viewIfLoaded?.window?.windowScene { return }
        if let window = notification.object as? UIWindow, window !== viewIfLoaded?.window { return }
        if [
            UIApplication.willResignActiveNotification, UIScene.willDeactivateNotification,
            UIWindow.didResignKeyNotification,
        ].contains(notification.name) {
            overflowMenu?.dismiss()
            invalidateCommandSession()
        } else {
            if isEditorVisible, !hasLoadedSource, loadTask == nil { loadSource() }
            presentPendingSaveErrorIfVisible()
        }
        updateMoreMenu()
    }

    @objc private func handleBack() {
        guard !isSaving, canPresentEditorResult else { return }
        if let overflowMenu {
            overflowMenu.dismiss()
            return
        }
        guard toolbar.canInteract else { return }
        commitPendingInput()
        refreshDraftDirtyState()
        saveNavigationID = nil
        guard isDirty else {
            finishEditorNavigation()
            return
        }
        guard let context = commandContext() else { return }
        let session = UUID()
        let dialog = ReaderExitConfirmationDialogViewController(
            title: NSLocalizedString("source_edit.exit_title", value: "退出", comment: "Legado exit"),
            message: NSLocalizedString("source_edit.exit_no_save", value: "尚未保存，是否继续编辑", comment: "Legado exit_no_save"),
            confirmTitle: NSLocalizedString("source_edit.exit_yes", value: "是", comment: "Legado yes"),
            accessibilityIdentifierPrefix: "sourceEdit.exit"
        ) { [weak self] decision in
            guard let self, self.exitDialogSession == session else { return }
            self.exitDialog = nil
            self.exitDialogSession = nil
            defer { self.updateMoreMenu() }
            // The dialog has detached; only an explicit No may discard this same draft.
            guard decision == false, !self.isSaving, self.isCurrent(context, modal: nil) else { return }
            self.finishEditorNavigation()
        }
        dialog.canDecide = { [weak self, weak dialog] in
            guard let self, let dialog, self.exitDialog === dialog,
                self.exitDialogSession == session, !self.isSaving
            else { return false }
            return self.isCurrent(context, modal: self.presentedViewController === dialog ? dialog : nil)
        }
        exitDialog = dialog
        exitDialogSession = session
        present(dialog, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    private func finishEditorNavigation() {
        guard let navigation = navigationController, navigation.topViewController === self else { return }
        if navigation.viewControllers.count > 1 {
            navigation.popViewController(animated: true)
        } else if let presenter = navigation.presentingViewController,
            presenter.presentedViewController === navigation, !navigation.isBeingDismissed
        {
            navigation.dismiss(animated: true)
        }
    }

    @objc private func handleSave() {
        guard toolbar.canInteract else { return }
        saveSource()
    }

    @objc private func handleMore() {
        guard hasLoadedSource, !isSaving, !commands.isBusy, toolbar.canInteract, canPresentEditorResult else { return }
        commitPendingInput()
        guard let context = commandContext() else { return }
        let menuSession = UUID()
        activeMenuSession = menuSession
        let menu = ReaderOverflowMenuView(
            items: BookSourceEditorMenuAction.visibleActions(
                hasLogin: !fieldText("loginUrl").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !fieldText("loginUi").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ).map {
                action in
                .init(
                    identifier: action.rawValue, title: action.title,
                    isChecked: action == .autoComplete ? autoComplete : nil
                ) { [weak self] in
                    guard let self, self.activeMenuSession == menuSession, self.hasLoadedSource,
                        !self.isSaving, self.isCurrent(context, modal: nil)
                    else { return }
                    self.activeMenuSession = nil
                    self.performMenuAction(action)
                }
            }, anchorView: moreButton, interfaceStyle: traitCollection.userInterfaceStyle)
        menu.onDismiss = { [weak self, weak menu] in
            guard self?.overflowMenu === menu else { return }
            self?.overflowMenu = nil
            self?.updateMoreMenu()
        }
        menu.canActivateItem = { [weak self] in
            guard let self else { return false }
            return self.activeMenuSession == menuSession && self.isCurrent(context, modal: nil) && !self.isSaving
        }
        overflowMenu?.dismiss()
        overflowMenu = menu
        menu.present(in: view)
        updateMoreMenu()
    }

    @objc private func handleDebug() {
        guard toolbar.canInteract else { return }
        saveSource(then: .debug)
    }

    @objc private func tabChanged() {
        guard toolbar.canInteract, !commands.isBusy, overflowMenu == nil, canPresentEditorResult else { return }
        overflowMenu?.dismiss()
        commitPendingInput()
        activeEditingView = nil
        for (key, view) in sectionViews {
            view.isHidden = key != tabControl.selectedTab
        }
        scrollView.setContentOffset(.zero, animated: false)
    }

    private func configureScaffold() {
        view.addSubview(toolbar)
        view.addSubview(contentArea)
        toolbar.snp.makeConstraints { make in make.top.leading.trailing.equalTo(view.safeAreaLayoutGuide) }
        contentArea.snp.makeConstraints { make in
            make.top.equalTo(toolbar.snp.bottom)
            make.leading.trailing.bottom.equalToSuperview()
        }
        backButton.accessibilityIdentifier = UIIdentifiers.Common.drillDownBackButton
        backButton.accessibilityLabel = "返回"
        saveButton.accessibilityIdentifier = UIIdentifiers.SourceEdit.saveButton
        saveButton.accessibilityLabel = L10n.SourceEdit.saveAction
        moreButton.accessibilityIdentifier = UIIdentifiers.SourceEdit.moreButton
        moreButton.accessibilityLabel = "更多"
        backButton.addTarget(self, action: #selector(handleBack), for: .touchUpInside)
        saveButton.addTarget(self, action: #selector(handleSave), for: .touchUpInside)
        moreButton.addTarget(self, action: #selector(handleMore), for: .touchUpInside)
        toolbar.debugButton.addTarget(self, action: #selector(handleDebug), for: .touchUpInside)
        updateMoreMenu()

        contentArea.addSubview(optionsView)
        contentArea.addSubview(tabControl)
        contentArea.addSubview(scrollView)
        scrollView.addSubview(contentStack)
        optionsView.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
        }
        tabControl.snp.makeConstraints { make in
            make.top.equalTo(optionsView.snp.bottom)
            make.leading.trailing.equalToSuperview()
        }
        scrollView.snp.makeConstraints { make in
            make.top.equalTo(tabControl.snp.bottom)
            make.leading.trailing.equalToSuperview()
        }
        scrollView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor).isActive = true
        scrollView.keyboardDismissMode = .interactive
        scrollView.contentInsetAdjustmentBehavior = .never
        contentStack.axis = .vertical
        contentStack.spacing = 0
        contentStack.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(UIEdgeInsets(top: 0, left: 0, bottom: 16, right: 0))
            make.width.equalTo(scrollView.snp.width)
        }
    }

    private func configureTabs() {
        tabControl.selectedTab = .base
        tabControl.accessibilityIdentifier = UIIdentifiers.SourceEdit.tabControl
        tabControl.addTarget(self, action: #selector(tabChanged), for: .valueChanged)
        optionsView.onChange = { [weak self] in
            guard let self, self.toolbar.canInteract, !self.commands.isBusy,
                self.overflowMenu == nil, self.canPresentEditorResult
            else { return }
            self.draft.sourceType = self.optionsView.sourceType
            self.draft.enabled = self.optionsView.enabled
            self.draft.enabledExplore = self.optionsView.enabledExplore
            self.draft.enabledCookieJar = self.optionsView.enabledCookieJar
            self.markDraftChanged()
        }
    }

    private func configureSections() {
        for tab in SourceEditorTab.allCases {
            let form = BookSourceEditorFormView(tab: tab)
            form.onChange = { [weak self] field, text in
                self?.draft.setText(text, for: field)
                self?.markDraftChanged()
            }
            form.onEditing = { [weak self] textView in
                self?.activeEditingView = textView
                self?.revealActiveEditor()
            }
            sectionViews[tab] = form
            form.isHidden = tab != .base
            contentStack.addArrangedSubview(form)
        }
    }

    private func configureStateView() {
        contentArea.addSubview(stateView)
        stateView.snp.makeConstraints { make in
            make.edges.equalTo(scrollView)
        }
    }

    private func loadSource() {
        guard hasLoadedSource == false, isDirty == false, isSaving == false,
            canPresentEditorResult, let context = commandContext()
        else { return }
        loadTask?.cancel()
        let requestID = UUID()
        loadRequestID = requestID
        needsInitialLoad = false
        stateView.showLoading(message: L10n.SourceEdit.loading)
        loadTask = Task { @MainActor [weak self, screen, mode] in
            do {
                let dictionary: [String: Any]
                switch mode {
                case .create:
                    dictionary = [:]
                case .edit(let sourceURL):
                    let payload = try await screen.exportSource(sourceUrl: sourceURL)
                    dictionary = try BookSourceEditorDraft.decodePayload(payload)
                }
                guard let self, self.loadRequestID == requestID else { return }
                self.loadRequestID = nil
                self.loadTask = nil
                guard !Task.isCancelled, !self.hasLoadedSource, !self.isDirty, self.isCurrent(context, modal: nil)
                else {
                    self.needsInitialLoad = !self.hasLoadedSource
                    return
                }
                self.populate(with: dictionary, originalSourceURL: mode.existingSourceURL)
            } catch {
                guard let self, self.loadRequestID == requestID else { return }
                self.loadRequestID = nil
                self.loadTask = nil
                guard !Task.isCancelled, self.isCurrent(context, modal: nil)
                else {
                    self.needsInitialLoad = !self.hasLoadedSource
                    return
                }
                self.stateView.showMessage(
                    title: L10n.SourceEdit.loadFailed,
                    message: error.userFacingMessage,
                    actionTitle: L10n.Common.retry
                ) { [weak self] in
                    self?.loadSource()
                }
            }
        }
    }

    private func populate(with payload: [String: Any], originalSourceURL: String?, importedDraft: Bool = false) {
        loadRequestID = nil
        loadTask?.cancel()
        loadTask = nil
        hasLoadedSource = true
        needsInitialLoad = false
        stateView.hide()
        draft.load(payload)
        if !importedDraft { savedDraftPayload = try? draft.payloadData() }
        self.originalSourceURL = originalSourceURL
        for form in sectionViews.values { form.populate { draft.text(for: $0) } }
        optionsView.sourceType = draft.sourceType
        optionsView.enabled = draft.enabled
        optionsView.enabledExplore = draft.enabledExplore
        optionsView.enabledCookieJar = draft.enabledCookieJar
        if importedDraft {
            tabControl.selectedTab = .base
            for (tab, form) in sectionViews { form.isHidden = tab != .base }
            activeEditingView = nil
            scrollView.setContentOffset(.zero, animated: false)
        }
        refreshDraftDirtyState()
        updateMoreMenu()
    }

    private func revealActiveEditor() {
        guard let editor = activeEditingView, editor.isFirstResponder else { return }
        let inputRect: CGRect
        if let textView = editor as? UITextView, let selection = textView.selectedTextRange {
            inputRect = textView.caretRect(for: selection.end)
        } else {
            inputRect = editor.bounds
        }
        let rect = editor.convert(inputRect, to: scrollView).insetBy(dx: 0, dy: -12)
        scrollView.scrollRectToVisible(rect, animated: false)
    }

    private func markDraftChanged() {
        draftRevision += 1
        // Compare the complete payload on exit, not on each keystroke in a large code field.
        isDirty = true
        saveNavigationID = nil
        updateMoreMenu()
    }

    private func refreshDraftDirtyState() {
        isDirty = savedDraftPayload == nil || (try? draft.payloadData()) != savedDraftPayload
    }

    private func commitPendingInput() {
        for tab in SourceEditorTab.allCases {
            for field in BookSourceEditorField.fields(for: tab) {
                sectionViews[tab]?.textView(for: field.id)?.unmarkText()
            }
        }
        view.endEditing(true)
    }

    private func saveSource(then destination: SourceEditorSaveDestination = .back) {
        guard hasLoadedSource, !isSaving, !commands.isBusy, canPresentEditorResult else { return }
        commitPendingInput()
        guard let context = commandContext() else { return }
        let payload: Data
        do { payload = try buildSourcePayloadData() } catch {
            presentError(error)
            return
        }
        let originalURL = originalSourceURL
        isSaving = true
        pendingSaveError = nil
        let navigationID = UUID()
        saveNavigationID = navigationID
        updateMoreMenu()
        stateView.showLoading(message: L10n.SourceEdit.saving)
        // Finish authorized writes and rename cleanup even if navigation is revoked.
        Task { @MainActor [self] in
            var savedURL: String?
            var savedSource: BookSource?
            do {
                let result = try await self.persistence.save(payload: payload, originalSourceURL: originalURL)
                self.onSourceSaved?(result.source)
                let sourceURL = result.source.bookSourceUrl
                if context.draftRevision == self.draftRevision, context.sourceURL == self.commandContext()?.sourceURL {
                    self.populate(with: result.savedPayload, originalSourceURL: sourceURL)
                    savedURL = sourceURL
                    savedSource = result.source
                } else {
                    self.originalSourceURL = sourceURL
                    self.isDirty = true
                }
            } catch {
                if savedURL == nil { self.refreshDraftDirtyState() }
                if self.isCurrent(context, modal: nil) { self.pendingSaveError = (error, context) }
            }
            self.isSaving = false
            self.stateView.hide()
            self.updateMoreMenu()
            let shouldNavigate = self.saveNavigationID == navigationID && self.isCurrent(context, modal: nil)
            self.saveNavigationID = nil
            guard let savedURL, shouldNavigate else {
                self.presentPendingSaveErrorIfVisible()
                return
            }
            switch destination {
            case .back:
                self.finishEditorNavigation()
            case .search:
                self.navigationController?.pushViewController(
                    AndroidReplicaSearchViewController(preferredSourceURL: savedURL).configuredForDrillDownPresentation(),
                    animated: true
                )
            case .debug:
                self.navigationController?.pushViewController(
                    BookSourceDebugViewController(sourceUrl: savedURL, screen: self.screen).configuredForDrillDownPresentation(),
                    animated: true)
            case .login:
                SourceLoginEntry.open(sourceURL: savedURL, from: self)
            case .sourceVariable:
                if let savedSource, let current = self.commandContext() {
                    self.commands.editVariable(source: savedSource, context: current)
                }
            }
        }
    }

    private var isEditorForeground: Bool {
        isEditorVisible && isSceneHierarchyCurrent(modal: nil)
    }

    private var canPresentEditorResult: Bool {
        isEditorForeground && !isStartingPresentation
    }

    private func commandContext() -> BookSourceEditorCommandContext? {
        guard let window = viewIfLoaded?.window, let scene = window.windowScene else { return nil }
        let url = hasLoadedSource ? fieldText("bookSourceUrl") : (mode.existingSourceURL ?? "")
        return .init(
            sourceURL: url.trimmingCharacters(in: .whitespacesAndNewlines),
            draftRevision: draftRevision, session: commandSession,
            scene: ObjectIdentifier(scene), window: ObjectIdentifier(window))
    }

    private func isCurrent(_ context: BookSourceEditorCommandContext, modal: UIViewController?) -> Bool {
        commandContext() == context && isSceneHierarchyCurrent(modal: modal)
            && (modal != nil || (isEditorVisible && !isStartingPresentation))
    }

    private func isSceneHierarchyCurrent(modal: UIViewController?) -> Bool {
        guard navigationController?.topViewController === self,
            UIApplication.shared.applicationState == .active,
            let window = viewIfLoaded?.window, window.isKeyWindow, !window.isHidden, window.alpha > 0,
            window.windowScene?.activationState == .foregroundActive,
            presentedViewController === modal
        else { return false }
        var ancestor: UIView? = view
        while let current = ancestor {
            if current.isHidden || current.alpha <= 0.01 { return false }
            ancestor = current.superview
        }
        var controller: UIViewController? = self
        while let current = controller {
            if current.isBeingDismissed || current.isMovingFromParent || current.isBeingPresented
                || current.transitionCoordinator?.isInteractive == true
            {
                return false
            }
            if let cover = current.presentedViewController, cover !== modal { return false }
            if let tabs = current.parent as? UITabBarController, tabs.selectedViewController !== current { return false }
            controller = current.parent
        }
        return true
    }

    private func presentPendingSaveErrorIfVisible() {
        guard let pending = pendingSaveError, isCurrent(pending.context, modal: nil) else { return }
        pendingSaveError = nil
        presentError(pending.error)
    }

    private func buildSourcePayloadData() throws -> Data {
        var snapshot = draft
        for tab in SourceEditorTab.allCases {
            for field in BookSourceEditorField.fields(for: tab) {
                if let editor = sectionViews[tab]?.textView(for: field.id) {
                    snapshot.setText(editor.text, for: field)
                }
            }
        }
        return try persistence.makeOutput(payload: snapshot.payloadData(), autoComplete: autoComplete)
    }

    private func fieldText(_ key: String) -> String {
        for tab in SourceEditorTab.allCases {
            if let field = BookSourceEditorField.fields(for: tab).first(where: { $0.id == key }) {
                return sectionViews[tab]?.textView(for: key)?.text ?? draft.text(for: field)
            }
        }
        return ""
    }

    private func updateMoreMenu() {
        toolbar.setBusy(isSaving)
        let enabled = hasLoadedSource && !isSaving && !commands.isBusy
        saveButton.isEnabled = enabled
        toolbar.debugButton.isEnabled = enabled
        moreButton.isEnabled = enabled
        tabControl.isEnabled = enabled
        contentStack.isUserInteractionEnabled = enabled
        optionsView.isUserInteractionEnabled = enabled
        let active = canPresentEditorResult && overflowMenu == nil && exitDialog == nil && !isSaving
        toolbar.setPresentationActive(active)
        tabControl.setPresentationActive(active && enabled)
        optionsView.setPresentationActive(active && enabled)
        for form in sectionViews.values { form.setPresentationActive(active && enabled) }
        scrollView.isScrollEnabled = active && enabled
    }

    private func performMenuAction(_ action: BookSourceEditorMenuAction) {
        switch action {
        case .login: saveSource(then: .login)
        case .search: saveSource(then: .search)
        case .clearCookie:
            let sourceURL = fieldText("bookSourceUrl").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sourceURL.isEmpty, let context = commandContext() else { return }
            Task { @MainActor [weak self, screen] in
                do { try await screen.clearSourceCookies(sourceUrl: sourceURL) } catch {
                    guard let self, self.isCurrent(context, modal: nil) else { return }
                    self.presentError(error)
                }
            }
        case .autoComplete:
            autoComplete.toggle()
        case .copy, .shareString:
            do {
                let data = try buildSourcePayloadData()
                let string = String(decoding: data, as: UTF8.self)
                if action == .copy {
                    UIPasteboard.general.string = string
                } else {
                    let activity = UIActivityViewController(activityItems: [string], applicationActivities: nil)
                    activity.popoverPresentationController?.sourceView = moreButton
                    activity.popoverPresentationController?.sourceRect = moreButton.bounds
                    present(activity, animated: true)
                }
            } catch { presentError(error) }
        case .paste:
            guard let string = UIPasteboard.general.string, let context = commandContext() else { return }
            commands.importDraft(string, context: context)
        case .sourceVariable: saveSource(then: .sourceVariable)
        case .scanQR:
            if let context = commandContext() { commands.scanDraft(context: context) }
        case .shareQR: shareSourceQRCode()
        case .help:
            if let context = commandContext() { commands.showRuleHelp(context: context) }
        case .variableHelp:
            presentInfoSheet(
                title: L10n.SourceEdit.variableHelpAction,
                message: fieldText("variableComment").nilIfEmpty ?? L10n.SourceEdit.variableHelpMessage)
        case .review: editReviewRule()
        }
    }

    private func editReviewRule() {
        guard let context = commandContext() else { return }
        commands.editReview(text: draft.reviewText, context: context) { [weak self] (text: String) in
            self?.draft.reviewText = text
            self?.markDraftChanged()
        }
    }

    private func shareSourceQRCode() {
        do {
            let data = try buildSourcePayloadData()
            present(BookSourceEditorSharing.controller(payload: data, anchor: moreButton), animated: true)
        } catch {
            presentError(error)
        }
    }

    private func presentInfoSheet(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.Common.ok, style: .default))
        present(alert, animated: true)
    }
}
