import UIKit

@MainActor
final class LocalBookDirectoryImportCoordinator {
    var onBatchCompleted: ((LocalBookImportSummary) -> Void)?
    var onFinished: (() -> Void)?

    private weak var presenter: UIViewController?
    private var task: Task<Void, Never>?
    private var importer: LocalBookImportCoordinator?
    private var rootLease: SandboxFileReadLease?
    private var progress: LocalBookImportProgressViewController?
    private var selection: LocalBookDirectorySelectionViewController?
    private var selectionNavigation: UINavigationController?
    private var continuation: CheckedContinuation<[URL]?, Never>?
    private var revision = UUID()
    private weak var sourceWindow: UIWindow?

    init(presenter: UIViewController) { self.presenter = presenter }

    func start(root: URL, groupID: Int64 = 0) {
        guard task == nil, importer == nil, let presenter, presenter.canPerformNavigationAction,
            presenter.presentedViewController == nil, let window = presenter.viewIfLoaded?.window,
            AppLockManager.shared.isUnlocked(in: window)
        else { onFinished?(); return }
        rootLease = SandboxFileReadLease(root)
        sourceWindow = window
        let id = UUID()
        revision = id
        // Keep the granted directory scope through scan, selection, and the last acknowledged import.
        task = Task { @MainActor [self] in
            do {
                try await showProgress(root.lastPathComponent)
                let result = try await LocalBookDirectoryScanner.scan(root: root) { [weak self] visited, found in
                    Task { @MainActor in
                        guard let self, self.revision == id, self.task != nil, !Task.isCancelled else { return }
                        self.progress?.setStatus("已扫描 \(visited) 项，找到 \(found) 个文件")
                    }
                }
                try Task.checkCancellation()
                await dismissProgress()
                try ensureCurrent(id)
                let urls = try await select(result)
                try Task.checkCancellation()
                try ensureCurrent(id)
                guard let urls, !urls.isEmpty else { finish(); return }
                let importer = LocalBookImportCoordinator(presenter: presenter) { _ in }
                self.importer = importer
                importer.onBatchCompleted = { [weak self] summary in self?.onBatchCompleted?(summary) }
                importer.onFinished = { [weak self] in self?.finish() }
                task = nil
                importer.start(urls: urls, groupID: groupID)
            } catch {
                await dismissProgress()
                if !(error is CancellationError), canPresent {
                    presenter.showTransientMessage(error.userFacingMessage, duration: 4)
                }
                finish()
            }
        }
    }

    func cancel() {
        task?.cancel()
        importer?.cancel()
        selection?.cancelSelection()
        progress?.setStatus(BookshelfLocalImportText.cancelling, cancelling: true)
    }

    private var canPresent: Bool {
        guard let presenter, let window = presenter.viewIfLoaded?.window,
            window === sourceWindow, window.isKeyWindow,
            window.windowScene?.activationState == .foregroundActive,
            UIApplication.shared.applicationState == .active,
            presenter.canPerformNavigationAction, presenter.presentedViewController == nil,
            AppLockManager.shared.isUnlocked(in: window)
        else { return false }
        return true
    }

    private func ensureCurrent(_ id: UUID) throws {
        guard revision == id, canPresent else { throw CancellationError() }
    }

    private func showProgress(_ fileName: String) async throws {
        guard canPresent, let presenter else { throw CancellationError() }
        let controller = LocalBookImportProgressViewController(fileName: fileName)
        controller.onCancel = { [weak self] in self?.cancel() }
        progress = controller
        await withCheckedContinuation { continuation in
            presenter.present(controller, animated: !UIAccessibility.isReduceMotionEnabled) { continuation.resume() }
        }
        controller.setStatus("正在扫描文件夹…")
        try Task.checkCancellation()
    }

    private func select(_ scan: LocalBookDirectoryScan) async throws -> [URL]? {
        guard canPresent, let presenter else { throw CancellationError() }
        let controller = LocalBookDirectorySelectionViewController(
            files: scan.files, issues: scan.issues, isTruncated: scan.isTruncated
        ) { [weak self] urls in
            guard let self, let continuation = self.continuation, let navigation = self.selectionNavigation else { return }
            self.continuation = nil
            Task { @MainActor in
                await Self.dismiss(navigation)
                self.selection = nil
                self.selectionNavigation = nil
                continuation.resume(returning: urls)
            }
        }
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .formSheet
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        selection = controller
        selectionNavigation = navigation
        let result: [URL]? = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
                presenter.present(navigation, animated: !UIAccessibility.isReduceMotionEnabled)
                navigation.presentationController?.delegate = controller
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.selection?.cancelSelection() }
        }
        try Task.checkCancellation()
        return result
    }

    private func dismissProgress() async {
        guard let controller = progress else { return }
        controller.onCancel = nil
        await Self.dismiss(controller)
        progress = nil
    }

    private func finish() {
        revision = UUID()
        task = nil
        importer = nil
        selection = nil
        selectionNavigation = nil
        rootLease?.cancel()
        rootLease = nil
        sourceWindow = nil
        let callback = onFinished
        onFinished = nil
        callback?()
    }

    private static func dismiss(_ controller: UIViewController) async {
        if let transition = controller.transitionCoordinator,
            controller.isBeingPresented || controller.isBeingDismissed
        {
            await withCheckedContinuation { continuation in
                if !transition.animate(alongsideTransition: nil, completion: { _ in continuation.resume() }) {
                    continuation.resume()
                }
            }
        }
        guard controller.presentingViewController != nil else { return }
        await withCheckedContinuation { continuation in
            controller.dismiss(animated: !UIAccessibility.isReduceMotionEnabled) { continuation.resume() }
        }
    }
}
