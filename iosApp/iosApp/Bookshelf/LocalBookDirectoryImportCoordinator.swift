import UIKit

@MainActor
final class LocalBookDirectoryImportCoordinator {
    var onBatchCompleted: ((LocalBookImportSummary) -> Void)?
    var onFinished: (() -> Void)?
    private(set) var completedSummary: LocalBookImportSummary?
    private(set) var canDeliverResult = false

    private weak var presenter: UIViewController?
    private var task: Task<Void, Never>?
    private var importer: LocalBookImportCoordinator?
    private var rootLease: SandboxFileReadLease?
    private var progress: LocalBookImportProgressViewController?
    private weak var progressPresenter: UIViewController?
    private var selection: LocalBookDirectorySelectionViewController?
    private var selectionNavigation: UINavigationController?
    private var continuation: CheckedContinuation<[URL]?, Never>?
    private var presentationContinuation: CheckedContinuation<Void, Never>?
    private var isPresentingSelection = false
    private var hasPendingSelectionReply = false
    private var pendingSelectionReply: [URL]?
    private var ownership: LocalBookImportOwnership?
    private var isFinishing = false

    init(presenter: UIViewController) { self.presenter = presenter }

    func start(root: URL, groupID: Int64 = 0) {
        guard task == nil, importer == nil, !isFinishing else { return }
        completedSummary = nil
        canDeliverResult = false
        let ownership = presenter.flatMap { LocalBookImportOwnership(owner: $0) }
        self.ownership = ownership
        let id = ownership?.id
        ownership?.onCheck = { [weak self] in self?.checkInteraction() }
        rootLease = SandboxFileReadLease(root)
        ownership?.observe { [weak self] in
            guard let self, self.ownership?.id == id else { return }
            self.cancel()
        }
        // Keep the granted directory scope through scan, selection, and the last acknowledged import.
        task = Task { @MainActor [self] in
            var summary: LocalBookImportSummary?
            do {
                try await showProgress(root.lastPathComponent)
                let result = try await LocalBookDirectoryScanner.scan(root: root) { [weak self] visited, found in
                    Task { @MainActor in
                        guard let self, self.ownership?.id == id, self.task?.isCancelled == false, !self.isFinishing,
                            let progress = self.progress, self.ownership?.canUse(progress) == true
                        else { return }
                        self.progress?.setStatus("已扫描 \(visited) 项，找到 \(found) 个文件")
                    }
                }
                try Task.checkCancellation()
                await dismissProgress()
                try await ensureCurrent(id)
                let urls = try await select(result)
                try Task.checkCancellation()
                if let urls, !urls.isEmpty, let presenter {
                    try await ensureCurrent(id)
                    let importer = LocalBookImportCoordinator(presenter: presenter) { _ in }
                    importer.onBatchCompleted = { _ in }
                    self.importer = importer
                    let terminal: (LocalBookImportSummary?, Bool) = await withTaskCancellationHandler {
                        await withCheckedContinuation { terminal in
                            importer.onFinished = { [weak importer] in
                                terminal.resume(returning: (importer?.completedSummary, importer?.canDeliverResult == true))
                            }
                            // The directory task stays busy until the child's true terminal callback.
                            guard ownership?.canPresent == true else {
                                terminal.resume(returning: (nil, false))
                                return
                            }
                            ownership?.stopObserving()
                            importer.start(urls: urls, groupID: groupID)
                            if Task.isCancelled { importer.cancel() }
                        }
                    } onCancel: {
                        Task { @MainActor [weak self] in
                            guard let self, self.ownership?.id == id else { return }
                            self.importer?.cancel()
                        }
                    }
                    summary = terminal.0
                    if !terminal.1 { ownership?.invalidate() }
                    self.importer = nil
                    // Do not replace a committed child summary with a late parent cancellation.
                }
            } catch {
                await dismissProgress()
                if !(error is CancellationError), canPresent {
                    presenter?.showTransientMessage(error.userFacingMessage, duration: 4)
                }
            }
            isFinishing = true
            await dismissSelection()
            await dismissProgress()
            rootLease?.cancel()
            rootLease = nil
            completedSummary = summary
            let completed = onBatchCompleted
            let finished = onFinished
            ownership?.stopObserving()
            canDeliverResult = ownership?.canPresent == true
            if let summary, canDeliverResult { completed?(summary) }
            self.ownership = nil
            task = nil
            isFinishing = false
            finished?()
        }
    }

    func cancel() {
        guard task != nil, !isFinishing else { return }
        task?.cancel()
        importer?.cancel()
        resolveSelection(nil)
        progress?.setStatus(BookshelfLocalImportText.cancelling, cancelling: true)
    }

    private var canPresent: Bool {
        ownership?.canPresent == true
    }

    private func ensureCurrent(_ id: UUID?) async throws {
        try Task.checkCancellation()
        guard let ownership, ownership.id == id else { throw CancellationError() }
        try await ownership.waitUntilReady()
        guard canPresent else { throw CancellationError() }
    }

    private func showProgress(_ fileName: String) async throws {
        try Task.checkCancellation()
        guard canPresent, let presenter, let ownership else { throw CancellationError() }
        let controller = LocalBookImportProgressViewController(fileName: fileName)
        let id = ownership.id
        controller.onCancel = { [weak self, weak controller] in
            guard let self, let controller, self.ownership?.id == id,
                self.ownership?.canUse(controller) == true
            else { return }
            self.cancel()
        }
        progress = controller
        ownership.bind(controller)
        await withCheckedContinuation { continuation in
            presentationContinuation = continuation
            presenter.present(controller, animated: !UIAccessibility.isReduceMotionEnabled) { [weak self] in
                guard let self, self.ownership?.id == id else { return }
                self.finishPresentation()
            }
        }
        progressPresenter = controller.presentingViewController
        try ownership.acknowledgePresentation(controller)
        try await ownership.waitUntilReady()
        guard ownership.canUse(controller) else { throw CancellationError() }
        controller.setStatus("正在扫描文件夹…")
        try Task.checkCancellation()
    }

    private func select(_ scan: LocalBookDirectoryScan) async throws -> [URL]? {
        guard canPresent, let presenter, let ownership else { throw CancellationError() }
        let id = ownership.id
        let controller = LocalBookDirectorySelectionViewController(
            files: scan.files, issues: scan.issues, isTruncated: scan.isTruncated
        ) { [weak self] urls in
            guard let self, self.ownership?.id == id, let navigation = self.selectionNavigation else { return }
            let current =
                ownership.canUse(navigation, allowingDismissal: true)
                && navigation.topViewController === self.selection
            self.resolveSelection(current ? urls : nil)
        }
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .formSheet
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        selection = controller
        selectionNavigation = navigation
        ownership.bind(navigation)
        let result: [URL]? = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
                isPresentingSelection = true
                presenter.present(navigation, animated: !UIAccessibility.isReduceMotionEnabled) { [weak self] in
                    guard let self, self.selectionNavigation === navigation else { return }
                    self.isPresentingSelection = false
                    if self.hasPendingSelectionReply {
                        let reply = self.pendingSelectionReply
                        self.hasPendingSelectionReply = false
                        self.pendingSelectionReply = nil
                        self.resolveSelection(reply)
                    }
                }
                navigation.presentationController?.delegate = controller
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.ownership?.id == id else { return }
                self.resolveSelection(nil)
            }
        }
        selection = nil
        selectionNavigation = nil
        ownership.bind(nil)
        try Task.checkCancellation()
        return result
    }

    private func resolveSelection(_ urls: [URL]?) {
        guard let continuation else { return }
        if isPresentingSelection {
            if !hasPendingSelectionReply || urls == nil { pendingSelectionReply = urls }
            hasPendingSelectionReply = true
            return
        }
        self.continuation = nil
        selection?.cancelSelection()
        let navigation = selectionNavigation
        Task { @MainActor in
            if let navigation { await LocalBookImportOwnership.dismiss(navigation) }
            continuation.resume(returning: urls)
        }
    }

    private func finishPresentation() {
        let continuation = presentationContinuation
        presentationContinuation = nil
        continuation?.resume()
    }

    private func checkInteraction() {
        guard task != nil, !isFinishing, importer == nil else { return }
        if let progress, let host = progressPresenter,
            progress.presentingViewController !== host || host.presentedViewController !== progress || progress.isBeingDismissed
        {
            cancel()
        }
        if continuation != nil, let navigation = selectionNavigation,
            navigation.topViewController !== selection || navigation.presentingViewController == nil || navigation.isBeingDismissed
        {
            cancel()
        }
    }

    private func dismissSelection() async {
        resolveSelection(nil)
        if let navigation = selectionNavigation { await LocalBookImportOwnership.dismiss(navigation) }
        selection = nil
        selectionNavigation = nil
        ownership?.bind(nil)
    }

    private func dismissProgress() async {
        guard let controller = progress else { return }
        controller.onCancel = nil
        // This dismissal hands the original owner to selection; it is not user cancellation.
        progressPresenter = nil
        await LocalBookImportOwnership.dismiss(controller)
        progress = nil
        ownership?.bind(nil)
    }
}
