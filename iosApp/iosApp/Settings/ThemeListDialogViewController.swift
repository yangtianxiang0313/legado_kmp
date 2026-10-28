import UIKit
import shared

/// ThemeListDialog.kt / dialog_recycler_view / item_theme_config / menu/theme_list
/// at Legado 5f5d31404af9957684703747ecee2b91e7161f1d. Present a fresh instance directly.
/// Callback dispatch and loadPresets are on MainActor; async closures own real persistence.
/// Before committing after an await, honour cancellation and recheck the captured owner.
@MainActor
final class ThemeListDialogViewController: UIViewController,
    UITableViewDataSource, UITableViewDelegate, UIAdaptivePresentationControllerDelegate
{
    /// Optional, side-effect-free owner/session identity guard, not a preset validator.
    /// A false result disables submissions and cancels work, but never disables closing.
    var canSubmit: (() -> Bool)? {
        didSet {
            guard isViewLoaded else { return }
            updateInteraction()
        }
    }

    private struct RowToken {
        let generation: UInt64
        let epoch: UInt64
        let id: ThemeListDialogRow.ID
        let signature: ThemeListDialogRow.Signature
    }

    private enum Action {
        case apply(RowToken)
        case delete(RowToken)
        case importJSON(String)

        var rowToken: RowToken? {
            switch self {
            case .apply(let token), .delete(let token): return token
            case .importJSON: return nil
            }
        }

        var failureTitle: String {
            switch self {
            case .apply: return "应用失败"
            case .delete: return "删除失败"
            case .importJSON: return "导入失败"
            }
        }
    }

    private final class Work {
        let generation: UInt64
        let epoch: UInt64
        var invalidated = false
        var task: Task<Void, Never>?

        init(generation: UInt64, epoch: UInt64) {
            self.generation = generation
            self.epoch = epoch
        }
    }

    private final class Overlay {
        enum Kind {
            case confirmation(RowToken)
            case share
        }

        let controller: UIViewController
        let kind: Kind
        let epoch: UInt64
        var confirmAction: UIAlertAction?
        var isClosing = false
        var approved = false
        var onDetached: (() -> Void)?

        init(controller: UIViewController, kind: Kind, epoch: UInt64) {
            self.controller = controller
            self.kind = kind
            self.epoch = epoch
        }
    }

    private var loadPresets: (() -> [ThemePreset])?
    private var onApply: ((ThemePreset) async throws -> Void)?
    private var onDelete: ((ThemePreset) async throws -> Void)?
    private var onImport: ((String) async throws -> Void)?
    private let context = ThemeListDialogPresentationContext()
    private let outsideControl = UIControl()
    private let windowControl = UIControl()
    private let body = ThemeListDialogBodyView(frame: .zero)
    private var rows: [ThemeListDialogRow] = []
    private var generation: UInt64 = 0
    private var epoch: UInt64 = 0
    private var work: Work?
    private var overlay: Overlay?
    private var refreshTimer: Timer?
    private var hasStarted = false
    private var isVisible = false
    private var isClosing = false
    private var isFinished = false
    private var isUpdatingInteraction = false
    private var isCheckingIdentity = false
    private var isReloading = false
    private var wasPermitted = false
    private var boundEpoch: UInt64 = 0
    private var isEnvironmentSuspended = false
    private var lastTableWidth: CGFloat = 0

    init(
        loadPresets: @escaping () -> [ThemePreset],
        onApply: @escaping (ThemePreset) async throws -> Void,
        onDelete: @escaping (ThemePreset) async throws -> Void,
        onImport: @escaping (String) async throws -> Void
    ) {
        self.loadPresets = loadPresets
        self.onApply = onApply
        self.onDelete = onDelete
        self.onImport = onImport
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
        isModalInPresentation = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        let command = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancel))
        command.discoverabilityTitle = "取消"
        command.wantsPriorityOverSystemBehavior = true
        return [command]
    }

    override func loadView() {
        let root = ThemeListDialogRootView()
        root.onWindowChange = { [weak self] in self?.schedulePresentationRefresh() }
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.accessibilityViewIsModal = true
        view.accessibilityIdentifier = "settings.themeList"
        // AppCompat 1.7.1 Base.V7.Theme[.Light] defaults backgroundDimAmount to 0.6.
        outsideControl.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        outsideControl.isAccessibilityElement = false
        outsideControl.accessibilityElementsHidden = true
        outsideControl.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        body.importButton.addTarget(self, action: #selector(importFromClipboard), for: .touchUpInside)
        body.table.dataSource = self
        body.table.delegate = self
        view.addSubview(outsideControl)
        windowControl.isAccessibilityElement = false
        windowControl.accessibilityElementsHidden = true
        view.addSubview(windowControl)
        view.addSubview(body)
        view.accessibilityElements = [body]
        for name in [
            UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification,
            UIScene.didActivateNotification, UIScene.willDeactivateNotification,
            UIWindow.didBecomeKeyNotification, UIWindow.didResignKeyNotification,
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(environmentChanged(_:)), name: name, object: nil)
        }
        refreshRows(force: true)
        updateInteraction()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        presentationController?.delegate = self
        if !hasStarted, presentingViewController != nil {
            hasStarted = true
            context.capture(dialog: self)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !isFinished else { return }
        isVisible = true
        isClosing = false
        if !hasStarted {
            hasStarted = true
            context.capture(dialog: self)
        }
        refreshPresentation()
        startRefreshTimer()
        becomeFirstResponder()
        UIAccessibility.post(notification: .screenChanged, argument: body.titleLabel)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        invalidateWork()
        if isBeingDismissed || ancestorIsLeaving { isClosing = true }
        updateInteraction()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        schedulePresentationRefresh()
    }

    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        // UIKit uses this method for dismissing a presented share sheet/confirmation too.
        if presentedViewController != nil {
            super.dismiss(animated: flag, completion: completion)
            return
        }
        beginClosing()
        super.dismiss(animated: flag) { [weak self] in
            self?.finishIfDetached()
            completion?()
        }
    }

    func presentationControllerDidDismiss(_: UIPresentationController) {
        schedulePresentationRefresh()
    }

    override func accessibilityPerformEscape() -> Bool {
        guard canClose else { return false }
        cancel()
        return true
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard isViewLoaded else { return }
        body.applyAppearance()
        reloadTablePreservingAnchor()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        outsideControl.frame = view.bounds
        let safe = view.safeAreaLayoutGuide.layoutFrame
        // setLayout sizes the floating window; AppCompat's drawable then insets its content 16dp.
        let outer = CGRect(
            x: safe.minX + safe.width * 0.05, y: safe.minY + safe.height * 0.05,
            width: safe.width * 0.9, height: safe.height * 0.9)
        windowControl.frame = outer
        let anchor = ThemeListDialogScrollAnchor(table: body.table, rows: rows)
        body.frame = outer.insetBy(dx: min(16, outer.width / 2), dy: min(16, outer.height / 2))
        body.layoutIfNeeded()
        if lastTableWidth != body.table.bounds.width {
            lastTableWidth = body.table.bounds.width
            body.table.reloadData()
            body.table.layoutIfNeeded()
        }
        anchor?.restore(table: body.table, rows: rows)
    }

    /// The owner may call this after external metadata/storage changes, on MainActor.
    /// Keeps the top visible name/occurrence anchored even when its colours or pairing change.
    func reloadPresets() {
        guard !isFinished else { return }
        guard isViewLoaded else { return }
        refreshRows(force: true)
        updateInteraction()
    }

    func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int { rows.count }

    func tableView(_: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        guard rows.indices.contains(indexPath.row) else { return 52 }
        return ThemeListDialogCell.height(traits: traitCollection)
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard rows.indices.contains(indexPath.row),
            let cell = tableView.dequeueReusableCell(
                withIdentifier: ThemeListDialogCell.reuseID, for: indexPath) as? ThemeListDialogCell
        else { return UITableViewCell() }
        let row = rows[indexPath.row]
        let token = RowToken(generation: generation, epoch: epoch, id: row.id, signature: row.signature)
        cell.configure(name: row.signature.themeName, enabled: canBeginAction)
        cell.onApply = { [weak self] in self?.start(.apply(token)) }
        cell.onDelete = { [weak self] in self?.confirmDeletion(token) }
        cell.onShare = { [weak self] anchor in self?.share(token, from: anchor) }
        return cell
    }

    private func refreshRows(force: Bool = false) {
        guard !isFinished, !isReloading, let loadPresets else { return }
        isReloading = true
        defer { isReloading = false }
        let next = ThemeListDialogRow.make(loadPresets())
        guard !isFinished, force || next.map(\.signature) != rows.map(\.signature) else { return }
        let anchor = ThemeListDialogScrollAnchor(table: body.table, rows: rows)
        generation &+= 1
        invalidateWork()
        if let overlay {
            overlay.confirmAction?.isEnabled = false
            dismissOverlay(overlay)
        }
        rows = next
        UIView.performWithoutAnimation {
            body.table.reloadData()
            body.table.layoutIfNeeded()
            anchor?.restore(table: body.table, rows: rows)
        }
        body.applyAppearance()
    }

    private func reloadTablePreservingAnchor() {
        let anchor = ThemeListDialogScrollAnchor(table: body.table, rows: rows)
        UIView.performWithoutAnimation {
            body.table.reloadData()
            body.table.layoutIfNeeded()
            anchor?.restore(table: body.table, rows: rows)
        }
    }

    private func currentRow(_ token: RowToken) -> ThemeListDialogRow? {
        guard token.generation == generation, token.epoch == epoch else { return nil }
        return rows.first { $0.id == token.id && $0.signature == token.signature }
    }

    private func validate(_ token: RowToken) -> ThemeListDialogRow? {
        refreshRows()
        guard let row = currentRow(token) else {
            showError("主题列表已更新，请重新选择。")
            updateInteraction()
            return nil
        }
        return row
    }

    @objc private func importFromClipboard() {
        guard canBeginAction else {
            updateInteraction()
            return
        }
        // This is the only pasteboard read. Never inspect it on load, polling or retries.
        let text = UIPasteboard.general.string
        guard canBeginAction else {
            updateInteraction()
            return
        }
        guard let text, !text.isEmpty else {
            showError("剪贴板中没有可导入的主题文本。")
            return
        }
        start(.importJSON(text))
    }

    private func start(_ action: Action) {
        guard canBeginAction else {
            updateInteraction()
            return
        }
        let operation: () async throws -> Void
        switch action {
        case .apply(let token):
            guard let row = validate(token), let onApply else { return }
            operation = { try await onApply(row.preset) }
        case .delete(let token):
            guard let row = validate(token), let onDelete else { return }
            operation = { try await onDelete(row.preset) }
        case .importJSON(let text):
            refreshRows()
            guard let onImport else { return }
            operation = { try await onImport(text) }
        }
        guard canBeginAction else {
            updateInteraction()
            return
        }
        let pending = Work(generation: generation, epoch: epoch)
        work = pending
        body.showError(nil)
        updateInteraction()
        pending.task = Task { @MainActor [weak self, weak pending] in
            guard let pending else { return }
            // Recheck after the task's scheduling gap, before invoking a storage callback.
            guard self?.mayExecute(pending, action: action) == true else {
                self?.finish(pending, action: action, result: nil)
                return
            }
            do {
                try Task.checkCancellation()
                try await operation()
                self?.finish(pending, action: action, result: .success(()))
            } catch {
                self?.finish(pending, action: action, result: .failure(error))
            }
        }
    }

    private func mayExecute(_ pending: Work, action: Action) -> Bool {
        guard work === pending, !pending.invalidated, !isClosing, !isFinished,
            pending.epoch == epoch, pending.generation == generation,
            isVisible, overlay == nil, permitsSubmission()
        else { return false }
        refreshRows()
        if let token = action.rowToken, currentRow(token) == nil { return false }
        return permitsSubmission() && work === pending && !pending.invalidated
            && pending.epoch == epoch && pending.generation == generation
            && isVisible && overlay == nil
    }

    private func finish(_ pending: Work, action: Action, result: Result<Void, Error>?) {
        guard work === pending else { return }
        let accepted =
            permitsSubmission() && !pending.invalidated && pending.epoch == epoch
            && pending.generation == generation && isVisible
        pending.task = nil
        work = nil
        guard accepted, !isClosing, !isFinished else {
            updateInteraction()
            return
        }
        switch result {
        case .success?:
            body.showError(nil)
            refreshRows(force: true)
        case .failure(let error)?:
            // No optimistic removal or applying state: the same rows remain available to retry.
            showError("\(action.failureTitle)：\(error.localizedDescription)")
        case nil: break
        }
        updateInteraction()
    }

    private func confirmDeletion(_ token: RowToken) {
        guard canBeginAction, validate(token) != nil, canBeginAction else { return }
        let alert = UIAlertController(title: "删除", message: "是否确认删除？", preferredStyle: .alert)
        let pending = Overlay(controller: alert, kind: .confirmation(token), epoch: epoch)
        let yes = UIAlertAction(title: "确定", style: .default) { [weak self, weak pending] _ in
            guard let self, let pending, self.overlay === pending, !pending.approved,
                !pending.isClosing, pending.epoch == self.epoch, self.permitsSubmission(),
                pending.controller.presentedViewController == nil, self.currentRow(token) != nil
            else { return }
            pending.approved = true
            self.dismissOverlay(pending) { [weak self, weak pending] in
                guard let self, let pending, pending.epoch == self.epoch,
                    self.canBeginAction, self.validate(token) != nil, self.canBeginAction
                else { return }
                self.start(.delete(token))
            }
        }
        pending.confirmAction = yes
        alert.addAction(yes)
        alert.addAction(
            UIAlertAction(title: "否", style: .cancel) { [weak self, weak pending] _ in
                guard let pending else { return }
                self?.dismissOverlay(pending)
            })
        alert.preferredAction = yes
        overlay = pending
        present(alert, animated: !UIAccessibility.isReduceMotionEnabled)
        updateInteraction()
    }

    private func share(_ token: RowToken, from anchor: UIView) {
        guard canBeginAction, let row = validate(token), canBeginAction,
            anchor.window === view.window
        else { return }
        do {
            let item = try ThemeListDialogShareItem(preset: row.preset)
            guard canBeginAction, currentRow(token) != nil else { return }
            let sheet = UIActivityViewController(activityItems: [item], applicationActivities: nil)
            sheet.title = "主题分享"
            let pending = Overlay(controller: sheet, kind: .share, epoch: epoch)
            sheet.completionWithItemsHandler = { [weak self, weak pending] _, _, _, error in
                Task { @MainActor [weak self, weak pending] in
                    guard let self, let pending, self.overlay === pending else { return }
                    self.dismissOverlay(pending) { [weak self, weak pending] in
                        guard let self, let pending, pending.epoch == self.epoch,
                            self.permitsSubmission()
                        else { return }
                        if let error { self.showError("分享失败：\(error.localizedDescription)") }
                    }
                }
            }
            if let popover = sheet.popoverPresentationController {
                popover.sourceView = anchor
                popover.sourceRect = anchor.bounds
                popover.permittedArrowDirections = [.up, .down]
            }
            overlay = pending
            present(sheet, animated: !UIAccessibility.isReduceMotionEnabled)
            sheet.presentationController?.delegate = self
            updateInteraction()
        } catch {
            showError("分享失败：\(error.localizedDescription)")
        }
    }

    private func dismissOverlay(_ pending: Overlay, completion: (() -> Void)? = nil) {
        guard overlay === pending, !pending.isClosing else { return }
        pending.isClosing = true
        pending.onDetached = completion
        pending.confirmAction?.isEnabled = false
        pending.controller.dismiss(animated: !UIAccessibility.isReduceMotionEnabled) { [weak self, weak pending] in
            guard let pending else { return }
            self?.releaseOverlayIfDetached(pending)
        }
    }

    private func releaseOverlayIfDetached(_ pending: Overlay) {
        guard overlay === pending, presentedViewController !== pending.controller,
            pending.controller.presentingViewController == nil,
            pending.controller.viewIfLoaded?.window == nil,
            !pending.controller.isBeingPresented, !pending.controller.isBeingDismissed
        else { return }
        let completion = pending.onDetached
        pending.onDetached = nil
        overlay = nil
        refreshPresentation()
        completion?()
    }

    private func showError(_ message: String) {
        guard !isClosing, !isFinished else { return }
        body.showError(message)
        view.setNeedsLayout()
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    private func permitsSubmission() -> Bool {
        guard hasStarted, !isClosing, !isFinished, !isCheckingIdentity, !isEnvironmentSuspended,
            context.isCurrent(dialog: self, allowing: overlay?.controller)
        else { return false }
        isCheckingIdentity = true
        let allowed = canSubmit?() ?? true
        isCheckingIdentity = false
        // The caller must supply a pure gate, but reentrancy still cannot bypass the hierarchy check.
        return allowed && !isClosing && !isFinished && !isEnvironmentSuspended
            && context.isCurrent(dialog: self, allowing: overlay?.controller)
    }

    private var canBeginAction: Bool {
        isVisible && work == nil && overlay == nil && permitsSubmission()
    }

    private var canClose: Bool {
        guard hasStarted, isVisible, !isClosing, !isFinished,
            !isBeingPresented, !isBeingDismissed, presentedViewController == nil,
            presentingViewController != nil, let window = viewIfLoaded?.window,
            !window.isHidden, window.alpha > 0,
            window.windowScene?.activationState == .foregroundActive
        else { return false }
        return true
    }

    private var ancestorIsLeaving: Bool {
        var current = presentingViewController
        while let controller = current {
            if controller.isBeingDismissed || controller.isMovingFromParent { return true }
            current = controller.parent ?? controller.presentingViewController
        }
        return false
    }

    private func updateInteraction() {
        guard isViewLoaded, !isUpdatingInteraction else { return }
        isUpdatingInteraction = true
        defer { isUpdatingInteraction = false }
        let permitted = permitsSubmission()
        if !permitted {
            if wasPermitted { epoch &+= 1 }
            invalidateWork()
        }
        wasPermitted = permitted
        if permitted, boundEpoch != epoch {
            boundEpoch = epoch
            reloadTablePreservingAnchor()
        }
        let enabled = permitted && isVisible && work == nil && overlay == nil
        outsideControl.isEnabled = canClose
        body.setInteraction(enabled: enabled, busy: work != nil)
        for case let cell as ThemeListDialogCell in body.table.visibleCells {
            cell.setActionsEnabled(enabled)
        }
        if let overlay, case .confirmation(let token) = overlay.kind {
            overlay.confirmAction?.isEnabled =
                permitted && !overlay.isClosing
                && overlay.epoch == epoch && currentRow(token) != nil
                && overlay.controller.presentedViewController == nil
        }
    }

    private func invalidateWork() {
        guard let work, !work.invalidated else { return }
        work.invalidated = true
        work.task?.cancel()
        // Keep the single-flight lock until a non-cooperative callback actually returns.
    }

    @objc private func environmentChanged(_ notification: Notification) {
        guard hasStarted, !isFinished else { return }
        let inactive =
            notification.name == UIApplication.willResignActiveNotification
            || (notification.name == UIScene.willDeactivateNotification
                && (notification.object as? UIScene) === viewIfLoaded?.window?.windowScene)
            || (notification.name == UIWindow.didResignKeyNotification
                && (notification.object as? UIWindow) === viewIfLoaded?.window)
        if inactive {
            isEnvironmentSuspended = true
            epoch &+= 1
            invalidateWork()
            overlay?.confirmAction?.isEnabled = false
        } else if notification.name == UIApplication.didBecomeActiveNotification
            || (notification.name == UIScene.didActivateNotification
                && (notification.object as? UIScene) === viewIfLoaded?.window?.windowScene)
            || (notification.name == UIWindow.didBecomeKeyNotification
                && (notification.object as? UIWindow) === viewIfLoaded?.window)
        {
            isEnvironmentSuspended = false
        }
        refreshPresentation()
    }

    private func refreshPresentation() {
        finishIfDetached()
        guard !isFinished else { return }
        if let overlay { releaseOverlayIfDetached(overlay) }
        let permitted = permitsSubmission()
        if !permitted {
            invalidateWork()
        }
        if permitted, work == nil { refreshRows() }
        updateInteraction()
    }

    private func schedulePresentationRefresh() {
        DispatchQueue.main.async { [weak self] in self?.refreshPresentation() }
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        // Navigation/owner changes have no common UIKit notification; loadPresets must be cheap.
        let timer = Timer(
            timeInterval: 0.2, target: RefreshTarget(owner: self),
            selector: #selector(RefreshTarget.tick(_:)), userInfo: nil, repeats: true)
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func cancel() {
        guard canClose else { return }
        beginClosing()
        super.dismiss(animated: !UIAccessibility.isReduceMotionEnabled) { [weak self] in
            self?.finishIfDetached()
        }
    }

    private func beginClosing() {
        guard !isFinished else { return }
        isClosing = true
        isVisible = false
        epoch &+= 1
        invalidateWork()
        updateInteraction()
        resignFirstResponder()
    }

    private func finishIfDetached() {
        guard hasStarted, !isFinished, presentingViewController == nil,
            parent == nil, viewIfLoaded?.window == nil
        else { return }
        isFinished = true
        isVisible = false
        epoch &+= 1
        invalidateWork()
        refreshTimer?.invalidate()
        refreshTimer = nil
        NotificationCenter.default.removeObserver(self)
        overlay = nil
        loadPresets = nil
        onApply = nil
        onDelete = nil
        onImport = nil
        canSubmit = nil
        updateInteraction()
    }

    @MainActor
    private final class RefreshTarget: NSObject {
        weak var owner: ThemeListDialogViewController?

        init(owner: ThemeListDialogViewController) { self.owner = owner }

        @objc func tick(_ timer: Timer) {
            guard let owner else {
                timer.invalidate()
                return
            }
            owner.refreshPresentation()
        }
    }
}
