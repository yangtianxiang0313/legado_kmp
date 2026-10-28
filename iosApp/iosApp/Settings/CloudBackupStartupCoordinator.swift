import UIKit
import shared

/// Startup only offers recovery; it never restores automatically or interrupts an active reader.
@MainActor
final class CloudBackupStartupCoordinator {
    private let screen = CloudBackupScreenAdapter()
    private weak var window: UIWindow?
    private weak var home: MainTabBarController?
    private var unlocked = false
    private var finished = false
    private var generation = UUID()
    private var task: Task<Void, Never>?

    deinit { task?.cancel() }

    func attach(window: UIWindow, home: MainTabBarController) {
        self.window = window
        self.home = home
        AutomaticBackupCoordinator.shared.onStartupCheckRequired = { [weak self] in
            let canContinue = self?.window.map { AppLockManager.shared.isUnlocked(in: $0) } == true
            self?.suspend()
            self?.finished = false
            self?.unlocked = canContinue
            self?.resume()
        }
        resume()
    }

    func appDidUnlock() { unlocked = true; resume() }

    func suspend() {
        unlocked = false
        generation = UUID()
        task?.cancel()
        task = nil
    }

    func disconnect() { suspend(); finished = true }

    func resume() {
        guard !finished, unlocked, task == nil, let window, home != nil,
            UIApplication.shared.applicationState == .active,
            window.windowScene?.activationState == .foregroundActive
        else { return }
        let id = UUID()
        generation = id
        task = Task { [weak self] in
            guard let self else { return }
            defer { if generation == id { task = nil } }
            let automatic = AutomaticBackupCoordinator.shared
            let token = automatic.startupBackupCheckWillBegin()
            do {
                guard let file = try await screen.checkNewBackup() else {
                    if generation == id {
                        finished = true
                        automatic.startupBackupCheckDidFinish(token, allowAutomaticBackup: true)
                    }
                    return
                }
                while generation == id, !Task.isCancelled {
                    guard let window = self.window, let home = self.home,
                        window.windowScene?.activationState == .foregroundActive,
                        UIApplication.shared.applicationState == .active
                    else { return }
                    if window.isKeyWindow, home.isReadyForStartupNavigation {
                        present(file, from: home, automaticToken: token)
                        return
                    }
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
            } catch is CancellationError {
            } catch {
                automatic.startupBackupCheckDidFinish(token, allowAutomaticBackup: false)
                // A failed startup request is not "no new backup"; retry on the next activation.
                SharedRuntime.log("启动云备份检查失败，请在备份与恢复中重试")
            }
        }
    }

    private func present(_ file: CloudBackupFile, from home: MainTabBarController, automaticToken: UUID) {
        guard !finished, home.isReadyForStartupNavigation else { return }
        let prompt = UIAlertController(
            title: "发现新的云端备份", message: file.name + "\n是否打开恢复？", preferredStyle: .alert)
        prompt.view.accessibilityIdentifier = "backup.cloud.startup"
        prompt.addAction(
            UIAlertAction(title: L10n.Common.cancel, style: .cancel) { _ in
                AutomaticBackupCoordinator.shared.startupBackupCheckDidFinish(automaticToken, allowAutomaticBackup: true)
            })
        prompt.addAction(
            UIAlertAction(title: "恢复", style: .default) { [weak home, weak prompt] _ in
                guard let prompt else { return }
                let open = { [weak home] in
                    DispatchQueue.main.async {
                        guard let home, home.isReadyForStartupNavigation else { return }
                        let page = CloudBackupViewController(initialRestore: file)
                        page.onReturn = {
                            AutomaticBackupCoordinator.shared.startupBackupCheckDidFinish(
                                automaticToken, allowAutomaticBackup: true)
                        }
                        home.navigationController?.pushViewController(page.configuredForDrillDownPresentation(), animated: true)
                    }
                }
                if let transition = prompt.transitionCoordinator {
                    if !transition.animate(alongsideTransition: nil, completion: { _ in open() }) { open() }
                } else {
                    prompt.dismiss(animated: true, completion: open)
                }
            })
        finished = true
        home.present(prompt, animated: true) { [weak self, weak prompt] in
            guard prompt?.presentingViewController != nil else { return }
            Task { [weak self] in try? await self?.screen.acknowledge(file) }
        }
    }
}
