import UIKit

/// Push onto a navigation controller, or present inside a fresh UINavigationController.
@MainActor
final class MangaFooterSettingsViewController: UITableViewController, UIAdaptivePresentationControllerDelegate {
    private struct Toggle {
        let title: String
        let keyPath: WritableKeyPath<MangaFooterConfiguration, Bool>
        let identifier: String
    }

    private enum Row {
        case toggle(Toggle)
        case alignment(MangaFooterConfiguration.Orientation)
    }

    private struct Section {
        let title: String
        let rows: [Row]
    }

    private static let sections: [Section] = [
        Section(
            title: "章节",
            rows: [
                .toggle(Toggle(title: "隐藏章节文案", keyPath: \.hideChapterLabel, identifier: "hideChapterLabel")),
                .toggle(Toggle(title: "隐藏章节序号", keyPath: \.hideChapter, identifier: "hideChapter")),
                .toggle(Toggle(title: "隐藏章节名称", keyPath: \.hideChapterName, identifier: "hideChapterName")),
            ]),
        Section(
            title: "本章图片",
            rows: [
                .toggle(Toggle(title: "隐藏页数文案", keyPath: \.hidePageNumberLabel, identifier: "hidePageNumberLabel")),
                .toggle(Toggle(title: "隐藏页数", keyPath: \.hidePageNumber, identifier: "hidePageNumber")),
            ]),
        Section(
            title: "总进度",
            rows: [
                .toggle(Toggle(title: "隐藏总进度文案", keyPath: \.hideProgressRatioLabel, identifier: "hideProgressRatioLabel")),
                .toggle(Toggle(title: "隐藏总进度", keyPath: \.hideProgressRatio, identifier: "hideProgressRatio")),
            ]),
        Section(
            title: "页脚",
            rows: [
                .toggle(Toggle(title: "隐藏页脚", keyPath: \.hideFooter, identifier: "hideFooter"))
            ]),
        Section(title: "对齐方式", rows: [.alignment(.left), .alignment(.center)]),
    ]

    private(set) var draft: MangaFooterConfiguration
    private let onSave: @MainActor (MangaFooterConfiguration) async throws -> Void
    private var saveTask: Task<Void, Never>?
    private var saveID: UUID?
    private var appearanceID = UUID()
    private var isVisible = false
    private var isClosing = false
    private var foregroundSuspended = false
    private var lastError: String?
    private weak var sourceWindow: UIWindow?
    private weak var sourceScene: UIWindowScene?
    private weak var sourceRoot: UIViewController?
    private weak var savingNavigation: UINavigationController?
    private var previousPopEnabled: Bool?
    private var previousNavigationModal: Bool?
    private var previousModal: Bool?
    private var previousNavigationBarHidden: Bool?
    private var isSaving: Bool { saveID != nil }

    private lazy var cancelButton = UIBarButtonItem(
        barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
    private lazy var saveButton = UIBarButtonItem(
        title: "保存", style: .done, target: self, action: #selector(save))

    /// The callback owns persistence; honor cancellation and recheck the owner's write gate before committing.
    init(
        configuration: MangaFooterConfiguration,
        onSave: @escaping @MainActor (MangaFooterConfiguration) async throws -> Void
    ) {
        draft = configuration
        self.onSave = onSave
        super.init(style: .insetGrouped)
        title = "漫画页脚"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit {
        saveTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancel))
        escape.discoverabilityTitle = "取消"
        return [escape]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        tableView.backgroundView = nil
        tableView.backgroundColor = UIColor(white: 0.08, alpha: 1)
        tableView.accessibilityIdentifier = "manga.footer.settings"
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 52
        navigationItem.leftBarButtonItem = cancelButton
        navigationItem.rightBarButtonItem = saveButton
        navigationItem.hidesBackButton = true
        cancelButton.accessibilityIdentifier = "manga.footer.settings.cancel"
        saveButton.accessibilityIdentifier = "manga.footer.settings.save"
        for name in [
            UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
            UIApplication.didBecomeActiveNotification,
            UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification,
            UIScene.didDisconnectNotification, UIScene.didActivateNotification,
            UIWindow.didResignKeyNotification, UIWindow.didBecomeHiddenNotification,
            UIWindow.didBecomeKeyNotification, UIWindow.didBecomeVisibleNotification,
            .appLockWillCover, .appLockStatusDidChange,
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(environmentChanged(_:)), name: name, object: nil)
        }
        updateControls()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if previousNavigationBarHidden == nil {
            previousNavigationBarHidden = navigationController?.isNavigationBarHidden
        }
        navigationController?.setNavigationBarHidden(false, animated: animated)
        let presentation = navigationController?.presentationController ?? presentationController
        if presentation?.delegate == nil { presentation?.delegate = self }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isVisible = true
        isClosing = false
        foregroundSuspended = false
        appearanceID = UUID()
        if sourceWindow == nil, let window = view.window {
            sourceWindow = window
            sourceScene = window.windowScene
            sourceRoot = window.rootViewController
        }
        updateControls()
        becomeFirstResponder()
        DispatchQueue.main.async { [weak self] in self?.updateControls() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        invalidateAttempt()
        updateControls()
        if isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true,
            let previousNavigationBarHidden
        {
            navigationController?.setNavigationBarHidden(previousNavigationBarHidden, animated: animated)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateControls()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { Self.sections.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        Self.sections[section].rows.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        Self.sections[section].title
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == Self.sections.count - 1 ? lastError : nil
    }

    override func tableView(_ tableView: UITableView, willDisplayFooterView view: UIView, forSection section: Int) {
        guard section == Self.sections.count - 1, let footer = view as? UITableViewHeaderFooterView else { return }
        footer.textLabel?.textColor = .systemRed
        footer.textLabel?.numberOfLines = 0
        footer.textLabel?.accessibilityIdentifier = "manga.footer.settings.error"
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.backgroundColor = UIColor(white: 0.14, alpha: 1)
        cell.textLabel?.font = .preferredFont(forTextStyle: .body)
        cell.textLabel?.adjustsFontForContentSizeCategory = true
        cell.textLabel?.numberOfLines = 0
        cell.isUserInteractionEnabled = canInteract && !isSaving
        switch Self.sections[indexPath.section].rows[indexPath.row] {
        case .toggle(let option):
            cell.textLabel?.text = option.title
            cell.selectionStyle = .none
            cell.accessibilityIdentifier = "manga.footer.settings.row.\(option.identifier)"
            let control = UISwitch()
            control.isOn = draft[keyPath: option.keyPath]
            control.isEnabled = canInteract && !isSaving
            control.accessibilityLabel = option.title
            control.accessibilityIdentifier = "manga.footer.settings.\(option.identifier)"
            control.addAction(
                UIAction { [weak self, weak control] _ in
                    guard let self, let control else { return }
                    guard self.canInteract, !self.isSaving else {
                        control.setOn(self.draft[keyPath: option.keyPath], animated: false)
                        return
                    }
                    self.draft[keyPath: option.keyPath] = control.isOn
                }, for: .valueChanged)
            cell.accessoryView = control
        case .alignment(let alignment):
            let title = alignment == .left ? "左对齐" : "居中"
            let selected = draft.orientation == alignment
            cell.textLabel?.text = title
            cell.imageView?.image = UIImage(systemName: alignment == .left ? "text.alignleft" : "text.aligncenter")
            cell.imageView?.isAccessibilityElement = false
            cell.accessoryType = selected ? .checkmark : .none
            cell.accessibilityLabel = title
            cell.accessibilityTraits = selected ? [.button, .selected] : .button
            cell.accessibilityIdentifier = "manga.footer.settings.alignment.\(alignment.rawValue)"
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard canInteract, !isSaving,
            case .alignment(let alignment) = Self.sections[indexPath.section].rows[indexPath.row]
        else { return }
        draft.orientation = alignment
        tableView.reloadSections(IndexSet(integer: indexPath.section), with: .none)
    }

    func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
        canInteract && !isSaving
    }

    func presentationControllerWillDismiss(_ presentationController: UIPresentationController) {
        invalidateAttempt()
        isVisible = false
        updateControls()
    }

    override func accessibilityPerformEscape() -> Bool {
        guard canInteract, !isSaving else { return false }
        cancel()
        return true
    }

    private var canInteract: Bool {
        guard isVisible, !isClosing, !foregroundSuspended,
            UIApplication.shared.applicationState == .active,
            let window = viewIfLoaded?.window, window === sourceWindow,
            window.windowScene === sourceScene, window.rootViewController === sourceRoot,
            window.isKeyWindow, !window.isHidden, window.alpha > 0.01,
            sourceScene?.activationState == .foregroundActive,
            AppLockManager.shared.isUnlocked(in: window)
        else { return false }
        var controller: UIViewController? = self
        while let current = controller {
            guard !current.isBeingPresented, !current.isBeingDismissed,
                !current.isMovingFromParent, !current.isMovingToParent,
                current.transitionCoordinator == nil, current.presentedViewController == nil
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
            controller = current.parent
        }
        var ancestor: UIView? = view
        while let current = ancestor {
            if current.isHidden || current.alpha <= 0.01 || !current.isUserInteractionEnabled { return false }
            ancestor = current.superview
        }
        return true
    }

    private func updateControls() {
        guard isViewLoaded else { return }
        let enabled = canInteract && !isSaving
        cancelButton.isEnabled = enabled
        saveButton.isEnabled = enabled
        saveButton.title = isSaving ? "保存中" : "保存"
        for cell in tableView.visibleCells {
            cell.isUserInteractionEnabled = enabled
            (cell.accessoryView as? UIControl)?.isEnabled = enabled
        }
    }

    @objc private func save() {
        guard canInteract, !isSaving else { return }
        let id = UUID()
        let appearance = appearanceID
        let snapshot = draft
        let callback = onSave
        saveID = id
        lastError = nil
        tableView.reloadSections(IndexSet(integer: Self.sections.count - 1), with: .none)
        setSavingPresentation(true)
        updateControls()
        saveTask = Task { [weak self] in
            guard let self else { return }
            guard self.attemptIsCurrent(id, appearance: appearance) else {
                self.finishSave(id, appearance: appearance, error: CancellationError())
                return
            }
            do {
                try Task.checkCancellation()
                try await callback(snapshot)
                try Task.checkCancellation()
                self.finishSave(id, appearance: appearance, error: nil)
            } catch {
                self.finishSave(id, appearance: appearance, error: error)
            }
        }
    }

    private func attemptIsCurrent(_ id: UUID, appearance: UUID) -> Bool {
        saveID == id && appearanceID == appearance && !Task.isCancelled && canInteract
    }

    private func finishSave(_ id: UUID, appearance: UUID, error: Error?) {
        guard saveID == id else { return }
        let mayDeliver = attemptIsCurrent(id, appearance: appearance)
        saveID = nil
        saveTask = nil
        setSavingPresentation(false)
        if mayDeliver, error == nil {
            close()
            return
        }
        if mayDeliver, let error {
            lastError = error is CancellationError ? "保存已取消，草稿已保留。" : error.userFacingMessage
        } else {
            // A callback may already have committed before noticing cancellation; do not claim it did not write.
            lastError = "保存状态已变化，请确认后重试。"
        }
        tableView.reloadSections(IndexSet(integer: Self.sections.count - 1), with: .none)
        updateControls()
        if canInteract, let lastError { UIAccessibility.post(notification: .announcement, argument: lastError) }
    }

    private func invalidateAttempt() {
        appearanceID = UUID()
        saveTask?.cancel()
        // Keep saveID until the callback returns, so a non-cooperative writer cannot overlap a retry.
    }

    private func setSavingPresentation(_ saving: Bool) {
        if saving {
            previousModal = isModalInPresentation
            isModalInPresentation = true
            savingNavigation = navigationController
            previousPopEnabled = navigationController?.interactivePopGestureRecognizer?.isEnabled
            previousNavigationModal = navigationController?.isModalInPresentation
            navigationController?.interactivePopGestureRecognizer?.isEnabled = false
            navigationController?.isModalInPresentation = true
        } else {
            if let previousModal { isModalInPresentation = previousModal }
            if let previousPopEnabled { savingNavigation?.interactivePopGestureRecognizer?.isEnabled = previousPopEnabled }
            if let previousNavigationModal { savingNavigation?.isModalInPresentation = previousNavigationModal }
            previousModal = nil
            previousPopEnabled = nil
            previousNavigationModal = nil
            savingNavigation = nil
        }
    }

    @objc private func cancel() {
        guard canInteract, !isSaving else { return }
        close()
    }

    private func close() {
        guard canInteract, !isSaving else { return }
        let animated = !UIAccessibility.isReduceMotionEnabled
        if let navigation = navigationController, navigation.viewControllers.first !== self {
            isClosing = true
            navigation.popViewController(animated: animated)
        } else if let navigation = navigationController, navigation.presentingViewController != nil {
            isClosing = true
            navigation.dismiss(animated: animated)
        } else if presentingViewController != nil {
            isClosing = true
            dismiss(animated: animated)
        }
    }

    @objc private func environmentChanged(_ notification: Notification) {
        if let scene = notification.object as? UIScene, scene !== sourceScene { return }
        if let window = notification.object as? UIWindow, window !== sourceWindow { return }
        switch notification.name {
        case UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
            UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification,
            UIScene.didDisconnectNotification, UIWindow.didResignKeyNotification,
            UIWindow.didBecomeHiddenNotification, .appLockWillCover:
            foregroundSuspended = true
            invalidateAttempt()
        default:
            foregroundSuspended = false
            if isSaving, !canInteract { invalidateAttempt() }
        }
        updateControls()
        DispatchQueue.main.async { [weak self] in self?.updateControls() }
    }
}
