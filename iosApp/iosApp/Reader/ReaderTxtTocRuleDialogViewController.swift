import UIKit
import shared

/// TxtTocRuleDialog / dialog_toc_regex.xml at Legado 5f5d314.
/// The coordinator owns loading, persistence and dismissal after a Kotlin terminal result.
@MainActor
final class ReaderTxtTocRuleDialogViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    var onManage: (() -> Void)? {
        didSet { refreshIfLoaded() }
    }

    /// When supplied, cancellation is a request only; the coordinator must dismiss later.
    /// Without a callback, an idle dialog dismisses itself, but a busy dialog never does.
    var onCancel: (() -> Void)? {
        didSet { refreshIfLoaded() }
    }

    /// Actual dismissal notification, distinct from a cancellation request.
    var onDismiss: (() -> Void)?

    private let bodyView = ReaderTxtTocRuleDialogBodyView(frame: .zero)
    private let onApply: (Int64) -> Void
    private var currentRegex: String
    private var rules: [TxtTocRule]
    private var selectedRuleID: Int64?
    private var isBusy = false
    private var busyMessage: String?
    private var errorMessage: String?
    private var applyPending = false
    private var cancelPending = false
    private var managePending = false
    private var isVisible = false
    private var isClosing = false
    private var didNotifyDismissal = false
    private var didRevealInitialSelection = false

    init(currentRegex: String, rules: [TxtTocRule], onApply: @escaping (Int64) -> Void) {
        self.currentRegex = currentRegex
        self.rules = rules
        self.onApply = onApply
        // Kotlin String equality is code-unit exact, unlike Swift's canonical equivalence.
        selectedRuleID = rules.first { $0.rule.utf16.elementsEqual(currentRegex.utf16) }?.id
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
        isModalInPresentation = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    /// Keep an existing ID across management refreshes, even for duplicate names.
    /// A changed current regex or a removed selection is resolved by exact regex again.
    func update(currentRegex: String, rules: [TxtTocRule]) {
        guard !isClosing else { return }
        let sameRegex = self.currentRegex.utf16.elementsEqual(currentRegex.utf16)
        let selectionExists = selectedRuleID.map { id in rules.contains { $0.id == id } } ?? false
        self.currentRegex = currentRegex
        self.rules = rules
        if !sameRegex || !selectionExists {
            selectedRuleID = rules.first { $0.rule.utf16.elementsEqual(currentRegex.utf16) }?.id
        }
        errorMessage = nil
        guard isViewLoaded else { return }
        bodyView.tableView.reloadData()
        refreshIfLoaded()
    }

    /// false is the host's terminal-result acknowledgement and releases a pending request.
    func setBusy(_ busy: Bool, message: String? = nil) {
        guard !isClosing else { return }
        isBusy = busy
        busyMessage = busy ? message : nil
        if busy {
            errorMessage = nil
        } else {
            applyPending = false
            cancelPending = false
        }
        refreshIfLoaded()
    }

    /// An operation failure is terminal, not dismissal; retain the chosen ID for retry.
    func showError(_ message: String) {
        guard !isClosing else { return }
        isBusy = false
        applyPending = false
        cancelPending = false
        busyMessage = nil
        errorMessage =
            message.isEmpty
            ? NSLocalizedString("reader.txt_toc_rule.error", value: "目录规则加载失败", comment: "TXT TOC rule failure")
            : message
        refreshIfLoaded()
        if isViewLoaded { bodyView.revealStatus() }
        if isVisible { UIAccessibility.post(notification: .announcement, argument: errorMessage) }
    }

    override func loadView() { view = bodyView }

    override func viewDidLoad() {
        super.viewDidLoad()
        bodyView.tableView.dataSource = self
        bodyView.tableView.delegate = self
        bodyView.onApply = { [weak self] in self?.applySelection() }
        bodyView.onCancel = { [weak self] in self?.requestCancel() }
        bodyView.onManage = { [weak self] in self?.manageRules() }
        refreshIfLoaded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !isClosing else { return }
        isVisible = true
        refreshIfLoaded()
        becomeFirstResponder()
        bodyView.layoutIfNeeded()
        revealInitialSelectionIfPossible()
        UIAccessibility.post(notification: .screenChanged, argument: bodyView.titleLabel)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        revealInitialSelectionIfPossible()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        if isLeavingPresentation { isClosing = true }
        refreshIfLoaded()
        resignFirstResponder()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Management may cover this dialog; only actual dismissal ends its lifetime.
        if isClosing || presentingViewController == nil { finishDismissal() }
    }

    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        // UIKit may forward dismissal of a management controller through its presenter.
        if presentedViewController != nil, !isLeavingPresentation {
            super.dismiss(animated: flag, completion: completion)
            return
        }
        isClosing = true
        refreshIfLoaded()
        super.dismiss(animated: flag) { [self] in
            finishDismissal()
            completion?()
        }
    }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        guard canRequestCancel else { return nil }
        let command = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancelFromKeyboard))
        command.discoverabilityTitle = L10n.Common.cancel
        command.wantsPriorityOverSystemBehavior = true
        return [command]
    }

    override func accessibilityPerformEscape() -> Bool {
        guard canRequestCancel, canReceiveAction else { return false }
        requestCancel()
        return true
    }

    func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int { rules.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: ReaderTxtTocRuleDialogCell.reuseIdentifier, for: indexPath)
        if let cell = cell as? ReaderTxtTocRuleDialogCell {
            let rule = rules[indexPath.row]
            cell.configure(rule: rule, selected: rule.id == selectedRuleID, enabled: controlsEnabled)
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        guard canReceiveAction, controlsEnabled, rules.indices.contains(indexPath.row) else { return }
        // enable controls automatic recognition only, never explicit book selection.
        selectedRuleID = rules[indexPath.row].id
        refreshIfLoaded()
    }

    private var operationPending: Bool { isBusy || applyPending || cancelPending }
    private var controlsEnabled: Bool { isVisible && !isClosing && !operationPending && !managePending }
    private var canRequestCancel: Bool {
        isVisible && !isClosing && !cancelPending && !managePending && (onCancel != nil || !operationPending)
    }

    private var isLeavingPresentation: Bool {
        var controller: UIViewController? = self
        while let current = controller {
            if current.isBeingDismissed || current.isMovingFromParent { return true }
            controller = current.parent ?? current.presentingViewController
        }
        return false
    }

    private var canReceiveAction: Bool {
        guard isVisible, !isClosing, !isBeingPresented, !isLeavingPresentation,
            presentedViewController == nil, let window = viewIfLoaded?.window,
            !window.isHidden, window.isKeyWindow,
            window.windowScene?.activationState == .foregroundActive,
            UIApplication.shared.applicationState == .active,
            presentingViewController?.viewIfLoaded?.window === window
        else { return false }
        return true
    }

    private func refreshIfLoaded() {
        guard isViewLoaded else { return }
        let hasSelection = selectedRuleID.map { id in rules.contains { $0.id == id } } ?? false
        bodyView.setState(
            enabled: controlsEnabled, canCancel: canRequestCancel,
            canApply: controlsEnabled && hasSelection, canManage: controlsEnabled && onManage != nil,
            busy: operationPending, message: errorMessage ?? busyMessage, isEmpty: rules.isEmpty)
        for case let cell as ReaderTxtTocRuleDialogCell in bodyView.tableView.visibleCells {
            cell.updateSelection(selected: cell.ruleID == selectedRuleID, enabled: controlsEnabled)
        }
    }

    private func applySelection() {
        guard canReceiveAction, controlsEnabled, let id = selectedRuleID,
            rules.contains(where: { $0.id == id })
        else { return }
        applyPending = true
        errorMessage = nil
        refreshIfLoaded()
        // Do not dismiss, mutate a shared rule, or unlock before the host acknowledges.
        onApply(id)
    }

    private func requestCancel() {
        guard canReceiveAction, canRequestCancel else { return }
        if let onCancel {
            cancelPending = true
            refreshIfLoaded()
            onCancel()
        } else {
            dismiss(animated: !UIAccessibility.isReduceMotionEnabled)
        }
    }

    private func manageRules() {
        guard canReceiveAction, controlsEnabled, let onManage else { return }
        managePending = true
        refreshIfLoaded()
        onManage()
        DispatchQueue.main.async { [weak self] in
            self?.managePending = false
            self?.refreshIfLoaded()
        }
    }

    private func revealInitialSelectionIfPossible() {
        guard isVisible, !didRevealInitialSelection, !operationPending,
            errorMessage == nil, !rules.isEmpty, bodyView.tableView.bounds.height > 0
        else { return }
        didRevealInitialSelection = true
        if let index = rules.firstIndex(where: { $0.id == selectedRuleID }) {
            bodyView.tableView.layoutIfNeeded()
            bodyView.tableView.scrollToRow(at: IndexPath(row: index, section: 0), at: .top, animated: false)
        }
    }

    @objc private func cancelFromKeyboard() { requestCancel() }

    private func finishDismissal() {
        guard !didNotifyDismissal else { return }
        isClosing = true
        didNotifyDismissal = true
        let callback = onDismiss
        onDismiss = nil
        onCancel = nil
        onManage = nil
        callback?()
    }
}
