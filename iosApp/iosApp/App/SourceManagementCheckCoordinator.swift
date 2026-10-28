import UIKit
import shared

/// Owns the keyword confirmation and commands; the shared runtime owns the running check.
@MainActor
final class SourceManagementCheckCoordinator: NSObject {
    private final class PresentationContext {
        let revision: UUID
        weak var window: UIWindow?
        weak var scene: UIWindowScene?

        init(revision: UUID, window: UIWindow) {
            self.revision = revision
            self.window = window
            scene = window.windowScene
        }
    }

    private final class Confirmation {
        let sourceURLs: [String]
        let context: PresentationContext
        let isCurrent: () -> Bool
        weak var alert: UIAlertController?
        var isConfirming = false
        var wasAttached = false

        init(sourceURLs: [String], context: PresentationContext, isCurrent: @escaping () -> Bool) {
            self.sourceURLs = sourceURLs
            self.context = context
            self.isCurrent = isCurrent
        }
    }

    private enum Command { case pause, resume, cancel }

    private weak var presenter: UIViewController?
    private let screen: SourceManagementScreenAdapter
    private let canStart: () -> Bool
    private let onStatusChange: (Bool, String) -> Void
    private let onMessage: (String) -> Void
    private let settingsStore = SourceCheckSettingsStore()
    private var confirmation: Confirmation?
    private var commandTask: Task<Void, Never>?
    private var presentationRevision = UUID()
    private var pageActive = false
    private var state: ServiceState?
    private var progressContext: PresentationContext?
    private(set) var controlRevision = UUID()

    var isChecking: Bool { state?.isRunning == true || state?.isPaused == true }

    init(
        presenter: UIViewController, screen: SourceManagementScreenAdapter,
        canStart: @escaping () -> Bool, onStatusChange: @escaping (Bool, String) -> Void,
        onMessage: @escaping (String) -> Void
    ) {
        self.presenter = presenter
        self.screen = screen
        self.canStart = canStart
        self.onStatusChange = onStatusChange
        self.onMessage = onMessage
        super.init()
        for name in [
            UIApplication.willResignActiveNotification, UIApplication.didBecomeActiveNotification,
            UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification, UIScene.didActivateNotification,
            UIWindow.didResignKeyNotification, UIWindow.didBecomeKeyNotification,
        ] {
            NotificationCenter.default.addObserver(self, selector: #selector(activationChanged(_:)), name: name, object: nil)
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func pageDidAppear() {
        pageActive = true
        refreshStatus()
    }

    func pageWillDisappear() {
        pageActive = false
        invalidatePresentation()
    }

    func refreshPresentation() {
        refreshStatus()
    }

    func confirm(sourceURLs: [String], isCurrent: @escaping () -> Bool) {
        invalidateConfirmationIfNeeded()
        guard commandTask == nil, confirmation == nil, !isChecking, canStart(), isCurrent(),
            let context = captureContext(), let presenter
        else { return }
        var seen = Set<String>()
        let urls = sourceURLs.filter { seen.insert($0).inserted }
        guard !urls.isEmpty else {
            onMessage("没有可校验的书源")
            return
        }
        let request = Confirmation(sourceURLs: urls, context: context, isCurrent: isCurrent)
        let alert = UIAlertController(title: "搜索书名、作者", message: nil, preferredStyle: .alert)
        let lifetimeView = SourceManagementCheckAlertLifetimeView(frame: .zero)
        lifetimeView.onAttach = { request.wasAttached = true }
        lifetimeView.onDetach = { [weak self] in
            guard let self, self.confirmation === request, !request.isConfirming else { return }
            self.confirmation = nil
        }
        alert.view.addSubview(lifetimeView)
        alert.addTextField { [settingsStore] field in
            field.placeholder = "search word"
            field.text = settingsStore.keyword
            field.clearButtonMode = .whileEditing
            field.returnKeyType = .done
            field.accessibilityIdentifier = "sourceManagement.check.keyword"
        }
        alert.addAction(
            UIAlertAction(title: L10n.Common.cancel, style: .cancel) { [weak self] _ in
                guard self?.confirmation === request else { return }
                self?.confirmation = nil
            })
        alert.addAction(
            UIAlertAction(title: L10n.Common.confirm, style: .default) { [weak self] _ in
                self?.accept(request)
            })
        request.alert = alert
        confirmation = request
        // Use the host's present override so list input and diffable delivery remain staged.
        presenter.present(alert, animated: true)
        if presenter.presentedViewController !== alert { confirmation = nil }
    }

    func invalidateConfirmationIfNeeded() {
        guard let request = confirmation else { return }
        let ownsAlert = request.alert.map { presenter?.presentedViewController === $0 } == true
        if !request.isCurrent() || (!request.isConfirming && !ownsAlert) { discardConfirmation() }
    }

    func receive(_ state: ServiceState) {
        let wasChecking = isChecking
        if self.state?.isRunning != state.isRunning || self.state?.isPaused != state.isPaused {
            controlRevision = UUID()
        }
        self.state = state
        if isChecking { discardConfirmation() }
        let message = state.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !isChecking, wasChecking, let context = progressContext, isCurrent(context), canStart(), !message.isEmpty {
            onMessage(message)
        }
        refreshStatus()
    }

    func controlMenuItems() -> [ReaderOverflowMenuView.Item] {
        guard isChecking else { return [] }
        let revision = controlRevision
        let paused = state?.isPaused == true
        return [
            .init(
                identifier: "sourceManagement.check.pause",
                title: paused ? L10n.SourceManagement.verifyResume : L10n.SourceManagement.verifyPause,
                isEnabled: commandTask == nil
            ) { [weak self] in self?.perform(paused ? .resume : .pause, revision: revision) },
            .init(
                identifier: "sourceManagement.check.cancel", title: L10n.SourceManagement.verifyCancel,
                isEnabled: commandTask == nil
            ) { [weak self] in self?.perform(.cancel, revision: revision) },
        ]
    }

    private func accept(_ request: Confirmation) {
        guard confirmation === request, !request.isConfirming else { return }
        guard commandTask == nil, !isChecking, request.wasAttached,
            let alert = request.alert,
            isCurrent(request.context, allowing: alert) || isCurrent(request.context), request.isCurrent()
        else {
            discardConfirmation()
            return
        }
        request.isConfirming = true
        let keyword = alert.textFields?.first?.text ?? ""
        let launch = { [weak self] in
            guard let self, self.confirmation === request else { return }
            guard self.isCurrent(request.context), self.canStart(), request.isCurrent(),
                self.commandTask == nil, !self.isChecking
            else {
                self.discardConfirmation()
                return
            }
            self.start(request, keyword: keyword)
        }
        // UIKit may deliver the action before or after its automatic alert dismissal.
        if alert.presentingViewController != nil {
            alert.dismiss(animated: true, completion: launch)
        } else {
            DispatchQueue.main.async(execute: launch)
        }
    }

    private func start(_ request: Confirmation, keyword: String) {
        controlRevision = UUID()
        commandTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.commandTask = nil
                self.controlRevision = UUID()
            }
            guard self.confirmation === request, self.isCurrent(request.context), self.canStart(),
                request.isCurrent(), !self.isChecking
            else {
                self.discardConfirmation()
                return
            }
            self.confirmation = nil
            // Match CheckSource.keyword: an empty confirmation retains the original search word.
            if !keyword.isEmpty { self.settingsStore.keyword = keyword }
            let config = self.settingsStore.load().makeConfig(keyword: self.settingsStore.keyword)
            do {
                try await self.screen.startSourceCheck(sourceURLs: request.sourceURLs, config: config)
            } catch {
                if self.isCurrent(request.context), self.canStart() { self.onMessage(error.userFacingMessage) }
            }
        }
    }

    private func perform(_ command: Command, revision: UUID) {
        guard revision == controlRevision, isChecking, commandTask == nil, canStart(), let context = captureContext()
        else { return }
        controlRevision = UUID()
        let commandRevision = controlRevision
        commandTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.commandTask = nil
                self.controlRevision = UUID()
            }
            guard self.isCurrent(context), self.canStart(), self.controlRevision == commandRevision, self.isChecking
            else { return }
            do {
                switch command {
                case .pause: try await self.screen.pauseSourceCheck()
                case .resume: try await self.screen.resumeSourceCheck()
                case .cancel: try await self.screen.cancelSourceCheck()
                }
            } catch {
                if self.isCurrent(context), self.canStart() { self.onMessage(error.userFacingMessage) }
            }
        }
    }

    private func refreshStatus() {
        guard let context = captureContext() else { return }
        progressContext = isChecking ? context : nil
        let message = state?.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallback = state?.isPaused == true ? L10n.SourceManagement.verifyPaused : L10n.SourceManagement.verifyRunning
        onStatusChange(isChecking, message.isEmpty ? fallback : message)
    }

    private func captureContext() -> PresentationContext? {
        guard let window = presenter?.viewIfLoaded?.window else { return nil }
        let context = PresentationContext(revision: presentationRevision, window: window)
        return isCurrent(context) ? context : nil
    }

    private func isCurrent(_ context: PresentationContext, allowing alert: UIAlertController? = nil) -> Bool {
        guard pageActive, context.revision == presentationRevision, let presenter,
            !presenter.isMovingFromParent, !presenter.isBeingDismissed,
            presenter.navigationController?.topViewController === presenter,
            presenter.navigationController?.isBeingDismissed != true,
            presenter.navigationController?.transitionCoordinator == nil,
            UIApplication.shared.applicationState == .active,
            let window = context.window, presenter.viewIfLoaded?.window === window,
            window.isKeyWindow, !window.isHidden, window.alpha > 0.01,
            let scene = context.scene, window.windowScene === scene, scene.activationState == .foregroundActive
        else { return false }
        if let presented = presenter.presentedViewController {
            return alert === presented && presented.presentingViewController === presenter
                && presented.viewIfLoaded?.window === window
        }
        return alert == nil
    }

    private func discardConfirmation() {
        let alert = confirmation?.alert
        confirmation = nil
        if let alert, presenter?.presentedViewController === alert { alert.dismiss(animated: false) }
    }

    private func invalidatePresentation() {
        presentationRevision = UUID()
        controlRevision = UUID()
        progressContext = nil
        discardConfirmation()
    }

    @objc private func activationChanged(_ notification: Notification) {
        switch notification.name {
        case UIApplication.willResignActiveNotification:
            invalidatePresentation()
            return
        case UIApplication.didBecomeActiveNotification:
            break
        case UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification, UIScene.didActivateNotification:
            guard let scene = notification.object as? UIScene, scene === presenter?.viewIfLoaded?.window?.windowScene else { return }
            if notification.name != UIScene.didActivateNotification {
                invalidatePresentation()
                return
            }
        case UIWindow.didResignKeyNotification, UIWindow.didBecomeKeyNotification:
            guard let window = notification.object as? UIWindow, window === presenter?.viewIfLoaded?.window else { return }
            if notification.name == UIWindow.didResignKeyNotification {
                invalidatePresentation()
                return
            }
        default:
            return
        }
        refreshStatus()
    }
}

@MainActor
private final class SourceManagementCheckAlertLifetimeView: UIView {
    var onAttach: (() -> Void)?
    var onDetach: (() -> Void)?
    private var wasAttached = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        if window != nil {
            wasAttached = true
            onAttach?()
        } else if wasAttached {
            wasAttached = false
            let callback = onDetach
            onAttach = nil
            onDetach = nil
            DispatchQueue.main.async { callback?() }
            removeFromSuperview()
        }
    }
}
