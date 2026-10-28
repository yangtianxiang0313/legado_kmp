import UIKit
import shared

@MainActor
final class ExternalReaderConfigImportCoordinator: NSObject, UIAdaptivePresentationControllerDelegate {
    var onImported: (() -> Void)?
    var isPreparing: Bool { task != nil }

    private weak var owner: UIViewController?
    private weak var expectedWindow: UIWindow?
    private weak var expectedScene: UIWindowScene?
    private weak var expectedRoot: UIViewController?
    private weak var expectedNavigation: UINavigationController?
    private weak var expectedTop: UIViewController?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var download: ReaderPresetTransferDownload?
    private var loading: UIAlertController?
    private var preview: ExternalReaderConfigImportPreviewViewController?
    private var previewNavigation: UINavigationController?
    private var settlingSharedWrite = false
    private var closed = true

    init(owner: UIViewController) {
        self.owner = owner
        expectedWindow = owner.viewIfLoaded?.window
        expectedScene = expectedWindow?.windowScene
        expectedRoot = expectedWindow?.rootViewController
        expectedNavigation = owner.navigationController
        expectedTop = owner.navigationController?.topViewController
        super.init()
        // Only operation-local UIKit lifecycle gates; never subscribe to shared settings/UI flows.
        if let window = expectedWindow {
            NotificationCenter.default.addObserver(
                self, selector: #selector(invalidatePresentation), name: UIWindow.didResignKeyNotification, object: window)
            NotificationCenter.default.addObserver(
                self, selector: #selector(invalidatePresentation), name: .appLockWillCover, object: window)
        }
        if let scene = expectedScene {
            NotificationCenter.default.addObserver(
                self, selector: #selector(invalidatePresentation), name: UIScene.willDeactivateNotification, object: scene)
            NotificationCenter.default.addObserver(
                self, selector: #selector(invalidatePresentation), name: UIScene.didDisconnectNotification, object: scene)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        task?.cancel()
        monitor?.cancel()
        download?.cancel()
    }

    func start(input: ExternalRuleImportInput) {
        begin { [self] in
            switch input {
            case .file(let url):
                return try await ReaderPresetTransferFiles.read(url)
            case .remote(let url):
                let request = ReaderPresetTransferDownload()
                download = request
                return try await request.load(url)
            }
        }
    }

    func start(data: Data) {
        begin { data }
    }

    private func begin(load: @escaping @MainActor () async throws -> Data) {
        guard task == nil, closed, previewNavigation == nil, let owner,
            hasCurrentOwner, owner.canPerformNavigationAction, AppLockManager.shared.isUnlocked(in: expectedWindow)
        else { return }
        closed = false
        let token = UUID()
        generation = token
        let alert = UIAlertController(title: "正在读取阅读配置", message: nil, preferredStyle: .alert)
        alert.view.accessibilityIdentifier = "externalReaderConfigImport.loading"
        alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel) { [weak self] _ in self?.cancel() })
        loading = alert
        owner.present(alert, animated: true)
        startMonitor(token)
        task = Task { [self] in
            do {
                try Task.checkCancellation()
                let data = try await load()
                try checkCurrent(token)
                let parsing = Task.detached(priority: .userInitiated) {
                    try ExternalReaderConfigImportDocument.parse(data)
                }
                let document = try await withTaskCancellationHandler(
                    operation: { try await parsing.value }, onCancel: { parsing.cancel() })
                try checkCurrent(token)
                guard let loading else { throw CancellationError() }
                await Self.dismiss(loading)
                try checkCurrent(token)
                self.loading = nil
                try await waitUntilOwnerReady(token)
                let page = ExternalReaderConfigImportPreviewViewController(document: document)
                let navigation = UINavigationController(rootViewController: page)
                navigation.overrideUserInterfaceStyle = owner.traitCollection.userInterfaceStyle
                page.onCancel = { [weak self] in self?.cancel() }
                page.onClosed = { [weak self] in self?.cancel() }
                page.onConfirm = { [weak self] in self?.confirm(document, token: token) }
                preview = page
                previewNavigation = navigation
                owner.present(navigation, animated: true) { [weak self, weak navigation] in
                    guard let self, self.generation == token else { return }
                    if !self.isCurrent(token) || navigation?.presentingViewController == nil { self.cancel() }
                }
                navigation.presentationController?.delegate = self
                finishTask(token)
            } catch {
                await failLoading(error, token: token)
            }
        }
    }

    private func confirm(_ document: ExternalReaderConfigImportDocument, token: UUID) {
        guard task == nil, isCurrent(token), canUsePreview, let preview else { return }
        preview.setBusy(true)
        task = Task { [self] in
            do {
                // Obtain the facade before creating files. This does not install a settings observer.
                let facade = try SharedRuntime.settingsFacade().get()
                let prepared = try await ReaderPresetTransferFiles.prepare(document.data)
                do {
                    try checkCurrent(token)
                    guard canUsePreview else { throw CancellationError() }
                    settlingSharedWrite = true
                    defer { settlingSharedWrite = false }
                    // Swift cancellation cannot retract Kotlin persistence. Await the actual completion,
                    // even after scene disconnect/cancel, before deciding whether this resource lease is owned.
                    let _: ReaderPreset = try await SharedAsync.value {
                        facade.importAndroidReaderPreset(jsonString: prepared.json, completionHandler: $0)
                    }
                    prepared.commitResources()
                } catch {
                    throw prepared.discardResources(after: error)
                }
                if isCurrent(token), canUsePreview {
                    onImported?()
                    cancel()
                }
                finishTask(token)
            } catch {
                let mayReport = isCurrent(token) && canUsePreview && !(error is CancellationError)
                finishTask(token)
                if mayReport { preview.showFailure(error) }
            }
        }
    }

    func cancel() {
        generation = UUID()
        closed = true
        monitor?.cancel()
        monitor = nil
        download?.cancel()
        download = nil
        if !settlingSharedWrite { task?.cancel() }
        let loading = loading
        let navigation = previewNavigation
        preview?.onConfirm = nil
        preview?.onCancel = nil
        preview?.onClosed = nil
        navigation?.presentationController?.delegate = nil
        self.loading = nil
        preview = nil
        previewNavigation = nil
        Task { @MainActor in
            if let loading { await Self.dismiss(loading) }
            if let navigation { await Self.dismiss(navigation) }
        }
    }

    @objc private func invalidatePresentation() {
        if !closed { cancel() }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard presentationController.presentedViewController === previewNavigation else { return }
        cancel()
    }

    private func startMonitor(_ token: UUID) {
        monitor?.cancel()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.closed, self.generation == token else { return }
                guard self.hasCurrentOwner, self.isForegroundUnlocked else { self.cancel(); return }
                do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
            }
        }
    }

    private var hasCurrentOwner: Bool {
        guard let owner, let window = expectedWindow, let scene = expectedScene,
            let root = expectedRoot, let navigation = expectedNavigation,
            window.rootViewController === root, window.windowScene === scene,
            owner.viewIfLoaded?.window === window, owner.navigationController === navigation,
            navigation.topViewController === expectedTop, owner.isVisibleInNavigationStack,
            !owner.isBeingDismissed, !owner.isMovingFromParent,
            !navigation.isBeingDismissed, !root.isBeingDismissed
        else { return false }
        return true
    }

    private var isForegroundUnlocked: Bool {
        guard let window = expectedWindow else { return false }
        return UIApplication.shared.applicationState == .active && window.isKeyWindow && !window.isHidden
            && window.alpha > 0 && window.isUserInteractionEnabled && !window.accessibilityElementsHidden
            && expectedScene?.activationState == .foregroundActive && AppLockManager.shared.isUnlocked(in: window)
    }

    private func isCurrent(_ token: UUID) -> Bool {
        generation == token && !closed && hasCurrentOwner && isForegroundUnlocked
    }

    private func checkCurrent(_ token: UUID) throws {
        try Task.checkCancellation()
        guard isCurrent(token) else { throw CancellationError() }
    }

    private var canUsePreview: Bool {
        guard let preview, let navigation = previewNavigation,
            let presenter = navigation.presentingViewController, let window = expectedWindow,
            navigation.topViewController === preview, presenter.presentedViewController === navigation,
            preview.viewIfLoaded?.window === window, preview.canPerformNavigationAction,
            !navigation.isBeingPresented, !navigation.isBeingDismissed,
            expectedRoot?.transitionCoordinator == nil, expectedNavigation?.transitionCoordinator == nil
        else { return false }
        return true
    }

    private func waitUntilOwnerReady(_ token: UUID) async throws {
        while true {
            try checkCurrent(token)
            guard let owner else { throw CancellationError() }
            if owner.presentedViewController == nil, owner.canPerformNavigationAction,
                expectedRoot?.transitionCoordinator == nil, expectedNavigation?.transitionCoordinator == nil
            {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func failLoading(_ error: Error, token: UUID) async {
        let alert = loading
        let mayReport = isCurrent(token) && !(error is CancellationError)
        if generation == token {
            loading = nil
            closed = true
            monitor?.cancel()
            monitor = nil
        }
        if let alert { await Self.dismiss(alert) }
        finishTask(token)
        guard mayReport, generation == token, hasCurrentOwner, isForegroundUnlocked,
            owner?.canPerformNavigationAction == true
        else { return }
        owner?.showTransientMessage(error.userFacingMessage)
    }

    private func finishTask(_ token: UUID) {
        // cancel() changes the presentation generation but leaves an in-flight write to settle.
        if generation == token || closed {
            task = nil
            download = nil
        }
    }

    private static func dismiss(_ controller: UIViewController) async {
        if let transition = controller.transitionCoordinator, controller.isBeingPresented || controller.isBeingDismissed {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if !transition.animate(alongsideTransition: nil, completion: { _ in continuation.resume() }) {
                    continuation.resume()
                }
            }
        }
        guard let presenter = controller.presentingViewController, presenter.presentedViewController === controller,
            !controller.isBeingPresented, !controller.isBeingDismissed
        else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            controller.dismiss(animated: true) { continuation.resume() }
        }
    }
}
