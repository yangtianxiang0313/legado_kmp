import UIKit
import shared

@MainActor
final class CloudBackupViewController: UITableViewController {
    private enum RestorePhase { case idle, uploadPassword, uploading, password, preparing, confirming, committing, finishing }
    private let screen = CloudBackupScreenAdapter()
    private var files: [CloudBackupFile] = []
    private var task: Task<Void, Never>?
    private var requestID = UUID()
    private var visible = false
    private var loading = false
    private var processing = false
    private var failure: String?
    private var initialRestore: CloudBackupFile?
    private var initialConfiguration: AutomaticBackupConfiguration?
    private var filesConfiguration: AutomaticBackupConfiguration?
    private var context: CloudBackupScreenContext?
    private var contextMonitor: Task<Void, Never>?
    private var previousInteractivePop: Bool?
    private weak var processingNavigationController: UINavigationController?
    private var restorePhase = RestorePhase.idle
    private weak var restorePresentation: UIAlertController?
    private var passwordHandle: BackupPasswordPrompt.Handle?
    private var preparedRestore: PreparedCloudBackup?
    private var restoreInvalidated = false
    private var preparationCancelledByUser = false
    var onRestored: (() -> Void)?
    var onReturn: (() -> Void)?

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if parent == nil, let callback = onReturn {
            onReturn = nil
            callback()
        }
    }

    init(initialRestore: CloudBackupFile? = nil, configuration: AutomaticBackupConfiguration? = nil) {
        self.initialRestore = initialRestore
        initialConfiguration = configuration
        super.init(style: .plain)
        title = CloudBackupCopy.title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit {
        task?.cancel()
        contextMonitor?.cancel()
        preparedRestore?.discard()
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 72
        tableView.accessibilityIdentifier = "backup.cloud.list"
        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(reloadBackups), for: .valueChanged)
        refreshControl = refresh
        NotificationCenter.default.addObserver(
            self, selector: #selector(applyPalette), name: .androidReplicaThemeDidChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(becameActive(_:)), name: UIApplication.didBecomeActiveNotification, object: nil)
        for name in [UIScene.didActivateNotification, UIWindow.didBecomeKeyNotification, .appLockStatusDidChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(becameActive(_:)), name: name, object: nil)
        }
        for name in [
            UIApplication.willResignActiveNotification, UIScene.willDeactivateNotification,
            UIScene.didDisconnectNotification, UIWindow.didResignKeyNotification,
            UIWindow.didBecomeHiddenNotification,
            .appLockWillCover, .appLockStatusDidChange,
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(restoreContextChanged(_:)), name: name, object: nil)
        }
        applyPalette()
        updateControls()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        visible = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.canUseCloudScreen, !self.processing else { return }
            if self.task == nil { self.reloadBackups() }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        visible = false
        invalidateContext()
    }

    @objc private func applyPalette() {
        view.backgroundColor = AndroidReplicaTheme.background
        tableView.backgroundColor = AndroidReplicaTheme.background
        tableView.separatorColor = AndroidReplicaTheme.divider
        tableView.reloadData()
    }

    @objc private func becameActive(_ notification: Notification) {
        guard belongsToContext(notification) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, canUseCloudScreen, !processing, task == nil else { return }
            reloadBackups()
        }
    }

    private func updateControls() {
        let upload = UIBarButtonItem(
            image: UIImage(systemName: "icloud.and.arrow.up"), style: .plain, target: self, action: #selector(uploadBackup))
        upload.accessibilityLabel = CloudBackupCopy.uploadAction
        upload.accessibilityIdentifier = "backup.cloud.upload"
        upload.isEnabled = !loading && !processing
        let refresh = UIBarButtonItem(barButtonSystemItem: .refresh, target: self, action: #selector(reloadBackups))
        refresh.accessibilityIdentifier = "backup.cloud.refresh"
        refresh.isEnabled = !loading && !processing
        navigationItem.rightBarButtonItems = [upload, refresh]
        navigationItem.hidesBackButton = processing
        if processing, previousInteractivePop == nil {
            processingNavigationController = navigationController
            previousInteractivePop = navigationController?.interactivePopGestureRecognizer?.isEnabled
            navigationController?.interactivePopGestureRecognizer?.isEnabled = false
        } else if !processing, let previousInteractivePop {
            if processingNavigationController?.topViewController === self {
                processingNavigationController?.interactivePopGestureRecognizer?.isEnabled = previousInteractivePop
            }
            self.previousInteractivePop = nil
            processingNavigationController = nil
        }
        tableView.isUserInteractionEnabled = !processing
    }

    @objc private func reloadBackups() {
        guard canUseCloudScreen, !processing else {
            refreshControl?.endRefreshing()
            return
        }
        guard let context = captureContext() else {
            refreshControl?.endRefreshing()
            return
        }
        task?.cancel()
        let id = UUID()
        requestID = id
        self.context = context
        if let filesConfiguration, !screen.matchesConfiguration(filesConfiguration) {
            files = []
            self.filesConfiguration = nil
        }
        monitorContext(id)
        loading = true
        failure = nil
        updateControls()
        tableView.reloadData()
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if requestID == id {
                    task = nil
                    loading = false
                    refreshControl?.endRefreshing()
                    updateControls()
                    tableView.reloadData()
                }
            }
            do {
                let loaded = try await screen.list(configuration: context.configuration)
                guard currentContext(id), !Task.isCancelled else { return }
                files = loaded
                filesConfiguration = context.configuration
            } catch is CancellationError {
                return
            } catch {
                guard currentContext(id) else { return }
                failure = error.userFacingMessage
            }
            if let selected = initialRestore, failure == nil {
                initialRestore = nil
                let matchesInitial = initialConfiguration.map { self.screen.matchesConfiguration($0) } ?? true
                initialConfiguration = nil
                guard matchesInitial else {
                    showResult(CloudBackupCopy.configurationChanged)
                    return
                }
                if let file = files.first(where: { $0.name == selected.name && $0.lastModified == selected.lastModified }) {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.currentContext(id) else { return }
                        self.confirmRestore(file)
                    }
                } else {
                    showResult(CloudBackupCopy.selectionChanged)
                }
            }
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { max(1, files.count) }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        files.isEmpty ? nil : failure.map { CloudBackupCopy.refreshFailed + "\n" + $0 }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.backgroundColor = AndroidReplicaTheme.background
        cell.textLabel?.textColor = AndroidReplicaTheme.primaryText
        cell.detailTextLabel?.textColor = AndroidReplicaTheme.secondaryText
        cell.textLabel?.font = .preferredFont(forTextStyle: .body)
        cell.detailTextLabel?.font = .preferredFont(forTextStyle: .footnote)
        cell.textLabel?.numberOfLines = 0
        cell.detailTextLabel?.numberOfLines = 0
        guard !files.isEmpty else {
            cell.textLabel?.text = loading ? CloudBackupCopy.loading : (failure == nil ? CloudBackupCopy.empty : CloudBackupCopy.retry)
            cell.detailTextLabel?.text = failure
            cell.accessibilityIdentifier = failure == nil ? "backup.cloud.empty" : "backup.cloud.retry"
            cell.selectionStyle = failure == nil ? .none : .default
            return cell
        }
        let file = files[indexPath.row]
        cell.textLabel?.text = file.name
        let date =
            file.lastModified > 0
            ? DateFormatter.localizedString(
                from: Date(timeIntervalSince1970: Double(file.lastModified) / 1000), dateStyle: .medium, timeStyle: .short)
            : CloudBackupCopy.unknownTime
        cell.detailTextLabel?.text = date + " · " + ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityIdentifier = "backup.cloud.file.\(file.name)"
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !loading, !processing else { return }
        guard !files.isEmpty else {
            if failure != nil { reloadBackups() }
            return
        }
        confirmRestore(files[indexPath.row])
    }

    @objc private func uploadBackup() {
        guard canUseCloudScreen, task == nil, !processing, let context = captureContext() else { return }
        let id = UUID()
        requestID = id
        self.context = context
        restoreInvalidated = false
        restorePhase = .uploadPassword
        processing = true
        updateControls()
        passwordHandle = BackupPasswordPrompt.present(
            from: self, creating: true,
            onCancel: { [weak self] in
                guard let self, self.requestID == id, self.restorePhase == .uploadPassword else { return }
                self.cancelRestore(id, userInitiated: true)
            },
            onConfirm: { [weak self] password in
                guard let self, self.requestID == id, self.restorePhase == .uploadPassword else { return }
                self.task = Task { [weak self] in
                    guard let self else { return }
                    guard currentRestore(id, phase: .uploadPassword), canPerformNavigationAction else {
                        await finishRestore(id)
                        return
                    }
                    performUpload(password, id: id)
                }
            })
        restorePresentation = passwordHandle?.controller
        guard passwordHandle != nil else {
            Task { [weak self] in await self?.finishRestore(id) }
            return
        }
        monitorContext(id)
    }

    func confirmRestore(_ file: CloudBackupFile) {
        guard canUseCloudScreen, task == nil, !loading, !processing else { return }
        guard let filesConfiguration, screen.matchesConfiguration(filesConfiguration), let context = captureContext() else {
            reloadBackups()
            return
        }
        let id = UUID()
        requestID = id
        self.context = context
        restoreInvalidated = false
        preparationCancelledByUser = false
        restorePhase = .password
        processing = true
        updateControls()
        let prompt = UIAlertController(
            title: CloudBackupCopy.restoreTitle, message: CloudBackupCopy.restoreMessage + "\n" + file.name, preferredStyle: .alert)
        prompt.view.accessibilityIdentifier = "backup.cloud.restore.confirm"
        prompt.addTextField {
            $0.placeholder = CloudBackupCopy.optionalPassword
            $0.isSecureTextEntry = true
            $0.autocorrectionType = .no
            $0.autocapitalizationType = .none
            $0.textContentType = .password
            $0.accessibilityIdentifier = "backup.cloud.password.0"
        }
        prompt.addAction(
            UIAlertAction(title: L10n.Common.cancel, style: .cancel) { [weak self, weak prompt] _ in
                guard let self, let prompt, self.task == nil, self.restorePresentation === prompt,
                    self.currentRestore(id, phase: .password)
                else { return }
                for field in prompt.textFields ?? [] { field.text = nil }
                self.cancelRestore(id)
            })
        prompt.addAction(
            UIAlertAction(title: L10n.Common.confirm, style: .default) { [weak self, weak prompt] _ in
                guard let self, let prompt, self.task == nil, self.restorePresentation === prompt,
                    self.currentRestore(id, phase: .password)
                else { return }
                let password = prompt.textFields?.first?.text ?? ""
                for field in prompt.textFields ?? [] { field.text = nil }
                self.task = Task { [weak self] in
                    guard let self else { return }
                    await dismissRestorePresentation(prompt)
                    guard currentRestore(id, phase: .password), canPerformNavigationAction else {
                        await finishRestore(id)
                        return
                    }
                    prepareRestore(file, password: password, id: id)
                }
            })
        restorePresentation = prompt
        monitorContext(id)
        present(prompt, animated: true)
    }

    private func performUpload(_ password: String, id: UUID) {
        guard currentRestore(id, phase: .uploadPassword), let context else { return }
        passwordHandle = nil
        restorePhase = .uploading
        let hud = progressAlert(CloudBackupCopy.uploading, cancellable: true, id: id)
        hud.message = CloudBackupCopy.uploadCancellationNotice
        restorePresentation = hud
        present(hud, animated: true)
        task = Task { [weak self] in
            guard let self else { return }
            let message: String
            do {
                guard currentRestore(id, phase: .uploading) else {
                    await finishRestore(id)
                    return
                }
                let result = try await screen.upload(password: password, configuration: context.configuration)
                // A late cancellation must not replace a success claimed by shared.
                message =
                    ([String(format: CloudBackupCopy.uploaded, result.file.name)]
                    + SettingsBackupPreparationClient.localizedWarnings(result.warnings)).joined(separator: "\n")
            } catch is CancellationError {
                message = CloudBackupCopy.uploadCancelled
            } catch {
                message = error.userFacingMessage
            }
            await finishRestore(id, message: message)
        }
    }

    private func prepareRestore(_ file: CloudBackupFile, password: String, id: UUID) {
        guard currentRestore(id, phase: .password), let context else { return }
        restorePhase = .preparing
        let hud = UIAlertController(
            title: CloudBackupCopy.preparing, message: CloudBackupCopy.preparingMessage, preferredStyle: .alert)
        hud.view.accessibilityIdentifier = "backup.cloud.preparing"
        hud.addAction(
            UIAlertAction(title: CloudBackupCopy.cancelPreparation, style: .cancel) { [weak self, weak hud] _ in
                guard let self, let hud, self.restorePresentation === hud, self.currentRestore(id, phase: .preparing) else { return }
                self.cancelRestore(id, userInitiated: true)
            })
        restorePresentation = hud
        present(hud, animated: true)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                guard currentRestore(id, phase: .preparing) else {
                    await finishRestore(id)
                    return
                }
                let prepared = try await screen.prepareRestore(file: file, password: password, configuration: context.configuration)
                guard currentRestore(id, phase: .preparing) else {
                    prepared.discard()
                    await finishPreparation(id)
                    return
                }
                preparedRestore = prepared
                await dismissRestorePresentation(hud)
                guard currentRestore(id, phase: .preparing), canPerformNavigationAction else {
                    await finishPreparation(id)
                    return
                }
                restorePhase = .confirming
                confirmPreparedRestore(prepared, id: id)
                task = nil
            } catch {
                let message = restoreInvalidated || error is CancellationError ? nil : error.userFacingMessage
                await finishPreparation(id, message: message)
            }
        }
    }

    private func confirmPreparedRestore(_ prepared: PreparedCloudBackup, id: UUID) {
        guard currentRestore(id, phase: .confirming), canPerformNavigationAction else {
            prepared.discard()
            cancelRestore(id)
            return
        }
        let alert = UIAlertController(
            title: CloudBackupCopy.confirmRestore, message: CloudBackupCopy.preparedSummary(prepared), preferredStyle: .alert)
        alert.view.accessibilityIdentifier = "backup.cloud.restore.prepared.confirm"
        alert.addAction(
            UIAlertAction(title: L10n.Common.cancel, style: .cancel) { [weak self, weak alert] _ in
                guard let self, let alert, self.task == nil, self.restorePresentation === alert,
                    self.currentRestore(id, phase: .confirming)
                else { return }
                self.cancelRestore(id)
            })
        alert.addAction(
            UIAlertAction(title: CloudBackupCopy.restoreAction, style: .destructive) { [weak self, weak alert] _ in
                guard let self, let alert, self.task == nil, self.restorePresentation === alert,
                    self.currentRestore(id, phase: .confirming),
                    self.preparedRestore === prepared
                else { return }
                self.task = Task { [weak self] in
                    guard let self else { return }
                    // UIAlertAction runs before its dismissal animation has completed.
                    await dismissRestorePresentation(alert)
                    guard currentRestore(id, phase: .confirming), canPerformNavigationAction,
                        preparedRestore === prepared
                    else {
                        await finishRestore(id)
                        return
                    }
                    commitRestore(prepared, id: id)
                }
            })
        restorePresentation = alert
        present(alert, animated: true)
    }

    private func commitRestore(_ prepared: PreparedCloudBackup, id: UUID) {
        guard currentRestore(id, phase: .confirming) else { return }
        restorePhase = .committing
        preparedRestore = nil
        let hud = progressAlert(CloudBackupCopy.restoring, cancellable: false, id: id)
        hud.message = CloudBackupCopy.committingMessage
        restorePresentation = hud
        present(hud, animated: true)
        task = Task { [weak self] in
            guard let self else {
                prepared.discard()
                return
            }
            defer { prepared.discard() }
            guard currentRestore(id, phase: .committing) else {
                await finishRestore(id)
                return
            }
            let message: String
            do {
                let restored = try await screen.restore(prepared: prepared)
                // Do not suppress success when the Swift task was cancelled after shared committed.
                onRestored?()
                message =
                    ([CloudBackupCopy.restored, CloudBackupCopy.restoreSummary(restored.result)]
                    + SettingsBackupPreparationClient.localizedWarnings(restored.warnings)).joined(separator: "\n")
            } catch is CancellationError {
                message = CloudBackupCopy.restoreEnded
            } catch {
                message = error.userFacingMessage + "\n" + CloudBackupCopy.restoreCheck
            }
            await finishRestore(id, message: message)
        }
    }

    private func finishPreparation(_ id: UUID, message: String? = nil) async {
        guard requestID == id else { return }
        let result = preparationCancelledByUser ? CloudBackupCopy.preparationCancelled : message
        await finishRestore(id, message: result)
    }

    private func finishRestore(_ id: UUID, message: String? = nil) async {
        guard requestID == id, restorePhase != .idle, restorePhase != .finishing else { return }
        restorePhase = .finishing
        let handle = passwordHandle
        passwordHandle = nil
        handle?.cancel()
        preparedRestore?.discard()
        preparedRestore = nil
        if let presentation = restorePresentation { await dismissRestorePresentation(presentation) }
        guard requestID == id else { return }
        let mayPresent = currentContext(id) && !restoreInvalidated && canPerformNavigationAction
        restorePhase = .idle
        restorePresentation = nil
        restoreInvalidated = false
        preparationCancelledByUser = false
        task = nil
        loading = false
        processing = false
        refreshControl?.endRefreshing()
        updateControls()
        guard let message else { return }
        if mayPresent { showResult(message) }
    }

    private func cancelRestore(_ id: UUID, userInitiated: Bool = false) {
        guard requestID == id, restorePhase != .idle else { return }
        if !userInitiated {
            restoreInvalidated = true
            context?.invalidated = true
        }
        preparationCancelledByUser = preparationCancelledByUser || (userInitiated && restorePhase == .preparing)
        task?.cancel()
        guard restorePhase != .committing, restorePhase != .uploading, restorePhase != .finishing else { return }
        let handle = passwordHandle
        passwordHandle = nil
        handle?.cancel()
        preparedRestore?.discard()
        preparedRestore = nil
        for field in restorePresentation?.textFields ?? [] { field.text = nil }
        if restorePhase == .preparing {
            if let presentation = restorePresentation {
                Task { [weak self] in await self?.dismissRestorePresentation(presentation) }
            }
            return
        }
        Task { [weak self] in await self?.finishRestore(id) }
    }

    @objc private func restoreContextChanged(_ notification: Notification) {
        guard belongsToContext(notification) else { return }
        if notification.name == .appLockStatusDidChange,
            AppLockManager.shared.isUnlocked(in: context?.window ?? viewIfLoaded?.window)
        {
            return
        }
        invalidateContext()
    }

    private func belongsToContext(_ notification: Notification) -> Bool {
        let window = context?.window ?? viewIfLoaded?.window
        if let scene = notification.object as? UIScene { return scene === (context?.scene ?? window?.windowScene) }
        if let other = notification.object as? UIWindow { return other === window }
        return true
    }

    private func invalidateContext() {
        context?.invalidated = true
        if let filesConfiguration, !screen.matchesConfiguration(filesConfiguration) {
            files = []
            self.filesConfiguration = nil
            initialRestore = nil
            initialConfiguration = nil
            tableView.reloadData()
        }
        for field in restorePresentation?.textFields ?? [] { field.text = nil }
        guard restorePhase != .idle else {
            if !processing {
                requestID = UUID()
                task?.cancel()
                task = nil
                contextMonitor?.cancel()
                if let presentation = restorePresentation {
                    Task { [weak self] in await self?.dismissRestorePresentation(presentation) }
                }
                restorePresentation = nil
                loading = false
                refreshControl?.endRefreshing()
                updateControls()
            }
            return
        }
        cancelRestore(requestID)
    }

    private func currentRestore(_ id: UUID, phase: RestorePhase) -> Bool {
        restorePhase == phase && !restoreInvalidated && !Task.isCancelled && currentContext(id)
    }

    private func currentContext(_ id: UUID) -> Bool {
        guard requestID == id, visible, let context,
            context.isAttached(to: self, allowing: restorePresentation), screen.matchesConfiguration(context.configuration)
        else { return false }
        if task == nil, [.uploadPassword, .password, .confirming].contains(restorePhase) {
            if restorePhase == .uploadPassword, passwordHandle?.isConsuming == true { return true }
            guard let presentation = restorePresentation, presentation.presentingViewController != nil,
                presentation.isBeingPresented || presentation.viewIfLoaded?.window === context.window
            else { return false }
        }
        return true
    }

    private func captureContext() -> CloudBackupScreenContext? {
        do { return CloudBackupScreenContext(owner: self, configuration: try screen.configuration()) } catch {
            failure = error.userFacingMessage
            tableView.reloadData()
            return nil
        }
    }

    private func monitorContext(_ id: UUID) {
        contextMonitor?.cancel()
        contextMonitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.requestID == id else { return }
                if !self.currentContext(id) {
                    self.invalidateContext()
                    return
                }
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
            }
        }
    }

    private var canUseCloudScreen: Bool {
        visible && canPerformNavigationAction && AppLockManager.shared.isUnlocked(in: viewIfLoaded?.window)
    }

    private func dismissRestorePresentation(_ controller: UIViewController) async {
        let presenter = controller.presentingViewController
        while controller.isBeingPresented || controller.presentedViewController != nil {
            if let presenter, controller.presentingViewController !== presenter { return }
            await waitForPresentationTransition()
        }
        if let presenter, controller.presentingViewController !== presenter { return }
        if let actualPresenter = controller.presentingViewController,
            actualPresenter.presentedViewController === controller, !controller.isBeingDismissed
        {
            await withCheckedContinuation { continuation in
                controller.dismiss(animated: true) { continuation.resume() }
            }
        }
        // A cancellation must not let an action escape an in-flight UIKit dismissal.
        while controller.isBeingDismissed || controller.presentingViewController != nil {
            if let presenter, let actualPresenter = controller.presentingViewController, actualPresenter !== presenter { return }
            await waitForPresentationTransition()
        }
        if restorePresentation === controller { restorePresentation = nil }
    }

    private func waitForPresentationTransition() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { continuation.resume() }
        }
    }

    private func progressAlert(_ title: String, cancellable: Bool, id: UUID) -> UIAlertController {
        let hud = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        hud.view.accessibilityIdentifier = "backup.cloud.processing"
        if cancellable {
            hud.addAction(
                UIAlertAction(title: L10n.Common.cancel, style: .cancel) { [weak self, weak hud] _ in
                    guard let self, let hud, self.restorePresentation === hud, self.currentRestore(id, phase: .uploading) else { return }
                    self.cancelRestore(id, userInitiated: true)
                })
        }
        return hud
    }

    private func showResult(_ message: String) {
        let id = requestID
        guard currentContext(id), canUseCloudScreen else { return }
        showTransientMessage(message, duration: 6)
        if task == nil { reloadBackups() }
    }
}

@MainActor
private final class CloudBackupScreenContext {
    weak var owner: UIViewController?
    weak var window: UIWindow?
    weak var scene: UIWindowScene?
    private weak var root: UIViewController?
    private weak var navigation: UINavigationController?
    private weak var top: UIViewController?
    private weak var boundPresentation: UIViewController?
    private weak var presenter: UIViewController?
    let configuration: AutomaticBackupConfiguration
    var invalidated = false

    init(owner: UIViewController, configuration: AutomaticBackupConfiguration) {
        self.owner = owner
        window = owner.viewIfLoaded?.window
        scene = window?.windowScene
        root = window?.rootViewController
        navigation = owner.navigationController
        top = navigation?.topViewController
        self.configuration = configuration
    }

    func isAttached(to owner: UIViewController, allowing presentation: UIViewController?) -> Bool {
        guard !invalidated, self.owner === owner, let window, let scene, let root, let navigation, let top,
            owner.viewIfLoaded?.window === window, window.windowScene === scene, window.rootViewController === root,
            owner.navigationController === navigation, navigation.topViewController === top, top === owner,
            owner.isVisibleInNavigationStack,
            window.isKeyWindow, !window.isHidden, window.alpha > 0,
            window.isUserInteractionEnabled, !window.accessibilityElementsHidden,
            UIApplication.shared.applicationState == .active, scene.activationState == .foregroundActive,
            AppLockManager.shared.isUnlocked(in: window)
        else { return false }
        if let presentation, let actualPresenter = presentation.presentingViewController {
            if boundPresentation !== presentation {
                boundPresentation = presentation
                presenter = actualPresenter
            }
            guard presenter === actualPresenter, actualPresenter.presentedViewController === presentation,
                presentation.presentedViewController == nil
            else { return false }
        }
        var ownsPresentation = presentation?.presentingViewController == nil
        var candidate: UIViewController? = owner
        while let controller = candidate {
            guard !controller.isBeingDismissed, !controller.isBeingPresented,
                !controller.isMovingFromParent, !controller.isMovingToParent,
                controller.viewIfLoaded?.window === window,
                controller.viewIfLoaded?.isHidden == false, (controller.viewIfLoaded?.alpha ?? 0) > 0
            else { return false }
            if let presented = controller.presentedViewController,
                presented !== presentation || presented.presentedViewController != nil
            {
                return false
            }
            if let transition = controller.transitionCoordinator,
                transition.viewController(forKey: .from) !== presentation,
                transition.viewController(forKey: .to) !== presentation
            {
                return false
            }
            if controller === presentation?.presentingViewController { ownsPresentation = true }
            candidate = controller.parent
        }
        return ownsPresentation
    }
}
