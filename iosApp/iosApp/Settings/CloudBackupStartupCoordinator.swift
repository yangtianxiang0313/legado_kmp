import UIKit
import shared

/// Startup only offers recovery; it never restores automatically or interrupts an active reader.
@MainActor
final class CloudBackupStartupCoordinator: NSObject {
    private enum Phase { case checking, prompting, dismissing, restoring, returning }
    private let screen = CloudBackupScreenAdapter()
    private weak var window: UIWindow?
    private weak var home: MainTabBarController?
    private var unlocked = false
    private var finished = false
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var context: CloudBackupStartupContext?
    private var phase = Phase.checking
    private var automaticToken: UUID?
    private weak var prompt: UIAlertController?
    private weak var promptPresenter: UIViewController?
    private weak var restorePage: CloudBackupViewController?

    deinit {
        task?.cancel()
        monitor?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    func attach(window: UIWindow, home: MainTabBarController) {
        invalidate()
        self.window = window
        self.home = home
        finished = false
        NotificationCenter.default.removeObserver(self)
        for name in [
            UIApplication.willResignActiveNotification, UIScene.willDeactivateNotification,
            UIScene.didDisconnectNotification, UIWindow.didResignKeyNotification, UIWindow.didBecomeHiddenNotification,
            .appLockWillCover, .appLockStatusDidChange,
        ] {
            NotificationCenter.default.addObserver(self, selector: #selector(contextChanged(_:)), name: name, object: nil)
        }
        AutomaticBackupCoordinator.shared.onStartupCheckRequired = { [weak self] in
            guard let self else { return }
            let canContinue = self.window.map { AppLockManager.shared.isUnlocked(in: $0) } == true
            self.invalidate()
            self.finished = false
            self.unlocked = canContinue
            self.resume()
        }
        resume()
    }

    func appDidUnlock() {
        unlocked = true
        resume()
    }

    func suspend() {
        unlocked = false
        invalidate()
    }

    func disconnect() {
        suspend()
        finished = true
    }

    func resume() {
        guard !finished, unlocked, task == nil, context == nil, let window, let home,
            UIApplication.shared.applicationState == .active,
            window.windowScene?.activationState == .foregroundActive,
            window.isKeyWindow, !window.isHidden, AppLockManager.shared.isUnlocked(in: window),
            let configuration = try? screen.configuration(),
            let context = CloudBackupStartupContext(window: window, home: home, configuration: configuration)
        else { return }
        let id = UUID()
        generation = id
        self.context = context
        phase = .checking
        let automatic = AutomaticBackupCoordinator.shared
        let token = automatic.startupBackupCheckWillBegin()
        automaticToken = token
        monitorContext(id)
        task = Task { [weak self] in
            guard let self else { return }
            defer { if generation == id { task = nil } }
            do {
                guard current(id) else {
                    invalidateIfCurrent(id)
                    return
                }
                guard let file = try await screen.checkNewBackup(configuration: context.configuration) else {
                    finish(id, token: token)
                    return
                }
                while !Task.isCancelled {
                    guard current(id) else {
                        invalidateIfCurrent(id)
                        return
                    }
                    if window.isKeyWindow, home.isReadyForStartupNavigation {
                        present(file, from: home, id: id, token: token)
                        return
                    }
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
            } catch is CancellationError {
                invalidateIfCurrent(id)
            } catch {
                guard generation == id else { return }
                invalidate()
                // A failed startup request is not "no new backup"; retry on the next activation.
                SharedRuntime.log(
                    NSLocalizedString(
                        "backup.cloud.startup.failed", value: "启动云备份检查失败，请在备份与恢复中重试", comment: "Startup backup check failed"))
            }
        }
    }

    private func present(_ file: CloudBackupFile, from home: MainTabBarController, id: UUID, token: UUID) {
        guard current(id), !finished, home.isReadyForStartupNavigation else {
            invalidateIfCurrent(id)
            return
        }
        let prompt = UIAlertController(
            title: NSLocalizedString("backup.cloud.startup.title", value: "发现新的云端备份", comment: "New cloud backup found"),
            message: String(
                format: NSLocalizedString(
                    "backup.cloud.startup.message", value: "%@\n是否打开恢复？", comment: "Offer to open cloud backup restore"), file.name),
            preferredStyle: .alert)
        prompt.view.accessibilityIdentifier = "backup.cloud.startup"
        prompt.addAction(
            UIAlertAction(title: L10n.Common.cancel, style: .cancel) { [weak self, weak prompt] _ in
                self?.decide(file, prompt: prompt, id: id, token: token, restoring: false)
            })
        prompt.addAction(
            UIAlertAction(
                title: NSLocalizedString("backup.cloud.restore.action", value: "恢复", comment: "Restore backup action"), style: .default
            ) { [weak self, weak prompt] _ in
                self?.decide(file, prompt: prompt, id: id, token: token, restoring: true)
            })
        self.prompt = prompt
        phase = .prompting
        finished = true
        home.present(prompt, animated: true) { [weak self, weak prompt] in
            guard let self, let prompt, self.prompt === prompt, self.current(id), self.phase == .prompting,
                prompt.presentingViewController != nil, let context = self.context
            else { return }
            Task { [weak self] in
                guard let self, self.current(id), self.phase == .prompting else { return }
                try? await self.screen.acknowledge(file, configuration: context.configuration)
            }
        }
        promptPresenter = prompt.presentingViewController
    }

    private func decide(_ file: CloudBackupFile, prompt: UIAlertController?, id: UUID, token: UUID, restoring: Bool) {
        guard generation == id, phase == .prompting else { return }
        guard let prompt, self.prompt === prompt, phase == .prompting, current(id) else {
            invalidateIfCurrent(id)
            return
        }
        phase = .dismissing
        task = Task { [weak self] in
            guard let self else { return }
            defer { if generation == id { task = nil } }
            await CloudBackupStartupContext.dismiss(prompt)
            guard current(id), phase == .dismissing, let context, let home = context.home,
                home.isReadyForStartupNavigation, let navigation = context.navigation
            else {
                invalidateIfCurrent(id)
                return
            }
            self.prompt = nil
            if !restoring {
                finish(id, token: token)
                return
            }
            let page = CloudBackupViewController(initialRestore: file, configuration: context.configuration)
            restorePage = page
            page.onReturn = { [weak self, weak page] in
                guard let self, let page, self.restorePage === page, self.phase == .restoring, self.current(id) else {
                    self?.invalidateIfCurrent(id)
                    return
                }
                self.returned(id, token: token)
            }
            phase = .restoring
            navigation.pushViewController(page.configuredForDrillDownPresentation(), animated: true)
        }
    }

    private func returned(_ id: UUID, token: UUID) {
        phase = .returning
        task = Task { [weak self] in
            guard let self else { return }
            defer { if generation == id { task = nil } }
            while current(id), let navigation = context?.navigation, navigation.transitionCoordinator != nil {
                do { try await Task.sleep(nanoseconds: 10_000_000) } catch { return }
            }
            guard current(id), context?.home?.isReadyForStartupNavigation == true else {
                invalidateIfCurrent(id)
                return
            }
            finish(id, token: token)
        }
    }

    private func finish(_ id: UUID, token: UUID) {
        guard current(id), automaticToken == token else {
            invalidateIfCurrent(id)
            return
        }
        automaticToken = nil
        context = nil
        restorePage = nil
        prompt = nil
        monitor?.cancel()
        monitor = nil
        finished = true
        AutomaticBackupCoordinator.shared.startupBackupCheckDidFinish(token, allowAutomaticBackup: true)
    }

    private func current(_ id: UUID) -> Bool {
        let allowedPresentation =
            phase == .restoring
            ? (restorePage?.presentedViewController ?? context?.navigation?.presentedViewController) as? UIAlertController
            : prompt
        guard generation == id, unlocked, let context, context.window === window, context.home === home,
            context.isAttached(allowing: allowedPresentation), screen.matchesConfiguration(context.configuration)
        else { return false }
        switch phase {
        case .checking: return true
        case .prompting:
            guard let prompt, let promptPresenter, prompt.presentingViewController === promptPresenter,
                promptPresenter.presentedViewController === prompt,
                prompt.isBeingPresented || prompt.viewIfLoaded?.window === context.window
            else { return false }
            return context.navigation?.topViewController === context.home
        case .dismissing:
            if let actualPresenter = prompt?.presentingViewController, actualPresenter !== promptPresenter { return false }
            return context.navigation?.topViewController === context.home
        case .returning: return context.navigation?.topViewController === context.home
        case .restoring:
            guard let page = restorePage, let navigation = context.navigation else { return false }
            if navigation.topViewController === page { return page.navigationController === navigation }
            return navigation.topViewController === context.home
                && (navigation.transitionCoordinator != nil || page.isMovingFromParent || page.parent == nil)
        }
    }

    private func monitorContext(_ id: UUID) {
        monitor?.cancel()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == id else { return }
                if !self.current(id) {
                    self.invalidateIfCurrent(id)
                    return
                }
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
            }
        }
    }

    @objc private func contextChanged(_ notification: Notification) {
        let window = context?.window ?? self.window
        if let scene = notification.object as? UIScene, scene !== window?.windowScene { return }
        if let other = notification.object as? UIWindow, other !== window { return }
        if notification.name == .appLockStatusDidChange, AppLockManager.shared.isUnlocked(in: window) { return }
        if notification.name == .appLockWillCover || notification.name == .appLockStatusDidChange { unlocked = false }
        invalidate()
    }

    private func invalidateIfCurrent(_ id: UUID) { if generation == id { invalidate() } }

    private func invalidate() {
        let oldPrompt = prompt
        let token = automaticToken
        if context != nil { finished = false }
        generation = UUID()
        task?.cancel()
        task = nil
        monitor?.cancel()
        monitor = nil
        automaticToken = nil
        context = nil
        prompt = nil
        promptPresenter = nil
        restorePage = nil
        if let token { AutomaticBackupCoordinator.shared.startupBackupCheckDidFinish(token, allowAutomaticBackup: false) }
        if let oldPrompt { Task { await CloudBackupStartupContext.dismiss(oldPrompt) } }
    }
}

@MainActor
private final class CloudBackupStartupContext {
    weak var window: UIWindow?
    weak var scene: UIWindowScene?
    weak var root: UIViewController?
    weak var home: MainTabBarController?
    weak var navigation: UINavigationController?
    let configuration: AutomaticBackupConfiguration

    init?(window: UIWindow, home: MainTabBarController, configuration: AutomaticBackupConfiguration) {
        guard let scene = window.windowScene, let root = window.rootViewController, let navigation = home.navigationController else {
            return nil
        }
        self.window = window
        self.scene = scene
        self.root = root
        self.home = home
        self.navigation = navigation
        self.configuration = configuration
    }

    func isAttached(allowing prompt: UIAlertController?) -> Bool {
        guard let window, let scene, let root, let home, let navigation,
            window.windowScene === scene, window.rootViewController === root,
            home.navigationController === navigation, navigation.viewControllers.contains(where: { $0 === home }),
            navigation.viewIfLoaded?.window === window, root.viewIfLoaded?.window === window,
            !root.isBeingDismissed, !navigation.isBeingDismissed, !home.isBeingDismissed,
            window.isKeyWindow, !window.isHidden, window.alpha > 0,
            window.isUserInteractionEnabled, !window.accessibilityElementsHidden,
            UIApplication.shared.applicationState == .active, scene.activationState == .foregroundActive,
            AppLockManager.shared.isUnlocked(in: window)
        else { return false }
        for controller in [home, navigation, root] {
            if let presented = controller.presentedViewController,
                presented !== prompt || presented.presentedViewController != nil
            {
                return false
            }
        }
        return true
    }

    static func dismiss(_ controller: UIAlertController) async {
        let presenter = controller.presentingViewController
        while controller.isBeingPresented || controller.presentedViewController != nil {
            if let presenter, controller.presentingViewController !== presenter { return }
            await waitForTransition()
        }
        if let presenter, controller.presentingViewController !== presenter { return }
        if let actualPresenter = controller.presentingViewController,
            actualPresenter.presentedViewController === controller, !controller.isBeingDismissed
        {
            await withCheckedContinuation { continuation in
                controller.dismiss(animated: true) { continuation.resume() }
            }
        }
        while controller.isBeingDismissed || controller.presentingViewController != nil {
            if let presenter, let actualPresenter = controller.presentingViewController, actualPresenter !== presenter { return }
            await waitForTransition()
        }
    }

    private static func waitForTransition() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { continuation.resume() }
        }
    }
}
