import UIKit

/// ContentEditDialog at Android 5f5d31404; persistence stays with the identity-bound caller.
final class ReaderContentEditViewController: UIViewController, UITextViewDelegate,
    UIAdaptivePresentationControllerDelegate
{
    private enum Operation { case save, reset }

    var canEdit: (() -> Bool)?

    private var chapterTitleText: String
    private var rawChapterTitle: String
    private let initialContent: String
    private var baselineContent: String
    private let initialPosition: Int
    private let onReset: (() async throws -> String)?
    private let onRename: ((String) async throws -> String)?
    private let onSave: (String) async throws -> Void
    private let toolbar: AndroidEditorTitleBar
    private let textView = UITextView()
    private let editorUnderline = UIView()
    private var editorUnderlineHeight: NSLayoutConstraint?
    private let loadingView = ReaderContentEditLoadingView()
    private var operationTask: Task<Void, Never>?
    private var operationID: UUID?
    private var needsInitialPosition = true
    private var initialViewportSize: CGSize?
    private var isPositioningInitialContent = false
    private var isVisible = false
    private var isClosing = false
    private var titleDialogID: UUID?
    private var titleResultID: UUID?
    private weak var titleDialog: ReaderChapterTitleDialogViewController?
    private weak var presentationWindow: UIWindow?
    private weak var presentationScene: UIWindowScene?
    private weak var editorPresenter: UIViewController?
    private weak var presentationRoot: UIViewController?
    private var pendingError: (error: Error, operation: Operation)?
    private weak var overflowMenu: ReaderOverflowMenuView?

    init(
        chapterTitle: String, content: String, initialPosition: Int = 0,
        onReset: (() async throws -> String)? = nil,
        rawChapterTitle: String? = nil,
        onRename: ((String) async throws -> String)? = nil,
        onSave: @escaping (String) async throws -> Void
    ) {
        chapterTitleText = chapterTitle
        self.rawChapterTitle = rawChapterTitle ?? chapterTitle
        initialContent = content
        baselineContent = content
        self.initialPosition = initialPosition
        self.onReset = onReset
        self.onRename = onRename
        self.onSave = onSave
        // iOS has no Android system Back affordance for this full-screen editor.
        toolbar = AndroidEditorTitleBar(title: chapterTitle, showsBack: true, showsMore: true)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit { operationTask?.cancel() }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AndroidReplicaTheme.background
        view.accessibilityViewIsModal = true
        view.accessibilityIdentifier = "reader.contentEdit"
        configureToolbar()
        configureTextView()
        configureLayout()
        applyContentFont()
        for name in [UIApplication.didBecomeActiveNotification, UIScene.didActivateNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(resumeInteraction(_:)), name: name, object: nil)
        }
        updateControls()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isVisible = true
        if presentationWindow == nil {
            presentationWindow = view.window
            presentationScene = view.window?.windowScene
            editorPresenter = presentingViewController
            presentationRoot = view.window?.rootViewController
        }
        presentationController?.delegate = self
        updateControls()
        positionInitialContentIfNeeded()
        DispatchQueue.main.async { [weak self] in self?.presentPendingErrorIfPossible() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if isVisible { positionInitialContentIfNeeded() }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard isViewLoaded else { return }
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory
            || previousTraitCollection?.displayScale != traitCollection.displayScale
        {
            applyContentFont()
        }
        updateEditorUnderline()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        overflowMenu?.dismiss()
        // An owned title dialog may cover this editor without ending its draft session.
        if isPresentationLeaving || presentedViewController !== titleDialog || titleDialog == nil {
            invalidateOperation()
            titleDialogID = nil
            titleResultID = nil
            titleDialog = nil
        }
    }

    private func configureToolbar() {
        toolbar.backButton.accessibilityLabel = L10n.Reader.backAction
        toolbar.backButton.accessibilityIdentifier = "reader.contentEdit.back"
        toolbar.backButton.addTarget(self, action: #selector(handleBack), for: .touchUpInside)
        toolbar.saveButton.accessibilityLabel = L10n.Reader.saveContent
        toolbar.saveButton.accessibilityIdentifier = "reader.contentEdit.save"
        toolbar.saveButton.addTarget(self, action: #selector(handleSave), for: .touchUpInside)
        toolbar.moreButton.accessibilityLabel = "更多"
        toolbar.moreButton.accessibilityIdentifier = "reader.contentEdit.more"
        toolbar.moreButton.addTarget(self, action: #selector(showMoreMenu), for: .touchUpInside)
        toolbar.titleButton.accessibilityIdentifier = "reader.contentEdit.title"
        toolbar.titleButton.accessibilityLabel = chapterTitleText
        toolbar.titleButton.accessibilityTraits = onRename == nil ? [.header, .staticText] : [.header, .button]
        toolbar.titleButton.addTarget(self, action: #selector(editChapterTitle), for: .touchUpInside)
    }

    private func configureTextView() {
        textView.adjustsFontForContentSizeCategory = false
        textView.textColor = AndroidReplicaTheme.primaryText
        textView.backgroundColor = AndroidReplicaTheme.background
        textView.tintColor = AndroidReplicaTheme.accent
        textView.textAlignment = .natural
        // Keep vertical padding outside the scrolling viewport so the preceding line cannot bleed through it.
        textView.textContainerInset = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.widthTracksTextView = true
        textView.textContainer.lineBreakMode = .byWordWrapping
        textView.contentInsetAdjustmentBehavior = .never
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.spellCheckingType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.accessibilityLabel = "正文"
        textView.accessibilityIdentifier = "reader.contentEdit.text"
        textView.text = initialContent
        textView.delegate = self
    }

    private func applyContentFont() {
        let font = ReaderAndroidDefaultFont.scaledFont(
            size: 18, textStyle: .body, compatibleWith: traitCollection)
        let padding = AndroidExploreTextMetrics.padding(font: font, scale: traitCollection.displayScale)
        textView.font = font
        textView.textContainerInset = UIEdgeInsets(top: padding.top, left: 12, bottom: padding.bottom, right: 12)
    }

    private func configureLayout() {
        let statusBackground = UIView()
        statusBackground.backgroundColor = AndroidReplicaTheme.toolbarBackground
        statusBackground.isAccessibilityElement = false
        loadingView.tintColor = AndroidReplicaTheme.accent
        loadingView.accessibilityLabel = L10n.Common.loadingTitle
        loadingView.accessibilityIdentifier = "reader.contentEdit.busy"
        editorUnderline.isUserInteractionEnabled = false
        editorUnderline.isAccessibilityElement = false
        let underlineHeight = editorUnderline.heightAnchor.constraint(equalToConstant: 1)
        editorUnderlineHeight = underlineHeight
        for item in [statusBackground, toolbar, textView, editorUnderline, loadingView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        NSLayoutConstraint.activate([
            statusBackground.topAnchor.constraint(equalTo: view.topAnchor),
            statusBackground.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBackground.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusBackground.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),
            toolbar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 12),
            textView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -12),
            editorUnderline.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 4),
            editorUnderline.trailingAnchor.constraint(equalTo: textView.trailingAnchor, constant: -4),
            editorUnderline.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -7),
            underlineHeight,
            loadingView.widthAnchor.constraint(equalToConstant: 60),
            loadingView.heightAnchor.constraint(equalToConstant: 60),
            loadingView.centerXAnchor.constraint(equalTo: textView.centerXAnchor),
            loadingView.centerYAnchor.constraint(equalTo: textView.centerYAnchor),
        ])
    }

    private func positionInitialContentIfNeeded() {
        guard needsInitialPosition, !isPositioningInitialContent,
            textView.bounds.width > 0, textView.bounds.height > 0,
            initialViewportSize != textView.bounds.size
        else { return }
        initialViewportSize = textView.bounds.size
        isPositioningInitialContent = true
        defer { isPositioningInitialContent = false }
        let location = safePosition(initialPosition, in: initialContent)
        textView.selectedRange = NSRange(location: location, length: 0)
        textView.layoutIfNeeded()
        let layout = textView.layoutManager
        layout.ensureLayout(for: textView.textContainer)
        if layout.numberOfGlyphs > 0 {
            let glyph = min(layout.glyphIndexForCharacter(at: location), layout.numberOfGlyphs - 1)
            let lineTop = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
            let maximumOffset = max(0, textView.contentSize.height - textView.bounds.height)
            textView.setContentOffset(
                CGPoint(x: 0, y: min(max(0, lineTop), maximumOffset)), animated: false)
        }
    }

    private func safePosition(_ position: Int, in text: String) -> Int {
        let string = text as NSString
        let offset = min(max(0, position), string.length)
        guard offset < string.length else { return offset }
        return string.rangeOfComposedCharacterSequence(at: offset).location
    }

    private var hasChanges: Bool {
        !(textView.text ?? "").utf16.elementsEqual(baselineContent.utf16)
    }

    private var canPerformCommand: Bool {
        guard let scene = presentationScene else { return false }
        return isVisible && operationID == nil && titleDialogID == nil
            && transitionCoordinator?.isInteractive != true && presentedViewController == nil
            && hasCurrentPresentation(in: scene)
    }

    private var isPresentationLeaving: Bool {
        var current: UIViewController? = self
        while let controller = current {
            if controller.isBeingDismissed || controller.isMovingFromParent { return true }
            current = controller.parent ?? controller.presentingViewController
        }
        return false
    }

    private func hasCurrentPresentation(in scene: UIWindowScene) -> Bool {
        guard Thread.isMainThread, !isClosing, !isBeingPresented, !isBeingDismissed, !isMovingFromParent,
            UIApplication.shared.applicationState == .active, scene.activationState == .foregroundActive,
            let window = presentationWindow, !window.isHidden, window.alpha > 0,
            window.windowScene === scene, let root = presentationRoot, window.rootViewController === root,
            let presenter = editorPresenter, presentingViewController === presenter,
            presenter.presentedViewController === self,
            viewIfLoaded?.window === window || titleDialog?.viewIfLoaded?.window === window
        else { return false }
        var current: UIViewController? = self
        var expectedPresentation: UIViewController?
        var lastController: UIViewController?
        while let controller = current {
            guard !controller.isBeingDismissed, !controller.isBeingPresented,
                !controller.isMovingFromParent, !controller.isMovingToParent
            else { return false }
            if let presented = controller.presentedViewController,
                presented !== expectedPresentation,
                !(controller === self && (presented === titleDialog || presented is UIAlertController))
            {
                return false
            }
            if let navigation = controller.parent as? UINavigationController,
                navigation.topViewController !== controller
            {
                return false
            }
            if let tabs = controller.parent as? UITabBarController,
                tabs.selectedViewController !== controller
            {
                return false
            }
            lastController = controller
            if let parent = controller.parent {
                expectedPresentation = nil
                current = parent
            } else {
                expectedPresentation = controller
                current = controller.presentingViewController
            }
        }
        return lastController === root
    }

    private func canWrite(in scene: UIWindowScene) -> Bool {
        hasCurrentPresentation(in: scene) && (canEdit?() ?? true) && hasCurrentPresentation(in: scene)
    }

    private func contextChangedError() -> NSError {
        NSError(
            domain: "io.legado.kmp.ios", code: -1,
            userInfo: [NSLocalizedDescriptionKey: "当前书籍、章节或页面状态已变化，请重新打开编辑页面。"])
    }

    private func commitInput() {
        textView.unmarkText()
        view.endEditing(true)
    }

    private func updateControls() {
        let busy = operationID != nil || isClosing
        let locked = busy || titleDialogID != nil
        // ContentEditDialog has one rl_loading overlay; its save icon stays in its toolbar slot.
        toolbar.setBusy(false)
        toolbar.backButton.isEnabled = !locked
        toolbar.saveButton.isEnabled = !locked
        toolbar.moreButton.isEnabled = !locked
        toolbar.titleButton.isEnabled = onRename != nil && !locked
        toolbar.titleButton.isUserInteractionEnabled = onRename != nil && !locked
        textView.isEditable = !busy
        textView.isSelectable = !busy
        textView.isUserInteractionEnabled = !locked
        updateEditorUnderline()
        isModalInPresentation = locked || hasChanges
        if operationID != nil { loadingView.startAnimating() } else { loadingView.stopAnimating() }
    }

    private func updateEditorUnderline() {
        let enabled = textView.isEditable && textView.isUserInteractionEnabled
        let focused = enabled && textView.isFirstResponder
        editorUnderlineHeight?.constant = focused ? 2 : 1
        editorUnderline.backgroundColor =
            enabled
            ? (focused ? AndroidReplicaTheme.accent : AndroidReplicaTheme.secondaryText)
            : UIColor { traits in
                UIColor(
                    white: traits.userInterfaceStyle == .dark ? 1 : 0,
                    alpha: traits.userInterfaceStyle == .dark ? 0.30 : 0.26)
            }
    }

    @objc private func showMoreMenu() {
        guard canPerformCommand else { return }
        commitInput()
        guard canPerformCommand else { return }
        overflowMenu?.dismiss()
        var items: [ReaderOverflowMenuView.Item] = []
        if onReset != nil {
            items.append(
                .init(identifier: "reader.contentEdit.reset", title: "重置") { [weak self] in
                    self?.resetContent()
                })
        }
        items.append(
            .init(identifier: "reader.contentEdit.copy", title: "复制全部") { [weak self] in
                guard let self, self.canPerformCommand else { return }
                self.commitInput()
                guard self.canPerformCommand else { return }
                UIPasteboard.general.string = self.chapterTitleText + "\n" + (self.textView.text ?? "")
            })
        let menu = ReaderOverflowMenuView(
            items: items, anchorView: toolbar.moreButton, interfaceStyle: traitCollection.userInterfaceStyle)
        menu.onDismiss = { [weak self, weak menu] in
            guard self?.overflowMenu === menu else { return }
            self?.overflowMenu = nil
        }
        overflowMenu = menu
        menu.present(in: view)
    }

    @objc private func editChapterTitle() {
        guard canPerformCommand, let rename = onRename, let scene = presentationScene,
            canWrite(in: scene)
        else { return }
        commitInput()
        guard canPerformCommand, canWrite(in: scene) else { return }
        needsInitialPosition = false
        overflowMenu?.dismiss()
        let id = UUID()
        let dialog = ReaderChapterTitleDialogViewController(
            text: rawChapterTitle,
            onSave: { [weak self] raw in
                guard let self else { throw CancellationError() }
                guard self.canRename(id, in: scene) else { throw self.contextChangedError() }
                try Task.checkCancellation()
                let display = try await rename(raw)
                try Task.checkCancellation()
                guard self.canRename(id, in: scene) else { throw self.contextChangedError() }
                return display
            })
        dialog.canSave = { [weak self, weak dialog] in
            guard let self, let dialog else { return false }
            return self.canRename(id, in: scene) || self.canReceiveTitle(id, dialog: dialog, in: scene)
        }
        dialog.onSaved = { [weak self, weak dialog] raw, display in
            guard let self, let dialog, self.canReceiveTitle(id, dialog: dialog, in: scene)
            else { return }
            self.titleResultID = nil
            self.rawChapterTitle = raw
            self.chapterTitleText = display
            self.toolbar.titleButton.setAttributedTitle(
                NSAttributedString(string: display, attributes: [.kern: CGFloat(0)]), for: .normal)
            self.toolbar.titleButton.accessibilityLabel = display
        }
        dialog.onClose = { [weak self, weak dialog] in
            guard let self, let dialog, self.titleDialogID == id, self.titleDialog === dialog,
                self.isDetached(dialog)
            else { return }
            self.titleDialogID = nil
            self.titleResultID = nil
            self.titleDialog = nil
            self.updateControls()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.canPerformCommand else { return }
                UIAccessibility.post(notification: .layoutChanged, argument: self.toolbar.titleButton)
            }
        }
        titleDialogID = id
        titleResultID = id
        titleDialog = dialog
        updateControls()
        present(dialog, animated: true)
    }

    private func canRename(_ id: UUID, in scene: UIWindowScene) -> Bool {
        guard titleDialogID == id, operationID == nil, let dialog = titleDialog, canWrite(in: scene),
            titleDialogID == id, titleDialog === dialog
        else { return false }
        return presentedViewController === dialog && dialog.presentingViewController === self
            && !dialog.isBeingDismissed && !dialog.isBeingPresented
            && dialog.viewIfLoaded?.window === presentationWindow
    }

    private func canReceiveTitle(_ id: UUID, dialog: UIViewController, in scene: UIWindowScene) -> Bool {
        guard titleResultID == id, operationID == nil,
            titleDialogID == nil || titleDialogID == id,
            isDetached(dialog), presentedViewController == nil, canWrite(in: scene)
        else { return false }
        return titleResultID == id && isDetached(dialog) && presentedViewController == nil
    }

    private func isDetached(_ controller: UIViewController) -> Bool {
        controller.presentingViewController == nil && controller.presentedViewController == nil
            && controller.parent == nil && controller.viewIfLoaded?.window == nil
            && controller.viewIfLoaded?.superview == nil
    }

    @objc private func handleSave() {
        guard canPerformCommand else { return }
        commitInput()
        guard canPerformCommand else { return }
        guard hasChanges else {
            closeEditor()
            return
        }
        let content = textView.text ?? ""
        let save = onSave
        perform(.save) {
            try await save(content)
            return nil
        }
    }

    private func resetContent() {
        guard canPerformCommand, let reset = onReset else { return }
        commitInput()
        perform(.reset) { try await reset() }
    }

    private func perform(_ operation: Operation, action: @escaping () async throws -> String?) {
        guard canPerformCommand, let scene = presentationScene else { return }
        guard canWrite(in: scene), canPerformCommand else {
            pendingError = (contextChangedError(), operation)
            presentPendingErrorIfPossible()
            return
        }
        overflowMenu?.dismiss()
        pendingError = nil
        let id = UUID()
        operationID = id
        updateControls()
        operationTask = Task { @MainActor [weak self] in
            do {
                try Task.checkCancellation()
                guard self?.operationID == id, self?.canWrite(in: scene) == true, self?.operationID == id else {
                    if let self { throw self.contextChangedError() }
                    throw CancellationError()
                }
                let replacement = try await action()
                try Task.checkCancellation()
                guard let self, self.operationID == id else { return }
                guard self.canWrite(in: scene), self.operationID == id else {
                    throw self.contextChangedError()
                }
                self.finishOperation(id)
                switch operation {
                case .save:
                    self.closeEditor()
                case .reset:
                    if let replacement,
                        let range = self.textView.textRange(
                            from: self.textView.beginningOfDocument, to: self.textView.endOfDocument)
                    {
                        self.textView.replace(range, withText: replacement)
                        self.baselineContent = replacement
                    }
                    self.updateControls()
                }
            } catch {
                guard let self, self.operationID == id else { return }
                self.finishOperation(id)
                self.pendingError = (error, operation)
                self.presentPendingErrorIfPossible()
            }
        }
    }

    private func finishOperation(_ id: UUID) {
        guard operationID == id else { return }
        operationID = nil
        operationTask = nil
        updateControls()
    }

    private func invalidateOperation() {
        operationID = nil
        operationTask?.cancel()
        operationTask = nil
    }

    @objc private func handleBack() {
        guard canPerformCommand else { return }
        if let overflowMenu {
            overflowMenu.dismiss()
            return
        }
        commitInput()
        guard canPerformCommand else { return }
        guard hasChanges else {
            closeEditor()
            return
        }
        handleSave()
    }

    @objc private func handleEscape() {
        guard canPerformCommand else { return }
        // Android's IME consumes Back before ContentEditDialog.onCancel autosaves the draft.
        if textView.isFirstResponder,
            view.keyboardLayoutGuide.layoutFrame.minY < view.safeAreaLayoutGuide.layoutFrame.maxY
        {
            commitInput()
            return
        }
        handleBack()
    }

    private func closeEditor() {
        guard canPerformCommand else { return }
        isClosing = true
        invalidateOperation()
        commitInput()
        updateControls()
        dismiss(animated: true)
    }

    @objc private func resumeInteraction(_ notification: Notification) {
        if let scene = notification.object as? UIScene, scene !== presentationScene { return }
        updateControls()
        DispatchQueue.main.async { [weak self] in self?.presentPendingErrorIfPossible() }
    }

    private func presentPendingErrorIfPossible() {
        guard canPerformCommand, let pending = pendingError else { return }
        pendingError = nil
        presentError(pending.error, operation: pending.operation)
    }

    private func presentError(_ error: Error, operation: Operation) {
        guard canPerformCommand else { return }
        let alert = UIAlertController(
            title: operation == .save ? "保存失败" : "重置失败",
            message: error.localizedDescription, preferredStyle: .alert)
        alert.view.accessibilityIdentifier = "reader.contentEdit.error"
        alert.addAction(
            dialogAction(in: alert, title: L10n.Common.retry, identifier: "retry") {
                switch operation {
                case .save: $0.handleSave()
                case .reset: $0.resetContent()
                }
            })
        let cancel = UIAlertAction(title: L10n.Common.cancel, style: .cancel)
        cancel.accessibilityIdentifier = "reader.contentEdit.error.cancel"
        alert.addAction(cancel)
        present(alert, animated: true)
    }

    private func dialogAction(
        in alert: UIAlertController, title: String, identifier: String,
        action: @escaping (ReaderContentEditViewController) -> Void
    ) -> UIAlertAction {
        let result = UIAlertAction(title: title, style: .default) { [weak self, weak alert] _ in
            alert?.dismiss(animated: true) { [weak self] in
                guard let self, self.canPerformCommand else { return }
                action(self)
            }
        }
        result.accessibilityIdentifier = "reader.contentEdit.\(identifier)"
        return result
    }

    func textView(_: UITextView, shouldChangeTextIn _: NSRange, replacementText _: String) -> Bool {
        isVisible && operationID == nil && titleDialogID == nil && !isClosing
    }

    func textViewDidChange(_: UITextView) {
        needsInitialPosition = false
        isModalInPresentation = operationID != nil || titleDialogID != nil || isClosing || hasChanges
    }

    func textViewDidBeginEditing(_: UITextView) {
        needsInitialPosition = false
        updateEditorUnderline()
    }

    func textViewDidEndEditing(_: UITextView) {
        updateEditorUnderline()
    }

    func scrollViewWillBeginDragging(_: UIScrollView) {
        needsInitialPosition = false
    }

    func presentationControllerShouldDismiss(_: UIPresentationController) -> Bool {
        guard canPerformCommand else { return false }
        commitInput()
        updateControls()
        return canPerformCommand && !hasChanges
    }

    func presentationControllerDidAttemptToDismiss(_: UIPresentationController) {
        if let transitionCoordinator, transitionCoordinator.isInteractive {
            let scheduled = transitionCoordinator.animate(alongsideTransition: nil) { [weak self] _ in
                DispatchQueue.main.async { [weak self] in self?.handleBack() }
            }
            if scheduled { return }
        }
        DispatchQueue.main.async { [weak self] in self?.handleBack() }
    }

    override func accessibilityPerformEscape() -> Bool {
        handleBack()
        return true
    }

    override var keyCommands: [UIKeyCommand]? {
        let back = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(handleEscape))
        back.discoverabilityTitle = L10n.Reader.backAction
        back.wantsPriorityOverSystemBehavior = true
        let save = UIKeyCommand(input: "s", modifierFlags: .command, action: #selector(handleSave))
        save.discoverabilityTitle = L10n.Reader.saveContent
        save.wantsPriorityOverSystemBehavior = true
        return [back, save]
    }
}

/// RotateLoading: 60dp bounds, 6dp paired arcs, 2dp shadow and a 10-degree starting angle.
private final class ReaderContentEditLoadingView: UIView {
    private let strokes = (0..<4).map { _ in CAShapeLayer() }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        for stroke in strokes {
            stroke.fillColor = nil
            stroke.lineWidth = 6
            stroke.lineCap = .round
            layer.addSublayer(stroke)
        }
        tintColorDidChange()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let path = UIBezierPath(
            arcCenter: CGPoint(x: bounds.midX, y: bounds.midY),
            radius: max(0, min(bounds.width, bounds.height) / 2 - 12),
            startAngle: 0, endAngle: .pi * 2, clockwise: true
        ).cgPath
        for (index, stroke) in strokes.enumerated() {
            let offset: CGFloat = index < 2 ? 2 : 0
            stroke.bounds = CGRect(origin: .zero, size: bounds.size)
            stroke.position = CGPoint(x: bounds.midX + offset, y: bounds.midY + offset)
            stroke.path = path
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        tintColorDidChange()
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        for (index, stroke) in strokes.enumerated() {
            let color = index < 2 ? UIColor.black.withAlphaComponent(26 / 255.0) : (tintColor ?? .clear)
            stroke.strokeColor = color.resolvedColor(with: traitCollection).cgColor
        }
    }

    func startAnimating() {
        guard isHidden else { return }
        isHidden = false
        for (index, stroke) in strokes.enumerated() {
            let angle = CGFloat(10 + (index % 2) * 180) * .pi / 180
            stroke.transform = CATransform3DMakeRotation(angle, 0, 0, 1)
            stroke.strokeEnd = UIAccessibility.isReduceMotionEnabled ? 160 / 360.0 : 10 / 360.0
            guard !UIAccessibility.isReduceMotionEnabled else { continue }
            let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
            rotation.fromValue = angle
            rotation.toValue = angle + .pi * 2
            rotation.duration = 0.6
            rotation.timingFunction = CAMediaTimingFunction(name: .linear)
            rotation.repeatCount = .infinity
            stroke.add(rotation, forKey: "rotation")
            let sweep = CAKeyframeAnimation(keyPath: "strokeEnd")
            sweep.values = [10 / 360.0, 160 / 360.0, 10 / 360.0]
            sweep.keyTimes = [0, NSNumber(value: 2.0 / 3), 1]
            sweep.duration = 1.875
            sweep.repeatCount = .infinity
            stroke.add(sweep, forKey: "sweep")
        }
    }

    func stopAnimating() {
        isHidden = true
        for stroke in strokes { stroke.removeAllAnimations() }
    }
}
