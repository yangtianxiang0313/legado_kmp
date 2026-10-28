import UIKit

@MainActor
final class CacheExportSharing: NSObject, UIAdaptivePresentationControllerDelegate {
    struct Item {
        let bookURL: String
        let result: CacheBookExportResult
    }

    private var items: [Item]
    private let failedCount: Int
    private weak var owner: UIViewController?
    private weak var anchor: UIView?
    private var canPresent: (() -> Bool)?
    private var onFinish: ((Bool, Error?) -> Void)?
    private var confirmation: UIAlertController?
    private var confirmationDismissal: Task<Void, Never>?
    private var activity: UIActivityViewController?
    private var handedToSystem = false
    private var finishing = false
    private var finished = false

    init(items: [Item], failedCount: Int) {
        self.items = items
        self.failedCount = failedCount
        super.init()
    }

    static func activityItems(for items: [Item]) -> [Any] {
        // The [Any] initializer context can select Optional.flatMap and box an entire URL array.
        let urls: [URL] = items.flatMap { item -> [URL] in item.result.urls }
        return urls.map { $0 as Any }
    }

    func present(
        from owner: UIViewController, anchor: UIView,
        canPresent: @escaping () -> Bool, onFinish: @escaping (Bool, Error?) -> Void
    ) {
        self.owner = owner
        self.anchor = anchor
        self.canPresent = canPresent
        self.onFinish = onFinish
        guard canPresent(), !items.isEmpty else {
            finish(completed: false, error: nil)
            return
        }
        guard let warningMessage else {
            presentActivity()
            return
        }
        let alert = UIAlertController(title: "部分导出", message: warningMessage, preferredStyle: .alert)
        alert.addAction(
            UIAlertAction(title: L10n.Common.cancel, style: .cancel) { [weak self] _ in
                self?.finish(completed: false, error: nil)
            })
        alert.addAction(
            UIAlertAction(title: "分享已完成内容", style: .default) { [weak self] _ in
                guard let self, !self.finishing, !self.finished else { return }
                Task { @MainActor [self] in
                    await self.dismissConfirmation()
                    guard !self.finishing, !self.finished else { return }
                    self.presentActivity()
                }
            })
        confirmation = alert
        owner.present(alert, animated: true)
    }

    // Once handed to an activity, its own completion/dismissal owns the files, even after page navigation.
    func cancelUndelivered() {
        guard !handedToSystem else { return }
        finish(completed: false, error: nil)
    }

    private var warningMessage: String? {
        Self.warningMessage(for: items, failedCount: failedCount, verb: "分享")
    }

    static func warningMessage(for items: [Item], failedCount: Int, verb: String) -> String? {
        let partialCount = items.filter { $0.result.isPartial }.count
        guard partialCount > 0 || failedCount > 0 else { return nil }
        let missingChapters = items.reduce(0) { $0 + $1.result.missingChapterCount }
        let missingImages = items.reduce(0) { $0 + $1.result.missingImageCount }
        var lines = ["完整 \(items.count - partialCount) 本，内容不完整 \(partialCount) 本，失败 \(failedCount) 本。"]
        if missingChapters > 0 { lines.append("已生成文件中缺失 \(missingChapters) 章正文。") }
        if missingImages > 0 { lines.append("已生成文件中缺失 \(missingImages) 张图片。") }
        lines.append("是否\(verb)已完成的内容？")
        return lines.joined(separator: "\n")
    }

    private func presentActivity() {
        guard !finishing, !finished else { return }
        guard canPresent?() == true, let owner, let window = owner.viewIfLoaded?.window else {
            finish(completed: false, error: nil)
            return
        }
        let controller = UIActivityViewController(activityItems: Self.activityItems(for: items), applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            if let anchor, anchor.window === window {
                popover.sourceView = anchor
                popover.sourceRect = anchor.bounds
            } else {
                popover.sourceView = owner.view
                popover.sourceRect = CGRect(x: owner.view.bounds.midX, y: owner.view.bounds.midY, width: 1, height: 1)
                popover.permittedArrowDirections = []
            }
        }
        activity = controller
        controller.completionWithItemsHandler = { [self] _, completed, _, error in
            Task { @MainActor [self] in self.finish(completed: completed, error: error) }
        }
        handedToSystem = true
        owner.present(controller, animated: true)
        controller.presentationController?.delegate = self
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        if presentationController.presentedViewController === activity {
            finish(completed: false, error: nil)
        }
    }

    private func finish(completed: Bool, error: Error?) {
        guard !finishing, !finished else { return }
        finishing = true
        Task { @MainActor [self] in
            await self.dismissConfirmation()
            if let activity = self.activity { await Self.dismiss(activity) }
            self.activity?.completionWithItemsHandler = nil
            self.confirmation = nil
            self.activity = nil
            for item in self.items { item.result.cleanup() }
            self.items = []
            self.finished = true
            let callback = self.onFinish
            self.onFinish = nil
            self.canPresent = nil
            callback?(completed && error == nil, error)
        }
    }

    private func dismissConfirmation() async {
        let dismissal: Task<Void, Never>
        if let confirmationDismissal {
            dismissal = confirmationDismissal
        } else if let confirmation {
            dismissal = Task { @MainActor in await Self.dismiss(confirmation) }
            confirmationDismissal = dismissal
        } else {
            return
        }
        // The accept action and page cancellation share one dismissal, never two UIKit completions.
        await dismissal.value
        confirmation = nil
        confirmationDismissal = nil
    }

    static func dismiss(_ controller: UIViewController) async {
        while controller.presentingViewController != nil || controller.viewIfLoaded?.window != nil {
            if !controller.isBeingPresented, !controller.isBeingDismissed,
                controller.presentingViewController != nil
            {
                controller.dismiss(animated: true)
            }
            await waitForDismissalTransition(controller)
        }
    }

    private static func waitForDismissalTransition(_ controller: UIViewController) async {
        if let transition = controller.transitionCoordinator {
            let registered = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let registered = transition.animate(alongsideTransition: nil) { _ in
                    continuation.resume(returning: true)
                }
                if !registered { continuation.resume(returning: false) }
            }
            if registered { return }
        }
        // Alert actions auto-dismiss; a finished transition may no longer accept a completion callback.
        try? await Task.sleep(nanoseconds: 16_000_000)
    }
}
