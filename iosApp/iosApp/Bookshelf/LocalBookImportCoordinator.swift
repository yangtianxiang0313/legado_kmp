import shared
import UIKit

struct LocalBookImportIssue {
    let fileName: String
    let message: String
}

struct LocalBookImportSummary {
    let books: [Book]
    let failures: [LocalBookImportIssue]
    let isCancelled: Bool
    // Counts refer to deduplicated source URLs, not individual archive entries.
    // A started source counts as processed once its preparation/import cleanup has ended.
    let processedFiles: Int
    let totalFiles: Int
}

/// Reusable by file browsing, document previews, system URL handling and the bookshelf.
@MainActor
final class LocalBookImportCoordinator {
    var onBatchCompleted: ((LocalBookImportSummary) -> Void)?
    var onFinished: (() -> Void)?

    private weak var presenter: UIViewController?
    private let onImported: (Book) -> Void
    private var task: Task<Void, Never>?
    private var isFinishing = false
    private var progress: LocalBookImportProgressViewController?
    private weak var progressPresenter: UIViewController?
    private var selection: LocalBookArchiveSelectionViewController?
    private var selectionNavigation: UINavigationController?
    private var selectionContinuation: CheckedContinuation<[ArchiveBookEntry]?, Never>?

    init(presenter: UIViewController, onImported: @escaping (Book) -> Void) {
        self.presenter = presenter
        self.onImported = onImported
    }

    func start(url: URL, groupID: Int64 = 0) {
        start(urls: [url], groupID: groupID)
    }

    func start(urls: [URL], groupID: Int64 = 0) {
        guard task == nil else { return }
        var seen: Set<URL> = []
        let sources = urls.compactMap { url -> SandboxFileReadLease? in
            let key = url.isFileURL ? url.standardizedFileURL : url.absoluteURL.standardized
            guard seen.insert(key).inserted else { return nil }
            // Keep the original scoped URL; normalization is only used for identity.
            // Acquire synchronously so picker delivery scopes can be released after start returns.
            return SandboxFileReadLease(url)
        }
        // The task owns the coordinator until finish, even when the entry point does not retain it.
        task = Task { @MainActor [self] in
            var batch = Batch(totalFiles: sources.count)
            do {
                try Task.checkCancellation()
                if let first = sources.first {
                    try await showProgress(fileName: first.source.lastPathComponent)
                }
                for source in sources {
                    // Never begin another source after cancellation, even while cleanup was suspended.
                    try Task.checkCancellation()
                    await importSource(source.source, groupID: groupID, batch: &batch)
                    if batch.isCancelled { break }
                }
            } catch is CancellationError {
                batch.isCancelled = true
            } catch {
                batch.failures.append(
                    LocalBookImportIssue(
                        fileName: sources.first?.source.lastPathComponent ?? "",
                        message: error.userFacingMessage
                    ))
            }
            isFinishing = true
            await dismissImportUI()
            // These leases only hold incoming scopes. They do not cancel LocalBookFileStore's copy.
            // Every prepare/shared request and prepared-file lease has already reached its terminal state.
            sources.forEach { $0.cancel() }
            let summary = batch.summary
            let completed = onBatchCompleted
            let finished = onFinished
            if let completed {
                completed(summary)
            } else {
                summary.books.forEach(onImported)
                if !summary.failures.isEmpty { showFailures(summary.failures) }
            }
            task = nil
            isFinishing = false
            finished?()
        }
    }

    func cancel() {
        guard task != nil, !isFinishing else { return }
        task?.cancel()
        selection?.cancelSelection()
        progress?.setStatus(BookshelfLocalImportText.cancelling, cancelling: true)
    }

    private func importSource(_ url: URL, groupID: Int64, batch: inout Batch) async {
        var prepared: PreparedLocalBookImport?
        do {
            try Task.checkCancellation()
            let controller = try activeProgress()
            controller.setFileName(url.lastPathComponent)
            controller.setStatus("文件 \(batch.processedFiles + 1) / \(batch.totalFiles)\n\(BookshelfLocalImportText.preparing)")
            let input = try await LocalBookImportService.prepare(from: url)
            prepared = input
            try Task.checkCancellation()
            let paths = try await entryPaths(for: input)
            for (entryIndex, entryPath) in paths.enumerated() {
                try Task.checkCancellation()
                let controller = try activeProgress()
                let fileName = entryPath.map { "\(input.fileName) / \($0)" } ?? input.fileName
                controller.setFileName(fileName)
                controller.setStatus(
                    "文件 \(batch.processedFiles + 1) / \(batch.totalFiles)，条目 \(entryIndex + 1) / \(paths.count)\n\(BookshelfLocalImportText.importing)"
                )
                do {
                    let book = try await LocalBookImportService.importBook(
                        input, entryPath: entryPath, groupID: groupID
                    )
                    // Record an acknowledged commit even when cancel arrived during the shared request.
                    // Keep the first returned Book without rewriting reading progress or stored books.
                    batch.append(book)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    batch.failures.append(LocalBookImportIssue(fileName: fileName, message: error.userFacingMessage))
                    try Task.checkCancellation()
                }
            }
        } catch is CancellationError {
            batch.isCancelled = true
        } catch {
            batch.failures.append(LocalBookImportIssue(fileName: url.lastPathComponent, message: error.userFacingMessage))
            if Task.isCancelled { batch.isCancelled = true }
        }
        if let prepared { await LocalBookImportService.discard(prepared) }
        batch.processedFiles += 1
        // No cancellation check after the last acknowledged commit: it still owns its retained copy.
    }

    private func entryPaths(for input: PreparedLocalBookImport) async throws -> [String?] {
        guard let archive = input.archive else { return [nil] }
        guard !archive.entries.isEmpty else { throw failure("压缩包中没有可导入的书籍") }
        if archive.entries.count == 1 { return [archive.entries[0].path] }
        let selected = try await selectEntries(in: archive, fileName: input.fileName)
        let selectedPaths = Set(selected.map(\.path))
        var seen: Set<String> = []
        // Selection order does not affect import order, and a repeated entry is never imported twice.
        let paths = archive.entries.compactMap { entry -> String? in
            guard selectedPaths.contains(entry.path), seen.insert(entry.path).inserted else { return nil }
            return entry.path
        }
        guard !paths.isEmpty else { throw failure("请选择压缩包内需要导入的书籍") }
        return paths.map { Optional($0) }
    }

    private func showProgress(fileName: String) async throws {
        try Task.checkCancellation()
        guard let presenter, presenter.viewIfLoaded?.window != nil,
            !presenter.isBeingDismissed, presenter.presentedViewController == nil
        else { throw CancellationError() }
        let controller = LocalBookImportProgressViewController(fileName: fileName)
        controller.onCancel = { [weak self] in self?.cancel() }
        progress = controller
        await withCheckedContinuation { continuation in
            presenter.present(controller, animated: true) { continuation.resume() }
        }
        // UIKit may forward presentation to a navigation/container controller.
        // Track the actual presenter instead of comparing against the original caller.
        progressPresenter = controller.presentingViewController
        _ = try activeProgress()
    }

    private func activeProgress() throws -> LocalBookImportProgressViewController {
        guard let controller = progress, let host = progressPresenter,
            controller.presentingViewController === host,
            host.presentedViewController === controller,
            controller.viewIfLoaded?.window != nil, !controller.isBeingDismissed,
            controller.presentedViewController == nil
        else { throw CancellationError() }
        return controller
    }

    private func selectEntries(in archive: ArchiveBookListing, fileName: String) async throws -> [ArchiveBookEntry] {
        try Task.checkCancellation()
        let host = try activeProgress()
        let controller = LocalBookArchiveSelectionViewController(fileName: fileName, entries: archive.entries)
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .formSheet
        selection = controller
        selectionNavigation = navigation
        let selected: [ArchiveBookEntry]? = await withCheckedContinuation { continuation in
            selectionContinuation = continuation
            controller.onSelection = { [weak self, weak controller] entries in
                guard let self, let controller, self.selection === controller,
                    let continuation = self.selectionContinuation
                else { return }
                // Consume before dismissal suspends: cancel, confirm and swipe may race.
                self.selectionContinuation = nil
                controller.onSelection = nil
                Task { @MainActor in
                    await Self.dismiss(navigation)
                    continuation.resume(returning: entries)
                }
            }
            // Keep one progress controller alive for the whole batch, with selection above it.
            host.present(navigation, animated: true)
            navigation.presentationController?.delegate = controller
        }
        selection = nil
        selectionNavigation = nil
        try Task.checkCancellation()
        guard let selected else { throw CancellationError() }
        return selected
    }

    private func dismissImportUI() async {
        if let navigation = selectionNavigation {
            selection?.onSelection = nil
            await Self.dismiss(navigation)
            selection = nil
            selectionNavigation = nil
        }
        guard let controller = progress else { return }
        controller.onCancel = nil
        await Self.dismiss(controller)
        progress = nil
        progressPresenter = nil
    }

    private func showFailures(_ failures: [LocalBookImportIssue]) {
        guard let presenter, presenter.viewIfLoaded?.window != nil,
            presenter.presentedViewController == nil
        else { return }
        let message = failures.map { "\($0.fileName)：\($0.message)" }.joined(separator: "\n")
        let alert = UIAlertController(title: "导入失败", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default))
        presenter.present(alert, animated: true)
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "io.legado.local-book-import", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func dismiss(_ controller: UIViewController) async {
        if controller.isBeingPresented, let transition = controller.transitionCoordinator {
            await waitForTransition(transition)
        }
        if controller.isBeingDismissed, let transition = controller.transitionCoordinator {
            await waitForTransition(transition)
        } else if controller.presentingViewController != nil {
            await withCheckedContinuation { continuation in
                controller.dismiss(animated: true) { continuation.resume() }
            }
        }
    }

    private static func waitForTransition(_ transition: UIViewControllerTransitionCoordinator) async {
        await withCheckedContinuation { continuation in
            if !transition.animate(alongsideTransition: nil, completion: { _ in continuation.resume() }) {
                continuation.resume()
            }
        }
    }

    private struct Batch {
        let totalFiles: Int
        var books: [Book] = []
        var failures: [LocalBookImportIssue] = []
        var isCancelled = false
        var processedFiles = 0
        private var bookURLs: Set<String> = []

        init(totalFiles: Int) { self.totalFiles = totalFiles }

        mutating func append(_ book: Book) {
            if bookURLs.insert(book.bookUrl).inserted { books.append(book) }
        }

        var summary: LocalBookImportSummary {
            LocalBookImportSummary(
                books: books, failures: failures, isCancelled: isCancelled,
                processedFiles: processedFiles, totalFiles: totalFiles
            )
        }
    }
}
