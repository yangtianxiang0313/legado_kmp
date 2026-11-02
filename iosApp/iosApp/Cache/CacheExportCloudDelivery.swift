import UIKit
import shared

@MainActor
final class CacheExportCloudDelivery {
    struct Outcome {
        var uploaded: [String: Int] = [:]
        var skipped: [String: Int] = [:]
        var uncertain: Set<String> = []
        var errors: [String: String] = [:]
        var cancelled = false

        var summary: String {
            let count = uploaded.values.reduce(0, +)
            let warning = uncertain.isEmpty ? "" : "，部分状态不确定，请检查云端"
            return "WebDAV 已上传 \(count) 个文件\(warning)"
        }

        func message(for item: CacheExportSharing.Item) -> String {
            let count = uploaded[item.bookURL, default: 0]
            var value = "WebDAV 已上传 \(count)/\(item.result.files.count) 个文件"
            if uncertain.contains(item.bookURL) { value += "；部分上传状态不确定，请检查云端" }
            if skipped[item.bookURL, default: 0] > 0 { value += "；已跳过同名文件" }
            if let error = errors[item.bookURL] { value += "；\(error)" }
            if cancelled { value += "；请求已停止" }
            if item.result.isPartial { value += "；\(item.result.missingContentMessage)" }
            return value
        }
    }

    private enum Decision { case proceed, skip, stop }
    private var items: [CacheExportSharing.Item]
    private let failedCount: Int
    private weak var owner: UIViewController?
    private var canContinue: (() -> Bool)?
    private var onFinish: ((Outcome) -> Void)?
    private var job: Task<Void, Never>?
    private var context: CacheExportOwnerContext?
    private var monitor: Task<Void, Never>?
    private var session: BookExportCloudSession?
    private var presentation: CacheExportPresentation?
    private var decision: Decision?
    private var outcome = Outcome()
    private var started = false
    private var cancelled = false
    private var finishing = false
    private var finished = false

    // Passing a session transfers ownership of its captured destination to this single-use delivery.
    init(items: [CacheExportSharing.Item], failedCount: Int, session: BookExportCloudSession? = nil) {
        self.items = items
        self.failedCount = failedCount
        self.session = session
    }

    deinit {
        monitor?.cancel()
        session?.close()
    }

    func present(
        from owner: UIViewController, canContinue: @escaping () -> Bool,
        onFinish: @escaping (Outcome) -> Void
    ) {
        guard !started, !cancelled, !finishing, !finished else { return }
        started = true
        self.owner = owner
        self.canContinue = canContinue
        self.onFinish = onFinish
        context = CacheExportOwnerContext(owner: owner)
        context?.startMonitoring(
            allowing: { [weak self] in self?.presentation?.controller },
            onInvalidated: { [weak self] in self?.cancel() })
        job = Task { @MainActor [self] in await run() }
        monitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                guard let self, !self.finishing, !self.finished else { return }
                guard self.active else {
                    self.cancel()
                    return
                }
                if self.decision == nil, self.presentation?.unexpectedlyDetached == true {
                    self.cancel()
                    return
                }
            }
        }
    }

    func cancel() {
        guard !cancelled, !finishing, !finished else { return }
        cancelled = true
        outcome.cancelled = true
        context?.finish()
        monitor?.cancel()
        // The async bridge waits for the actual upload result, including any accepted remote PUT.
        job?.cancel()
        if let presentation {
            Task { @MainActor in await presentation.dismiss() }
        }
        if !started {
            started = true
            job = Task { @MainActor [self] in await finish() }
        }
    }

    private var active: Bool {
        !cancelled && !finishing && !finished && !Task.isCancelled && canContinue?() == true
            && context?.isCurrent(allowing: presentation?.controller) == true
    }

    private var ready: Bool {
        guard active, context?.isCurrent() == true, let owner else { return false }
        return CacheExportPresentation.canStart(from: owner)
    }

    private func run() async {
        guard active, !items.isEmpty else {
            await finish()
            return
        }
        if let warning = CacheExportSharing.warningMessage(for: items, failedCount: failedCount, verb: "上传") {
            let response = await ask(title: "部分导出", message: warning, conflict: false)
            if response != .proceed { cancel() }
        }
        guard active else {
            await finish()
            return
        }
        do {
            if session == nil {
                let facade = try BookExportCloudFacade.companion.create()
                session = try facade.startSession()
            }
            guard let session else {
                await finish()
                return
            }
            let total = items.reduce(0) { $0 + $1.result.files.count }
            var attempted = 0
            uploadLoop: for item in items {
                guard active else {
                    outcome.cancelled = true
                    break
                }
                guard item.result.uploadPayloads.count == item.result.files.count else {
                    outcome.errors[item.bookURL] = "导出数据已失效，请重新导出"
                    break
                }
                for (index, file) in item.result.files.enumerated() {
                    guard active else {
                        outcome.cancelled = true
                        break uploadLoop
                    }
                    attempted += 1
                    let name = file.url.lastPathComponent
                    guard await showProgress(name: name, current: attempted, total: total), active else {
                        cancel()
                        break uploadLoop
                    }
                    var result = try await CacheExportCloudAsync.upload(
                        session: session, fileName: name, data: item.result.uploadPayloads[index], overwrite: false)
                    if result.conflict && !result.isCancelled && active {
                        let response = await ask(
                            title: "同名文件已存在", message: name, conflict: true)
                        switch response {
                        case .stop:
                            cancel()
                            break uploadLoop
                        case .skip:
                            guard active else {
                                outcome.cancelled = true
                                break uploadLoop
                            }
                            outcome.skipped[item.bookURL, default: 0] += 1
                            continue
                        case .proceed:
                            guard active else {
                                outcome.cancelled = true
                                break uploadLoop
                            }
                            guard await showProgress(name: name, current: attempted, total: total), active else {
                                cancel()
                                break uploadLoop
                            }
                            result = try await CacheExportCloudAsync.upload(
                                session: session, fileName: name, data: item.result.uploadPayloads[index],
                                overwrite: true)
                        }
                    }
                    // Record the settled result before checking UI/cancellation again.
                    if result.success {
                        outcome.uploaded[item.bookURL, default: 0] += 1
                        if result.isCancelled { outcome.cancelled = true }
                        if let message = result.errorMessage {
                            outcome.errors[item.bookURL] = Self.safeMessage(message)
                            break uploadLoop
                        }
                    } else {
                        if result.mayHaveUploaded { outcome.uncertain.insert(item.bookURL) }
                        if result.isCancelled { outcome.cancelled = true }
                        if let message = result.errorMessage {
                            outcome.errors[item.bookURL] = Self.safeMessage(message)
                        } else if !result.isCancelled {
                            outcome.errors[item.bookURL] = Self.safeMessage(nil)
                        }
                        break uploadLoop
                    }
                    if result.isCancelled || !active {
                        outcome.cancelled = true
                        break uploadLoop
                    }
                }
            }
        } catch {
            if error is CancellationError || Task.isCancelled {
                outcome.cancelled = true
            } else {
                let message = Self.safeMessage(error.userFacingMessage)
                for item in items { outcome.errors[item.bookURL] = message }
            }
        }
        await finish()
    }

    private func ask(title: String, message: String, conflict: Bool) async -> Decision {
        await dismissAlert()
        guard ready, let owner else { return .stop }
        let controller = UIAlertController(title: title, message: message, preferredStyle: .alert)
        let request = CacheExportPresentation(controller)
        presentation = request
        decision = nil
        var actions: [(String, UIAlertAction.Style, Decision)] = [
            (conflict ? "停止上传" : "取消", .cancel, .stop)
        ]
        if conflict { actions.append(("跳过", .default, .skip)) }
        actions.append((conflict ? "覆盖" : "上传已完成内容", conflict ? .destructive : .default, .proceed))
        for (title, style, value) in actions {
            controller.addAction(
                UIAlertAction(title: title, style: style) { [weak self, weak request] _ in
                    guard let self, let request, self.presentation === request, self.decision == nil,
                        !self.cancelled, !self.finishing, !self.finished
                    else { return }
                    guard self.active else {
                        self.cancel()
                        return
                    }
                    guard request.canConsumeAction() else { return }
                    self.decision = value
                })
        }
        guard await request.present(from: owner) else {
            cancel()
            await dismissAlert()
            return .stop
        }
        while decision == nil && active {
            if request.unexpectedlyDetached {
                cancel()
                break
            }
            await CacheExportPresentation.pause()
        }
        let response = decision ?? .stop
        await dismissAlert()
        // Even a valid action cannot authorize another PUT after cancellation during dismissal.
        return active ? response : .stop
    }

    private func showProgress(name: String, current: Int, total: Int) async -> Bool {
        await dismissAlert()
        guard ready, let owner else { return false }
        let controller = UIAlertController(
            title: "上传到 WebDAV", message: "\(current)/\(total)\n\(name)", preferredStyle: .alert)
        let request = CacheExportPresentation(controller)
        presentation = request
        decision = nil
        controller.addAction(
            UIAlertAction(title: "停止上传", style: .cancel) { [weak self, weak request] _ in
                guard let self, let request, self.presentation === request,
                    !self.cancelled, !self.finishing, !self.finished
                else { return }
                // Identity, environment and leaf ownership are checked even for old HUD stop actions.
                guard self.active else {
                    self.cancel()
                    return
                }
                guard request.canConsumeAction() else { return }
                self.cancel()
            })
        let shown = await request.present(from: owner)
        return shown && active && !request.unexpectedlyDetached
    }

    private func dismissAlert() async {
        guard let request = presentation else { return }
        await request.dismiss()
        if presentation === request {
            presentation = nil
            decision = nil
        }
    }

    private func finish() async {
        guard !finishing, !finished else { return }
        if !active { outcome.cancelled = true }
        finishing = true
        context?.finish()
        context = nil
        monitor?.cancel()
        monitor = nil
        await dismissAlert()
        // run() reaches here only after every started upload has returned its terminal value.
        session?.close()
        session = nil
        finished = true
        for item in items { item.result.cleanup() }
        items = []
        let callback = onFinish
        onFinish = nil
        canContinue = nil
        job = nil
        callback?(outcome)
    }

    private static func safeMessage(_ message: String?) -> String {
        guard let message, !message.isEmpty, message.count <= 160,
            !message.contains("://"), !message.contains("/"), !message.contains("\\")
        else { return "上传未完成，请检查网络、配置或云端状态后重试" }
        return message
    }
}
