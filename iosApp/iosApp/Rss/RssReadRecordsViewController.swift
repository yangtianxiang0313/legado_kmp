import shared
import UIKit

/// ReadRecordDialog at Legado 5f5d314: global, read-only title and URL rows.
@MainActor
final class RssReadRecordsViewController: UIViewController, UITableViewDataSource,
    UIAdaptivePresentationControllerDelegate
{
    var onClose: (() -> Void)?
    private enum Operation { case load, count, clear }
    private let screen = RssScreenAdapter()
    private let body = RssReadRecordsDialogBodyView()
    private let ownership = ReaderBookDialogOwnership()
    private lazy var dialogView = SourceChangeDialogView(
        content: body, wrapsContent: false, identifier: "rss.readRecords")
    private lazy var lifecycle = SourceChangeDialogLifecycle(
        controller: self,
        dismiss: { [weak self] animated, completion in
            self?.dismissDialog(animated: animated, completion: completion)
        },
        interactionChanged: { [weak self] in self?.updateInteraction() },
        detached: { [weak self] _ in self?.finish() })
    private var records: [RssReadRecord] = []
    private var hasLoaded = false
    private var runtimeReady = false
    private var isFinished = false
    private var operation: Operation?
    private var retryOperation: Operation = .load
    private var failureMessage: String?
    private var pendingSuccess: String?
    private var needsLoad = true
    private var requestID: UUID?
    private var task: Task<Void, Never>?
    private var confirmationID: UUID?
    private var pendingClear: (id: UUID, keys: Set<Data>)?
    private weak var confirmation: ReaderRestoreProgressDialogViewController?
    private var protectedDataSuspended = false
    private var lockSuspended = false

    init() {
        super.init(nibName: nil, bundle: nil)
        title = L10n.RSS.readRecordsTitle
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
        isModalInPresentation = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit { task?.cancel(); screen.unbind(); NotificationCenter.default.removeObserver(self) }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        guard canInteract else { return nil }
        let command = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(closeDialog))
        command.discoverabilityTitle = L10n.Common.cancel
        command.wantsPriorityOverSystemBehavior = true
        return [command]
    }

    override func loadView() {
        view = dialogView
        dialogView.onWindowChange = { [weak self] in self?.lifecycle.scheduleDetachmentCheck() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        body.tableView.dataSource = self
        body.clearButton.addTarget(self, action: #selector(confirmClear), for: .touchUpInside)
        body.retryButton.addTarget(self, action: #selector(retry), for: .touchUpInside)
        body.closeButton.addTarget(self, action: #selector(closeDialog), for: .touchUpInside)
        dialogView.outsideControl.addTarget(self, action: #selector(closeDialog), for: .touchUpInside)
        screen.onReadRecordsChange = { [weak self] records in
            guard let self, !self.isFinished else { return }
            let previousKeys = self.recordKeys
            self.accept(records)
            if self.confirmationID != nil, previousKeys != self.recordKeys { self.revokeConfirmation() }
            self.render()
        }
        for name in ReaderBookDialogOwnership.environmentNotifications + [
            UIScene.didDisconnectNotification, UIApplication.protectedDataWillBecomeUnavailableNotification,
            UIApplication.protectedDataDidBecomeAvailableNotification, .appLockWillCover, .appLockStatusDidChange,
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(environmentChanged(_:)), name: name, object: nil)
        }
        body.applyFonts(traits: traitCollection)
        render()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        lifecycle.willAppear()
        presentationController?.delegate = self
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        ownership.capture(from: self)
        lifecycle.didAppear()
        resumeAfterTransition()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        lifecycle.willDisappear()
        if isBeingDismissed || presentingViewController?.isBeingDismissed == true { stopRequests() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        lifecycle.scheduleDetachmentCheck()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let maximum = max(0, view.safeAreaLayoutGuide.layoutFrame.height - 16)
        if body.maximumHeight != maximum {
            body.maximumHeight = maximum
            dialogView.setNeedsLayout()
        }
        updateInteraction()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard isViewLoaded else { return }
        body.applyFonts(traits: traitCollection)
        body.tableView.reloadData()
        dialogView.setNeedsLayout()
    }

    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        guard presentedViewController == nil else {
            super.dismiss(animated: flag, completion: completion)
            return
        }
        stopRequests()
        lifecycle.close(.external, animated: flag, completion: completion)
    }

    func presentationControllerDidDismiss(_: UIPresentationController) { lifecycle.externallyDismissed() }

    override func accessibilityPerformEscape() -> Bool {
        guard canInteract else { return false }
        closeDialog()
        return true
    }

    private var ownsSession: Bool {
        guard !isFinished, !protectedDataSuspended, !lockSuspended,
            UIApplication.shared.isProtectedDataAvailable, ownership.isCurrent(allowing: self),
            let window = ownership.window, viewIfLoaded?.window === window,
            window.isUserInteractionEnabled, !window.accessibilityElementsHidden,
            viewIfLoaded?.isHidden == false, (viewIfLoaded?.alpha ?? 0) > 0.01
        else { return false }
        return true
    }

    private var canInteract: Bool { ownsSession && lifecycle.canInteract && transitionCoordinator == nil }
    private var recordKeys: Set<Data> { Set(records.map { Data($0.record.utf8) }) }

    private func resumePresentation() {
        guard canInteract else { updateInteraction(); return }
        becomeFirstResponder()
        if let pending = pendingClear {
            pendingClear = nil
            let accepted = confirmationID == pending.id && recordKeys == pending.keys
            confirmationID = nil
            confirmation = nil
            if accepted { clearRecords(); return }
        }
        if needsLoad, operation == nil { loadRecords() }
        render()
        if let message = pendingSuccess {
            pendingSuccess = nil
            showTransientMessage(message)
        }
    }

    @objc private func environmentChanged(_ notification: Notification) {
        guard ownership.belongs(notification) else { return }
        ownership.receive(notification)
        switch notification.name {
        case UIApplication.protectedDataWillBecomeUnavailableNotification: protectedDataSuspended = true
        case UIApplication.protectedDataDidBecomeAvailableNotification: protectedDataSuspended = false
        case .appLockWillCover: lockSuspended = true
        case .appLockStatusDidChange:
            lockSuspended = !AppLockManager.shared.isUnlocked(in: ownership.window)
        case UIScene.didDisconnectNotification:
            stopRequests()
            lifecycle.close(.external, animated: false)
            return
        default: break
        }
        if ReaderBookDialogOwnership.interruptionNotifications.contains(notification.name)
            || notification.name == .appLockWillCover
            || notification.name == UIApplication.protectedDataWillBecomeUnavailableNotification
        {
            revokeConfirmation()
            if operation != .clear {
                needsLoad = true
                stopRequests()
            }
        }
        updateInteraction()
        resumeAfterTransition()
    }

    private func bootstrap() -> Bool {
        if runtimeReady { return true }
        switch screen.bootstrap() {
        case .success:
            runtimeReady = true
            return true
        case .failure(let error):
            failureMessage = error.message
            retryOperation = .load
            needsLoad = false
            render()
            return false
        }
    }

    private func loadRecords() {
        guard canInteract, operation == nil, bootstrap() else { return }
        let id = begin(.load)
        needsLoad = false
        task = Task { @MainActor [weak self, screen] in
            do {
                let loaded = try await Self.readStableSnapshot(screen)
                try Task.checkCancellation()
                guard let self, self.isCurrent(id) else { return }
                self.accept(loaded)
                self.endRequest()
            } catch {
                guard let self, !Task.isCancelled, self.isCurrent(id) else { return }
                self.fail(error, retry: .load)
            }
        }
    }

    @objc private func confirmClear() {
        guard canInteract, operation == nil, confirmationID == nil, runtimeReady else { return }
        let id = begin(.count)
        task = Task { @MainActor [weak self, screen] in
            do {
                let loaded = try await Self.readStableSnapshot(screen)
                try Task.checkCancellation()
                guard let self, self.isCurrent(id) else { return }
                self.accept(loaded)
                self.endRequest()
                guard self.canInteract, !self.records.isEmpty else { return }
                self.presentConfirmation()
            } catch {
                guard let self, !Task.isCancelled, self.isCurrent(id) else { return }
                self.fail(error, retry: .count)
            }
        }
    }

    private func presentConfirmation() {
        let id = UUID()
        let keys = recordKeys
        confirmationID = id
        let count = NumberFormatter.localizedString(from: NSNumber(value: records.count), number: .decimal)
        let message = "\(L10n.RSS.clearReadRecordsConfirmMessage)\n\(count) \(L10n.RSS.readRecordsTitle)"
        let dialog = ReaderRestoreProgressDialogViewController(
            title: L10n.RSS.clearReadRecordsConfirmTitle, message: message,
            accessibilityIdentifierPrefix: "rss.readRecords.confirmClear"
        ) { [weak self] confirmed in
            guard let self, self.confirmationID == id else { return }
            self.confirmation = nil
            if confirmed {
                self.pendingClear = (id, keys)
            } else {
                self.confirmationID = nil
            }
            self.resumeAfterTransition()
        }
        dialog.canConfirm = { [weak self, weak dialog] in
            guard let self, self.confirmationID == id, self.ownsSession, self.recordKeys == keys,
                self.operation == nil
            else { return false }
            return self.presentedViewController == nil || self.presentedViewController === dialog
        }
        dialog.onClose = { [weak self] in self?.resumeAfterTransition() }
        confirmation = dialog
        updateInteraction()
        present(dialog, animated: true)
    }

    private func resumeAfterTransition() {
        let id = confirmationID
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let transition = self.transitionCoordinator {
                if transition.animate(
                    alongsideTransition: nil,
                    completion: { [weak self] context in
                        if context.isCancelled, self?.confirmationID == id { self?.revokeConfirmation() }
                        DispatchQueue.main.async { [weak self] in self?.resumePresentation() }
                    })
                {
                    return
                }
            }
            self.resumePresentation()
        }
    }

    private func clearRecords() {
        let id = begin(.clear)
        task = Task { @MainActor [weak self, screen] in
            do {
                try await screen.clearReadRecords()
                try Task.checkCancellation()
                guard let self, self.isCurrent(id) else { return }
                let loaded = try await Self.readStableSnapshot(screen)
                try Task.checkCancellation()
                guard self.isCurrent(id) else { return }
                self.accept(loaded)
                self.pendingSuccess = L10n.RSS.clearReadRecordsSuccess
                self.endRequest()
                self.resumePresentation()
            } catch {
                guard let self, !Task.isCancelled, self.isCurrent(id) else { return }
                self.fail(error, retry: .count)
            }
        }
    }

    private func begin(_ operation: Operation) -> UUID {
        let id = UUID()
        requestID = id
        self.operation = operation
        failureMessage = nil
        render()
        return id
    }

    private func isCurrent(_ id: UUID) -> Bool {
        !isFinished && requestID == id && presentingViewController != nil && !isBeingDismissed
    }

    private static func readStableSnapshot(_ screen: RssScreenAdapter) async throws -> [RssReadRecord] {
        // Do not replace a newer Flow update with an older read, or count a cached UI array.
        while true {
            try Task.checkCancellation()
            let revision = screen.readRecordsRevision
            let loaded = try await screen.readRecords()
            try Task.checkCancellation()
            if revision == screen.readRecordsRevision { return loaded }
        }
    }

    private func accept(_ loaded: [RssReadRecord]) {
        records = loaded
        hasLoaded = true
    }

    private func endRequest() {
        requestID = nil
        task = nil
        operation = nil
        render()
    }

    private func fail(_ error: Error, retry: Operation) {
        failureMessage = error.userFacingMessage
        retryOperation = retry
        endRequest()
    }

    private func render() {
        guard isViewLoaded, !isFinished else { return }
        body.updateState(
            busy: operation != nil || needsLoad, failure: failureMessage,
            empty: hasLoaded && records.isEmpty && operation == nil && !needsLoad && failureMessage == nil)
        body.tableView.reloadData()
        body.tableView.accessibilityValue = String(records.count)
        dialogView.setNeedsLayout()
        updateInteraction()
    }

    private func updateInteraction() {
        guard isViewLoaded else { return }
        let enabled = canInteract && confirmationID == nil
        body.clearButton.isEnabled = enabled && runtimeReady && hasLoaded && !records.isEmpty && operation == nil
        body.retryButton.isEnabled = enabled && operation == nil
        body.tableView.isUserInteractionEnabled = enabled
        body.closeButton.isEnabled = enabled
        dialogView.outsideControl.isEnabled = enabled
    }

    @objc private func retry() {
        guard canInteract, operation == nil else { return }
        if retryOperation == .count { confirmClear() } else { loadRecords() }
    }

    private func revokeConfirmation() {
        confirmationID = nil
        pendingClear = nil
        if let dialog = confirmation, presentedViewController === dialog {
            dialog.dismiss(animated: false)
        }
        confirmation = nil
    }

    private func stopRequests() {
        requestID = nil
        task?.cancel()
        task = nil
        operation = nil
        confirmationID = nil
        pendingClear = nil
    }

    @objc private func closeDialog() {
        guard canInteract else { return }
        stopRequests()
        lifecycle.close(.cancelled, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    private func dismissDialog(animated: Bool, completion: @escaping () -> Void) {
        resignFirstResponder()
        super.dismiss(animated: animated, completion: completion)
    }

    private func finish() {
        guard !isFinished else { return }
        isFinished = true
        stopRequests()
        screen.unbind()
        NotificationCenter.default.removeObserver(self)
        let callback = onClose
        onClose = nil
        callback?()
    }

    func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int { records.count }

    func tableView(_ tableView: UITableView, cellForRowAt path: IndexPath) -> UITableViewCell {
        let cell =
            tableView.dequeueReusableCell(withIdentifier: "record")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "record")
        let record = records[path.row]
        cell.textLabel?.text = record.title
        cell.detailTextLabel?.text = record.record
        cell.textLabel?.font = ReaderAndroidDefaultFont.scaledFont(
            size: 16, textStyle: .body, compatibleWith: traitCollection)
        cell.detailTextLabel?.font = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .subheadline, compatibleWith: traitCollection)
        cell.textLabel?.textColor = AndroidReplicaTheme.primaryText
        cell.detailTextLabel?.textColor = AndroidReplicaTheme.secondaryText
        cell.textLabel?.numberOfLines = 0
        cell.detailTextLabel?.numberOfLines = 0
        cell.textLabel?.lineBreakMode = .byWordWrapping
        cell.detailTextLabel?.lineBreakMode = .byCharWrapping
        cell.backgroundColor = AndroidReplicaTheme.background
        cell.selectionStyle = .none
        cell.accessoryType = .none
        cell.isAccessibilityElement = true
        cell.accessibilityLabel = [record.title, record.record].compactMap { $0 }.joined(separator: "\n")
        cell.accessibilityTraits = .staticText
        return cell
    }
}

@MainActor
private final class RssReadRecordsDialogBodyView: UIView {
    let tableView = UITableView(frame: .zero, style: .plain)
    let clearButton = UIButton(type: .system)
    let closeButton = UIButton(type: .system)
    let retryButton = UIButton(type: .system)
    var maximumHeight: CGFloat = 500
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let emptyLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let toolbar = UIStackView()
    private let status = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = AndroidReplicaTheme.background
        titleLabel.text = L10n.RSS.readRecordsTitle
        titleLabel.textColor = AndroidReplicaTheme.primaryText
        titleLabel.numberOfLines = 0
        titleLabel.accessibilityTraits = .header
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        clearButton.setTitle(L10n.Common.clear, for: .normal)
        clearButton.accessibilityLabel = L10n.RSS.clearReadRecords
        clearButton.accessibilityIdentifier = "rss.readRecords.clear"
        clearButton.titleLabel?.numberOfLines = 0
        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.accessibilityLabel = L10n.Common.cancel
        closeButton.accessibilityIdentifier = "rss.readRecords.close"
        closeButton.addInteraction(UIToolTipInteraction(defaultToolTip: L10n.Common.cancel))
        retryButton.setImage(UIImage(systemName: "arrow.clockwise"), for: .normal)
        retryButton.accessibilityLabel = L10n.Common.retry
        retryButton.accessibilityIdentifier = "rss.readRecords.retry"
        retryButton.addInteraction(UIToolTipInteraction(defaultToolTip: L10n.Common.retry))
        messageLabel.numberOfLines = 0
        messageLabel.textColor = AndroidReplicaTheme.secondaryText
        emptyLabel.text = L10n.RSS.emptyReadRecords
        emptyLabel.textColor = AndroidReplicaTheme.secondaryText
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        tableView.backgroundColor = AndroidReplicaTheme.background
        tableView.accessibilityIdentifier = "rss.readRecords.table"
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 72
        tableView.separatorStyle = .none
        tableView.allowsSelection = false
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.tableFooterView = UIView()
        tableView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        toolbar.axis = .horizontal
        toolbar.alignment = .center
        toolbar.spacing = 8
        toolbar.isLayoutMarginsRelativeArrangement = true
        toolbar.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 8)
        [titleLabel, clearButton, closeButton].forEach { toolbar.addArrangedSubview($0) }
        status.axis = .horizontal
        status.alignment = .center
        status.spacing = 8
        status.isLayoutMarginsRelativeArrangement = true
        status.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 8)
        [spinner, messageLabel, retryButton].forEach { status.addArrangedSubview($0) }
        let stack = UIStackView(arrangedSubviews: [toolbar, status, tableView])
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            clearButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            clearButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
            retryButton.widthAnchor.constraint(equalToConstant: 44),
            retryButton.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    func applyFonts(traits: UITraitCollection) {
        titleLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 20, textStyle: .headline, weight: 500, compatibleWith: traits)
        clearButton.titleLabel?.font = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .body, compatibleWith: traits)
        messageLabel.font = ReaderAndroidDefaultFont.scaledFont(size: 14, textStyle: .body, compatibleWith: traits)
        emptyLabel.font = ReaderAndroidDefaultFont.scaledFont(size: 16, textStyle: .body, compatibleWith: traits)
    }

    func updateState(busy: Bool, failure: String?, empty: Bool) {
        status.isHidden = !busy && failure == nil
        messageLabel.text = failure ?? L10n.Common.loadingTitle
        spinner.isHidden = !busy
        if busy { spinner.startAnimating() } else { spinner.stopAnimating() }
        retryButton.isHidden = failure == nil
        tableView.backgroundView = empty ? emptyLabel : nil
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let width = max(1, size.width)
        let target = CGSize(width: width, height: UIView.layoutFittingCompressedSize.height)
        let header = toolbar.systemLayoutSizeFitting(
            target, withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        ).height
        let stateHeight =
            status.isHidden
            ? 0
            : status.systemLayoutSizeFitting(
                target, withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
            ).height
        let rowsHeight = max(160, tableView.contentSize.height)
        return CGSize(width: width, height: min(maximumHeight, header + stateHeight + min(440, rowsHeight)))
    }
}
