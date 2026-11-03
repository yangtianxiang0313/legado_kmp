import UIKit
import shared

@MainActor
final class RssArticleFavoriteEditorViewController: UITableViewController, UITextFieldDelegate,
    UIAdaptivePresentationControllerDelegate, NavigationBackActionHandling
{
    var onSave: ((String, String) async throws -> Void)? {
        didSet {
            if isViewLoaded { updateControls() }
        }
    }

    var onDelete: (() async throws -> Void)? {
        didSet {
            guard isViewLoaded else { return }
            tableView.reloadData()
            updateControls()
        }
    }

    var groups: [String] {
        didSet {
            if isViewLoaded { updateGroupMenu() }
        }
    }

    private let titleField = UITextField()
    private let groupField = UITextField()
    private let titleCell = UITableViewCell(style: .default, reuseIdentifier: nil)
    private let groupCell = UITableViewCell(style: .default, reuseIdentifier: nil)
    private let deleteCell = UITableViewCell(style: .default, reuseIdentifier: nil)
    private let groupMenuButton = FavoriteGroupMenuButton(type: .system)
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private var isSubmitting = false
    private var didCompleteOperation = false
    private var isClosing = false
    private var isEditorVisible = false
    private var isPresentationSuspended = false
    private var presentationContext: PresentationContext?
    private var completedContext: PresentationContext?
    private var groupMenuVersion: UUID?
    private var pendingGroupSelection:
        (version: UUID, context: PresentationContext, group: String, menu: UIViewController?)?
    private var groupSelectionTask: Task<Void, Never>?
    private weak var submittingNavigation: UINavigationController?
    private weak var submittingPopGesture: UIGestureRecognizer?
    private var originalPopGestureEnabled: Bool?
    private var originalNavigationModalInPresentation: Bool?
    private var pendingFailure: (context: PresentationContext, title: String, message: String)?
    private var failureAlert: UIAlertController?

    init(star: RssStar, groups: [String] = []) {
        self.groups = groups
        super.init(style: .insetGrouped)
        title = L10n.RSS.editFavoriteTitle
        modalPresentationStyle = .formSheet
        titleField.text = star.title
        groupField.text = star.group
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("Use init(star:groups:)") }

    deinit {
        NotificationCenter.default.removeObserver(self)
        groupSelectionTask?.cancel()
    }

    private static func text(_ key: String, _ fallback: String) -> String {
        NSLocalizedString(key, value: fallback, comment: "")
    }

    override var keyCommands: [UIKeyCommand]? {
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancel))
        escape.discoverabilityTitle = L10n.Common.cancel
        escape.wantsPriorityOverSystemBehavior = true
        return [escape]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.accessibilityIdentifier = "rss.favorite.editor"
        tableView.keyboardDismissMode = .interactive
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 56

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "xmark"), style: .plain, target: self, action: #selector(cancel))
        navigationItem.leftBarButtonItem?.accessibilityLabel = L10n.Common.cancel
        navigationItem.leftBarButtonItem?.accessibilityIdentifier = "rss.favorite.cancel"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "checkmark"), style: .done, target: self, action: #selector(save))
        navigationItem.rightBarButtonItem?.accessibilityLabel = L10n.Common.save
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "rss.favorite.save"

        configureField(
            titleField, cell: titleCell, label: L10n.RSS.editFavoriteTitleField, identifier: "rss.favorite.title")
        configureField(
            groupField, cell: groupCell, label: L10n.RSS.editFavoriteGroupField, identifier: "rss.favorite.group")
        titleField.returnKeyType = .next
        groupField.returnKeyType = .done
        groupField.addTarget(self, action: #selector(groupDidChange), for: .editingChanged)

        groupMenuButton.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        groupMenuButton.setImage(UIImage(systemName: "list.bullet"), for: .normal)
        groupMenuButton.showsMenuAsPrimaryAction = true
        let selectGroup = Self.text("rss.favorite_editor.select_group", "选择分组")
        groupMenuButton.accessibilityLabel = selectGroup
        groupMenuButton.accessibilityIdentifier = "rss.favorite.groups"
        groupMenuButton.addInteraction(UIToolTipInteraction(defaultToolTip: selectGroup))
        groupMenuButton.menuProvider = { [weak self] in self?.makeGroupMenu(forPresentation: true) }
        groupMenuButton.menuDidEnd = { [weak self] identifier in
            self?.finishGroupMenu(identifier)
        }
        updateGroupMenu()

        deleteCell.textLabel?.text = Self.text("rss.favorite_editor.delete", "删除收藏")
        deleteCell.textLabel?.textColor = .systemRed
        deleteCell.textLabel?.font = .preferredFont(forTextStyle: .body)
        deleteCell.textLabel?.adjustsFontForContentSizeCategory = true
        deleteCell.textLabel?.numberOfLines = 0
        deleteCell.imageView?.image = UIImage(systemName: "trash")
        deleteCell.imageView?.tintColor = .systemRed
        deleteCell.accessibilityTraits.insert(.button)
        deleteCell.accessibilityIdentifier = "rss.favorite.delete"
        activityIndicator.accessibilityIdentifier = "rss.favorite.progress"
        observePresentationChanges()
        updateControls()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        presentationController?.delegate = self
        navigationController?.presentationController?.delegate = self
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isEditorVisible = true
        if let context = presentationContext, !matches(context) { retirePresentation() }
        if presentationContext == nil, let window = view.window, let hierarchy = presentationHierarchy(in: window) {
            presentationContext = PresentationContext(window: window, hierarchy: hierarchy)
            isClosing = false
        }
        isPresentationSuspended = !isForegroundAndUnlocked
        updateControls()
        updateGroupMenu()
        resumePresentationFeedback()
    }

    override func viewWillDisappear(_ animated: Bool) {
        isEditorVisible = false
        retirePresentation()
        super.viewWillDisappear(animated)
    }

    override func willMove(toParent parent: UIViewController?) {
        if parent == nil, self.parent != nil { retirePresentation() }
        super.willMove(toParent: parent)
    }

    private func resumePresentationFeedback() {
        guard let context = presentationContext, matches(context), canUsePresentationUI else { return }
        if didCompleteOperation {
            if completedContext === context { closeEditor(in: context) }
        } else {
            showPendingFailure()
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int { onDelete == nil ? 2 : 3 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 1 }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0: return L10n.RSS.editFavoriteTitleField
        case 1: return L10n.RSS.editFavoriteGroupField
        default: return nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch indexPath.section {
        case 0: return titleCell
        case 1: return groupCell
        default: return deleteCell
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 2, canStartOperation, let onDelete else { return }
        performOperation(
            failureTitle: Self.text("rss.favorite_editor.delete_failed", "删除失败"),
            progressLabel: Self.text("rss.favorite_editor.deleting", "正在删除收藏"), operation: onDelete)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        guard canStartOperation else { return false }
        if textField === titleField {
            groupField.becomeFirstResponder()
        } else {
            save()
        }
        return false
    }

    func interceptNavigationBackGesture() -> Bool { !canExitPresentation }

    func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
        canExitPresentation
    }

    override func accessibilityPerformEscape() -> Bool {
        guard canExitPresentation else { return false }
        cancel()
        return true
    }

    private func configureField(_ field: UITextField, cell: UITableViewCell, label: String, identifier: String) {
        cell.selectionStyle = .none
        field.delegate = self
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.clearButtonMode = .whileEditing
        field.accessibilityLabel = label
        field.accessibilityIdentifier = identifier
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            field.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 12),
            field.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -12),
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
        ])
    }

    @objc private func groupDidChange() { updateGroupMenu() }

    private func updateGroupMenu() {
        invalidateGroupMenu()
        groupMenuButton.menu = makeGroupMenu(forPresentation: false)
        groupCell.accessoryView = groupMenuButton.menu == nil ? nil : groupMenuButton
    }

    private func invalidateGroupMenu() {
        groupMenuVersion = nil
        pendingGroupSelection = nil
        groupSelectionTask?.cancel()
        groupSelectionTask = nil
        groupMenuButton.contextMenuInteraction?.dismissMenu()
    }

    private func finishGroupMenu(_ identifier: String) {
        if groupMenuVersion?.uuidString == identifier { groupMenuVersion = nil }
        guard let selection = pendingGroupSelection, selection.version.uuidString == identifier else { return }
        groupSelectionTask?.cancel()
        groupSelectionTask = Task { @MainActor [weak self] in
            // A native menu is itself a presented controller. Validate the editor after it detaches.
            for _ in 0..<75 {
                guard !Task.isCancelled, let self,
                    self.pendingGroupSelection?.version == selection.version,
                    self.presentationContext === selection.context, self.canUsePresentationUI
                else { return }
                if let presented = self.presentedViewController {
                    guard presented === selection.menu else {
                        self.pendingGroupSelection = nil
                        return
                    }
                } else {
                    self.pendingGroupSelection = nil
                    guard self.matches(selection.context), self.canStartOperation else { return }
                    self.groupField.text = selection.group
                    self.updateGroupMenu()
                    return
                }
                do { try await Task.sleep(nanoseconds: 20_000_000) } catch { return }
            }
            if self?.pendingGroupSelection?.version == selection.version { self?.pendingGroupSelection = nil }
        }
    }

    private func makeGroupMenu(forPresentation: Bool) -> UIMenu? {
        if forPresentation, !canStartOperation { return nil }
        var seen = Set<Data>()
        let options = groups.filter { seen.insert(Data($0.utf8)).inserted }
        guard !options.isEmpty else { return nil }
        let selectedGroup = groupField.text.map { Data($0.utf8) }
        let version = UUID()
        let context = presentationContext
        if forPresentation { groupMenuVersion = version }
        return UIMenu(
            identifier: UIMenu.Identifier(version.uuidString),
            children: options.map { group in
                UIAction(
                    title: group.isEmpty ? Self.text("rss.favorite_editor.ungrouped", "未分组") : group,
                    state: selectedGroup == Data(group.utf8) ? .on : .off
                ) {
                    [weak self] _ in
                    guard let self, self.groupMenuVersion == version else { return }
                    // Consume before native dismissal; only this menu's end callback can deliver the choice.
                    self.groupMenuVersion = nil
                    guard let context, self.presentationContext === context, !context.isRetired,
                        self.canUsePresentationUI, !self.isSubmitting, !self.didCompleteOperation, !self.isClosing
                    else { return }
                    self.pendingGroupSelection = (version, context, group, self.presentedViewController)
                    self.groupMenuButton.contextMenuInteraction?.dismissMenu()
                }
            })
    }

    private var canStartOperation: Bool {
        guard let context = presentationContext else { return false }
        return !isSubmitting && !didCompleteOperation && !isClosing && canUsePresentationUI
            && presentedViewController == nil && matches(context)
    }

    private var canExitPresentation: Bool {
        guard let context = presentationContext, !context.isRetired else { return false }
        // Completion blocks resubmission, but a replacement presentation must still allow explicit exit.
        return !isSubmitting && !isClosing && (!didCompleteOperation || completedContext !== context)
    }

    @objc private func cancel() {
        guard canExitPresentation else { return }
        closeEditor()
    }

    @objc private func save() {
        guard canStartOperation, let onSave else { return }
        view.endEditing(true)
        let title = titleField.text ?? ""
        let group = groupField.text ?? ""
        performOperation(
            failureTitle: Self.text("rss.favorite_editor.save_failed", "保存失败"),
            progressLabel: Self.text("rss.favorite_editor.saving", "正在保存收藏")
        ) {
            try await onSave(title, group)
        }
    }

    private func performOperation(
        failureTitle: String, progressLabel: String, operation: @escaping () async throws -> Void
    ) {
        guard canStartOperation, let context = presentationContext else { return }
        view.endEditing(true)
        invalidateGroupMenu()
        pendingFailure = nil
        activityIndicator.accessibilityLabel = progressLabel
        setSubmitting(true)
        // Accepted writes finish independently of presentation; never report success for a missing callback.
        Task { @MainActor [weak self] in
            do {
                try await operation()
                guard let self else { return }
                self.didCompleteOperation = true
                self.completedContext = context
                self.setSubmitting(false)
                self.closeEditor(in: context)
            } catch {
                guard let self else { return }
                self.setSubmitting(false)
                guard self.matches(context) else { return }
                self.pendingFailure = (context, failureTitle, error.userFacingMessage)
                self.showPendingFailure()
            }
        }
    }

    private func setSubmitting(_ submitting: Bool) {
        isSubmitting = submitting
        isModalInPresentation = submitting
        if submitting {
            submittingNavigation = navigationController
            originalNavigationModalInPresentation = submittingNavigation?.isModalInPresentation
            submittingNavigation?.isModalInPresentation = true
            if let gesture = submittingNavigation?.interactivePopGestureRecognizer {
                submittingPopGesture = gesture
                originalPopGestureEnabled = gesture.isEnabled
                gesture.isEnabled = false
            }
        } else {
            restoreSubmissionNavigation()
        }
        navigationItem.titleView = submitting ? activityIndicator : nil
        if submitting { activityIndicator.startAnimating() } else { activityIndicator.stopAnimating() }
        updateControls()
    }

    private func updateControls() {
        let enabled = !isSubmitting && !didCompleteOperation && !isClosing
        navigationItem.leftBarButtonItem?.isEnabled = canExitPresentation
        navigationItem.rightBarButtonItem?.isEnabled = enabled && onSave != nil
        titleField.isEnabled = enabled
        groupField.isEnabled = enabled
        groupMenuButton.isEnabled = enabled
        tableView.isUserInteractionEnabled = enabled
        deleteCell.isUserInteractionEnabled = enabled && onDelete != nil
        deleteCell.contentView.alpha = enabled ? 1 : 0.5
    }

    private func restoreSubmissionNavigation() {
        if let original = originalPopGestureEnabled { submittingPopGesture?.isEnabled = original }
        if let original = originalNavigationModalInPresentation {
            submittingNavigation?.isModalInPresentation = original
        }
        submittingPopGesture = nil
        submittingNavigation = nil
        originalPopGestureEnabled = nil
        originalNavigationModalInPresentation = nil
    }

    private func closeEditor(in expectedContext: PresentationContext? = nil) {
        guard let context = expectedContext ?? presentationContext, matches(context), canUsePresentationUI,
            !isSubmitting, !isClosing, presentedViewController == nil
        else { return }
        if let navigation = navigationController, navigation.topViewController !== self { return }
        isClosing = true
        invalidateGroupMenu()
        updateControls()
        view.endEditing(true)
        if let navigation = navigationController, navigation.viewControllers.first !== self {
            navigation.popViewController(animated: true)
        } else {
            dismiss(animated: true)
        }
    }

    private func showPendingFailure() {
        guard let failure = pendingFailure else { return }
        guard matches(failure.context) else {
            pendingFailure = nil
            dismissFailureAlert()
            return
        }
        guard canUsePresentationUI, !isClosing, presentedViewController == nil, failureAlert == nil
        else { return }
        invalidateGroupMenu()
        let alert = UIAlertController(title: failure.title, message: failure.message, preferredStyle: .alert)
        alert.view.accessibilityIdentifier = "rss.favorite.error"
        alert.addAction(
            UIAlertAction(title: L10n.Common.ok, style: .default) { [weak self, weak alert] _ in
                guard let self, let alert, self.failureAlert === alert else { return }
                if self.pendingFailure?.context === failure.context { self.pendingFailure = nil }
                self.dismissFailureAlert(animated: true)
            })
        failureAlert = alert
        present(alert, animated: true) { [weak self, weak alert] in
            guard let self, let alert, self.failureAlert === alert else { return }
            if !self.matches(failure.context) || !self.canUsePresentationUI
                || self.pendingFailure?.context !== failure.context
            {
                self.dismissFailureAlert()
            }
        }
    }

    private func dismissFailureAlert(animated: Bool = false) {
        guard let alert = failureAlert else { return }
        // The present completion will retry if suspension happened during presentation.
        guard !alert.isBeingPresented, !alert.isBeingDismissed else { return }
        guard alert.presentingViewController?.presentedViewController === alert else {
            if alert.viewIfLoaded?.window == nil { failureAlert = nil }
            return
        }
        let context = presentationContext
        alert.dismiss(animated: animated) { [weak self, weak alert] in
            guard let self, let alert, self.failureAlert === alert else { return }
            self.failureAlert = nil
            guard let context, self.matches(context) else { return }
            self.resumePresentationFeedback()
        }
    }

    private var isForegroundAndUnlocked: Bool {
        guard let window = viewIfLoaded?.window else { return false }
        return window.isKeyWindow && !window.isHidden && window.isUserInteractionEnabled
            && window.windowScene?.activationState == .foregroundActive
            && AppLockManager.shared.isUnlocked(in: window)
    }

    private var canUsePresentationUI: Bool {
        isEditorVisible && !isPresentationSuspended && isForegroundAndUnlocked
            && !isBeingDismissed && !isMovingFromParent && navigationController?.isBeingDismissed != true
    }

    // Include the presenting owner's containment and navigation stacks, not only the editor's window.
    private func presentationHierarchy(in window: UIWindow) -> [UIViewController]? {
        var hierarchy = [UIViewController]()
        var controller: UIViewController? = self
        while let current = controller {
            guard !current.isBeingDismissed, !current.isMovingFromParent,
                !hierarchy.contains(where: { $0 === current })
            else { return nil }
            let child = hierarchy.last
            if let navigation = current as? UINavigationController, child?.parent === navigation,
                navigation.topViewController !== child
            {
                return nil
            }
            if let tab = current as? UITabBarController, child?.parent === tab, tab.selectedViewController !== child {
                return nil
            }
            if current !== self, let presented = current.presentedViewController, presented !== failureAlert,
                !hierarchy.contains(where: { $0 === presented })
            {
                return nil
            }
            hierarchy.append(current)
            if let parent = current.parent {
                guard parent.children.contains(where: { $0 === current }) else { return nil }
                controller = parent
            } else if let presenter = current.presentingViewController {
                guard presenter.presentedViewController === current else { return nil }
                controller = presenter
            } else {
                controller = nil
            }
        }
        return hierarchy.last === window.rootViewController ? hierarchy : nil
    }

    private func matches(_ context: PresentationContext) -> Bool {
        guard presentationContext === context, !context.isRetired else { return false }
        guard let window = context.window, let scene = context.scene, let root = context.root,
            viewIfLoaded?.window === window, window.windowScene === scene, window.rootViewController === root,
            let hierarchy = presentationHierarchy(in: window),
            hierarchy.map(ObjectIdentifier.init) == context.hierarchy,
            PresentationContext.navigationStacks(in: hierarchy) == context.navigationStacks,
            PresentationContext.tabSelections(in: hierarchy) == context.tabSelections
        else {
            context.isRetired = true
            invalidateGroupMenu()
            return false
        }
        return true
    }

    private func retirePresentation() {
        presentationContext?.isRetired = true
        presentationContext = nil
        pendingFailure = nil
        invalidateGroupMenu()
        dismissFailureAlert()
        restoreSubmissionNavigation()
    }

    private func observePresentationChanges() {
        let center = NotificationCenter.default
        for name in [UIScene.willDeactivateNotification, UIScene.didDisconnectNotification] {
            center.addObserver(self, selector: #selector(sceneUnavailable(_:)), name: name, object: nil)
        }
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
            center.addObserver(self, selector: #selector(suspendPresentationUI), name: name, object: nil)
        }
        center.addObserver(self, selector: #selector(lockWillCover(_:)), name: .appLockWillCover, object: nil)
        center.addObserver(
            self, selector: #selector(windowResignedKey(_:)), name: UIWindow.didResignKeyNotification, object: nil)
        for name in [
            UIScene.didActivateNotification, UIApplication.didBecomeActiveNotification,
            UIWindow.didBecomeKeyNotification, .appLockStatusDidChange,
        ] {
            center.addObserver(self, selector: #selector(presentationMayResume(_:)), name: name, object: nil)
        }
    }

    @objc private func sceneUnavailable(_ notification: Notification) {
        guard let scene = notification.object as? UIScene, scene === presentationContext?.scene else { return }
        if notification.name == UIScene.didDisconnectNotification {
            retirePresentation()
        } else {
            suspendPresentationUI()
        }
    }

    @objc private func lockWillCover(_ notification: Notification) {
        guard let window = notification.object as? UIWindow, window === presentationContext?.window else { return }
        suspendPresentationUI()
    }

    @objc private func windowResignedKey(_ notification: Notification) {
        guard let window = notification.object as? UIWindow, window === presentationContext?.window else { return }
        suspendPresentationUI()
    }

    @objc private func suspendPresentationUI() {
        isPresentationSuspended = true
        invalidateGroupMenu()
        dismissFailureAlert()
    }

    @objc private func presentationMayResume(_ notification: Notification) {
        guard let context = presentationContext else { return }
        if let scene = notification.object as? UIScene, scene !== context.scene { return }
        if let window = notification.object as? UIWindow, window !== context.window { return }
        // Recheck after the key-window/lock transition and any synchronous root replacement have finished.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.matches(context), self.isForegroundAndUnlocked else { return }
            self.isPresentationSuspended = false
            self.resumePresentationFeedback()
        }
    }

    @MainActor
    private final class PresentationContext {
        weak var window: UIWindow?
        weak var scene: UIWindowScene?
        weak var root: UIViewController?
        let hierarchy: [ObjectIdentifier]
        let navigationStacks: [[ObjectIdentifier]]
        let tabSelections: [ObjectIdentifier?]
        var isRetired = false

        init(window: UIWindow, hierarchy: [UIViewController]) {
            self.window = window
            scene = window.windowScene
            root = window.rootViewController
            self.hierarchy = hierarchy.map(ObjectIdentifier.init)
            navigationStacks = Self.navigationStacks(in: hierarchy)
            tabSelections = Self.tabSelections(in: hierarchy)
        }

        static func navigationStacks(in hierarchy: [UIViewController]) -> [[ObjectIdentifier]] {
            hierarchy.compactMap { ($0 as? UINavigationController)?.viewControllers.map(ObjectIdentifier.init) }
        }

        static func tabSelections(in hierarchy: [UIViewController]) -> [ObjectIdentifier?] {
            hierarchy.compactMap { $0 as? UITabBarController }.map {
                $0.selectedViewController.map(ObjectIdentifier.init)
            }
        }
    }

    @MainActor
    private final class FavoriteGroupMenuButton: UIButton {
        var menuProvider: (() -> UIMenu?)?
        var menuDidEnd: ((String) -> Void)?

        override func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint
        ) -> UIContextMenuConfiguration? {
            guard let menu = menuProvider?() else { return nil }
            return UIContextMenuConfiguration(identifier: menu.identifier.rawValue as NSString, previewProvider: nil) {
                _ in menu
            }
        }

        override func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction, willEndFor configuration: UIContextMenuConfiguration,
            animator: (any UIContextMenuInteractionAnimating)?
        ) {
            super.contextMenuInteraction(interaction, willEndFor: configuration, animator: animator)
            guard let identifier = configuration.identifier as? String else { return }
            // UIKit may deliver the selected action during dismissal; retire unconsumed menus afterwards.
            let finish: () -> Void = { [weak self] in self?.menuDidEnd?(identifier) }
            if let animator { animator.addCompletion { finish() } } else { finish() }
        }
    }
}
