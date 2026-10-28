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
    private var alert: UIAlertController?
    private var decision: CheckedContinuation<Decision, Never>?
    private var outcome = Outcome()
    private var cancelled = false
    private var finished = false

    init(items: [CacheExportSharing.Item], failedCount: Int) {
        self.items = items
        self.failedCount = failedCount
    }

    func present(
        from owner: UIViewController, canContinue: @escaping () -> Bool,
        onFinish: @escaping (Outcome) -> Void
    ) {
        guard job == nil, !finished else { return }
        self.owner = owner
        self.canContinue = canContinue
        self.onFinish = onFinish
        job = Task { @MainActor [self] in await run() }
    }

    func cancel() {
        guard !cancelled, !finished else { return }
        cancelled = true
        outcome.cancelled = true
        decision?.resume(returning: .stop)
        decision = nil
        job?.cancel()
        alert?.dismiss(animated: true)
    }

    private var active: Bool {
        !cancelled && !Task.isCancelled && canContinue?() == true && owner?.viewIfLoaded?.window != nil
    }

    private func run() async {
        if let warning = CacheExportSharing.warningMessage(for: items, failedCount: failedCount, verb: "上传") {
            let response = await ask(title: "部分导出", message: warning, conflict: false)
            if response != .proceed { cancel() }
        }
        guard active else { await finish(); return }
        do {
            let facade = try BookExportCloudFacade.companion.create()
            let session = try facade.startSession()
            defer { session.close() }
            let total = items.reduce(0) { $0 + $1.result.files.count }
            var attempted = 0
            uploadLoop: for item in items {
                guard active else { outcome.cancelled = true; break }
                guard item.result.uploadPayloads.count == item.result.files.count else {
                    outcome.errors[item.bookURL] = "导出数据已失效，请重新导出"
                    break
                }
                for (index, file) in item.result.files.enumerated() {
                    guard active else { outcome.cancelled = true; break uploadLoop }
                    attempted += 1
                    let name = file.url.lastPathComponent
                    await showProgress(name: name, current: attempted, total: total)
                    guard active else { outcome.cancelled = true; break uploadLoop }
                    var result = try await CacheExportCloudAsync.upload(
                        session: session, fileName: name, data: item.result.uploadPayloads[index], overwrite: false)
                    if result.conflict && active {
                        let response = await ask(
                            title: "同名文件已存在", message: name, conflict: true)
                        switch response {
                        case .stop: cancel(); break uploadLoop
                        case .skip: outcome.skipped[item.bookURL, default: 0] += 1; continue
                        case .proceed:
                            guard active else { outcome.cancelled = true; break uploadLoop }
                            await showProgress(name: name, current: attempted, total: total)
                            guard active else { outcome.cancelled = true; break uploadLoop }
                            result = try await CacheExportCloudAsync.upload(
                                session: session, fileName: name, data: item.result.uploadPayloads[index], overwrite: true)
                        }
                    }
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
                        outcome.errors[item.bookURL] = Self.safeMessage(result.errorMessage)
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
        guard active, let owner else { return .stop }
        let controller = UIAlertController(title: title, message: message, preferredStyle: .alert)
        return await withCheckedContinuation { continuation in
            decision = continuation
            @MainActor func respond(_ value: Decision) {
                guard let waiting = self.decision else { return }
                self.decision = nil
                waiting.resume(returning: value)
            }
            controller.addAction(UIAlertAction(title: conflict ? "停止上传" : "取消", style: .cancel) { _ in respond(.stop) })
            if conflict {
                controller.addAction(UIAlertAction(title: "跳过", style: .default) { _ in respond(.skip) })
            }
            controller.addAction(
                UIAlertAction(
                    title: conflict ? "覆盖" : "上传已完成内容", style: conflict ? .destructive : .default
                ) { _ in respond(.proceed) })
            alert = controller
            owner.present(controller, animated: true)
        }
    }

    private func showProgress(name: String, current: Int, total: Int) async {
        await dismissAlert()
        guard active, let owner else { return }
        let controller = UIAlertController(
            title: "上传到 WebDAV", message: "\(current)/\(total)\n\(name)", preferredStyle: .alert)
        controller.addAction(UIAlertAction(title: "停止上传", style: .cancel) { [weak self] _ in self?.cancel() })
        alert = controller
        owner.present(controller, animated: true)
    }

    private func dismissAlert() async {
        guard let alert else { return }
        // Dismissal must yield normally even when the upload task has already been cancelled.
        let dismissal = Task { @MainActor in await CacheExportSharing.dismiss(alert) }
        await dismissal.value
        self.alert = nil
    }

    private func finish() async {
        guard !finished else { return }
        if !active { outcome.cancelled = true }
        await dismissAlert()
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
