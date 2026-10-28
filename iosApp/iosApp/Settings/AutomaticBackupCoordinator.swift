import UIKit
import shared

/// Opportunistic work, never a resident timer. The startup recovery check always has priority.
@MainActor
final class AutomaticBackupCoordinator {
    static let shared = AutomaticBackupCoordinator()
    static let statusDidChange = Notification.Name("AutomaticBackupCoordinator.statusDidChange")

    enum PasswordMode: Equatable { case missing, session, device }

    private let vault = AutomaticBackupPasswordVault()
    private var engine: AutomaticBackupEngine?
    private var observation: FlowSubscription?
    private var configuration: AutomaticBackupConfiguration?
    private var operation: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var operationID = UUID()
    private var pendingTrigger = false
    private var startupToken: UUID?
    private var startupConfiguration: AutomaticBackupConfiguration?
    private var startupAllowed = false
    private var unlocked = false
    private var foreground = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private(set) var lastResult: AutomaticBackupResult?
    private(set) var status = "等待解锁及启动备份检查"
    var isRunning: Bool { operation != nil }
    /// Main may restart CloudBackupStartupCoordinator when settings invalidate an earlier check.
    var onStartupCheckRequired: (() -> Void)?

    deinit {
        operation?.cancel()
        retry?.cancel()
        observation?.cancel()
    }

    func appDidUnlock() {
        unlocked = true
        foreground = true
        do { _ = try resolve() } catch { publish("自动备份服务暂不可用"); return }
        trigger()
    }

    /// Call BEFORE checkNewBackup, including a retry. It cancels any automatic work immediately.
    @discardableResult
    func startupBackupCheckWillBegin() -> UUID {
        cancelOperation()
        startupAllowed = false
        let token = UUID()
        startupToken = token
        startupConfiguration = try? currentConfiguration()
        publish("正在检查较新的云端备份")
        return token
    }

    /// A new-backup prompt is not finished until its user decision/restore has finished, not when shown.
    func startupBackupCheckDidFinish(_ token: UUID, allowAutomaticBackup: Bool) {
        guard startupToken == token, let checked = startupConfiguration,
            let current = try? currentConfiguration(), checked.matchesConfiguration(other: current)
        else { return }
        startupToken = nil
        startupConfiguration = nil
        startupAllowed = allowAutomaticBackup
        if allowAutomaticBackup { trigger() } else { publish("启动恢复检查未完成，自动备份暂缓") }
    }

    /// Main calls only after the reader's local progress persistence has completed.
    func readerDidLeave() { trigger() }

    /// Android's five-minute reading opportunity, invoked after the corresponding saved checkpoint.
    func readerDidSaveCheckpoint() { trigger() }

    func appDidEnterBackground() {
        foreground = false
        retry?.cancel()
        retry = nil
        guard unlocked, startupAllowed else { return }
        beginBackgroundWindow()
        guard backgroundTask != .invalid else {
            cancelOperation()
            publish("后台执行机会不可用，等待下次解锁")
            return
        }
        if operation == nil { trigger(allowBackground: true) }
        if operation == nil { endBackgroundWindow() }
    }

    func suspendForLock() {
        unlocked = false
        foreground = false
        vault.clearSession()
        cancelOperation()
        publish("已暂停，等待解锁")
    }

    func cancel() {
        cancelOperation()
        publish("本次自动备份已取消；下次有效触发可重试")
    }

    func disconnect() {
        suspendForLock()
        observation?.cancel()
        observation = nil
        engine = nil
        configuration = nil
        startupAllowed = false
        startupToken = nil
        startupConfiguration = nil
    }

    func currentConfiguration() throws -> AutomaticBackupConfiguration { try resolve().configuration() }

    func passwordMode() throws -> PasswordMode {
        let plan = try currentConfiguration()
        if try vault.hasRememberedPassword(scope: plan.passwordScope) { return .device }
        return vault.hasSessionPassword(scope: plan.passwordScope) ? .session : .missing
    }

    func authorizePassword(_ password: String, rememberOnDevice: Bool) throws {
        let plan = try currentConfiguration()
        guard plan.isConfigured else { throw configurationError() }
        cancelOperation()
        try vault.authorize(password: password, scope: plan.passwordScope, rememberOnDevice: rememberOnDevice)
        publish(rememberOnDevice ? "备份密码已加密保存到本机" : "备份密码仅用于本次解锁会话")
        trigger()
    }

    func forgetPassword() throws {
        cancelOperation()
        let plan = try currentConfiguration()
        try vault.forget(scope: plan.passwordScope)
        publish("当前备份目标的本机密码已清除")
    }

    func scheduleSnapshot() throws -> AutomaticBackupResult { try resolve().schedule() }

    private func resolve() throws -> AutomaticBackupEngine {
        if let engine { return engine }
        guard case .ready = SharedRuntime.startupState else { throw configurationError() }
        let engine = try BootstrapApiKt.sharedCloudBackupFacade().automaticBackups()
        self.engine = engine
        configuration = try engine.configuration()
        observation = engine.watchConfiguration { [weak self] _ in
            Task { @MainActor [weak self] in self?.configurationChanged() }
        }
        return engine
    }

    private func configurationChanged() {
        guard let engine else { return }
        do {
            let updated = try engine.configuration()
            if let configuration, configuration.matchesConfiguration(other: updated) { return }
            configuration = updated
            invalidateStartupCheck()
            publish("备份目标或策略已变化，等待重新检查云端备份")
            if unlocked, foreground { onStartupCheckRequired?() }
        } catch {
            invalidateStartupCheck()
            publish("备份配置无效，自动备份暂缓")
        }
    }

    private func invalidateStartupCheck() {
        cancelOperation()
        startupAllowed = false
        startupToken = nil
        startupConfiguration = nil
    }

    private func trigger(allowBackground: Bool = false) {
        guard unlocked, startupAllowed, foreground || allowBackground else { return }
        guard operation == nil else { pendingTrigger = true; return }
        retry?.cancel()
        retry = nil
        do {
            let engine = try resolve()
            let plan = try engine.configuration()
            // An observer callback may still be queued when a departure/foreground event arrives.
            if let configuration, !configuration.matchesConfiguration(other: plan) {
                configurationChanged()
                return
            }
            guard plan.isConfigured else { publish("未配置备份路径或完整的 WebDAV 目标"); return }
            let snapshot = try engine.schedule()
            if snapshot.outcome == .notDue || snapshot.outcome == .backingOff {
                lastResult = snapshot
                publish(message(for: snapshot))
                scheduleRetry(at: snapshot.nextAttemptTime)
                return
            }
            let password = try vault.password(scope: plan.passwordScope)
            guard let password else { publish("请在自动备份中设置备份密码"); return }
            let id = UUID()
            operationID = id
            operation = Task { [weak self] in
                guard let self else { return }
                defer {
                    if operationID == id {
                        operation = nil
                        endBackgroundWindow()
                        publish(status)
                        if pendingTrigger { pendingTrigger = false; trigger() }
                    }
                }
                let writer = AutomaticBackupNativeWriter()
                do {
                    let result: AutomaticBackupResult = try await SharedCancellableAsync.value { completion in
                        engine.runRequest(configuration: plan, password: password, writer: writer) { result in
                            completion(result, nil)
                        }
                    }
                    try Task.checkCancellation()
                    guard operationID == id else { return }
                    lastResult = result
                    publish(message(for: result))
                    scheduleRetry(at: result.nextAttemptTime)
                } catch is CancellationError {
                } catch {
                    // Payloads, user passwords and transport errors never enter logs or status strings.
                    if operationID == id { publish("自动备份已停止，可在下次有效触发时重试") }
                }
                writer.cancel()
                await writer.waitUntilFinished()
            }
            publish("自动备份进行中")
        } catch {
            publish("自动备份配置或安全存储暂不可用，请解锁设备后重试")
            endBackgroundWindow()
        }
    }

    private func scheduleRetry(at milliseconds: Int64) {
        guard milliseconds > 0, unlocked, foreground, startupAllowed else { return }
        let seconds = max(1, min(86_401, Double(milliseconds) / 1000 - Date().timeIntervalSince1970))
        retry = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard let self else { return }
                retry = nil
                trigger()
            } catch {}
        }
    }

    private func cancelOperation() {
        pendingTrigger = false
        retry?.cancel()
        retry = nil
        operation?.cancel()
        // Keep the slot until its cancellation continuation drains; new triggers cannot overtake it.
        endBackgroundWindow()
    }

    private func beginBackgroundWindow() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "LegadoAutomaticBackup") { [weak self] in
            Task { @MainActor [weak self] in
                self?.cancelOperation()
                self?.publish("后台执行时间已到，等待下次解锁重试")
            }
        }
    }

    private func endBackgroundWindow() {
        guard backgroundTask != .invalid else { return }
        let identifier = backgroundTask
        backgroundTask = .invalid
        UIApplication.shared.endBackgroundTask(identifier)
    }

    private func message(for result: AutomaticBackupResult) -> String {
        switch result.outcome {
        case .saved: return "自动备份已完成"
        case .alreadyPresent: return "同日同设备云备份已存在，本次未覆盖"
        case .notConfigured: return "未配置备份路径或完整的 WebDAV 目标"
        case .passwordRequired: return "请设置备份密码"
        case .notDue: return "距上次成功备份未超过 24 小时"
        case .backingOff: return "上次备份失败，退避后重试"
        case .busy: return "另一项备份操作正在进行，稍后重试"
        case .cancelled: return "自动备份已取消"
        default: return result.errorMessage ?? "自动备份失败，稍后重试"
        }
    }

    private func publish(_ message: String) {
        status = message
        NotificationCenter.default.post(name: Self.statusDidChange, object: self)
    }

    private func configurationError() -> NSError {
        NSError(
            domain: "io.legado.automaticBackup", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "请先完成启动并配置应用内备份路径或 WebDAV 目标"])
    }
}
