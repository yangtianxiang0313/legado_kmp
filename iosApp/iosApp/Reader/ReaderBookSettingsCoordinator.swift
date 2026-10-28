import UIKit
import shared

/// Owns per-book settings which reload reading content after their dialog closes.
@MainActor
final class ReaderBookSettingsCoordinator {
    private struct Context {
        let id = UUID()
        let bookURL: String
        let origin: String
        let chapterIndex: Int
        let chapterURL: String?
        let chapterTitle: String
        let position: Int

        init(_ reader: ReaderContainerViewController, book: Book) {
            bookURL = book.bookUrl
            origin = book.origin
            chapterIndex = reader.chapterIndex
            chapterURL = reader.currentChapterURL
            chapterTitle = reader.chapterTitle
            position =
                reader.pages.indices.contains(reader.currentPageIndex)
                ? reader.currentCharacterOffset() : Int(book.durChapterPos)
        }

        func target(in chapters: [BookChapter]) -> (index: Int, position: Int) {
            if let chapterURL, !chapterURL.isEmpty,
                let chapter = chapters.first(where: { $0.url == chapterURL || $0.getAbsoluteURL() == chapterURL })
            {
                return (Int(chapter.index), position)
            }
            if !chapterTitle.isEmpty, let chapter = chapters.first(where: { $0.title == chapterTitle }) {
                return (Int(chapter.index), position)
            }
            return (min(max(chapterIndex, 0), max(0, chapters.count - 1)), 0)
        }
    }

    private enum Setting {
        case imageStyle(String)
        case charset(String)
        case simulation(ReaderSimulatedReadingRequest)

        var successMessage: String {
            switch self {
            case .imageStyle: return L10n.Reader.imageStyleUpdated
            case .charset: return L10n.Reader.charsetUpdated
            case .simulation: return "模拟追读已更新"
            }
        }
    }

    private weak var reader: ReaderContainerViewController?
    private weak var dialog: UIViewController?
    private var context: Context?
    private var task: Task<Void, Never>?
    private var pendingReload: Context?
    private var activationObserver: NSObjectProtocol?

    var isSaving: Bool { task != nil }

    init(reader: ReaderContainerViewController) {
        self.reader = reader
        activationObserver = NotificationCenter.default.addObserver(
            forName: UIScene.didActivateNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let scene = notification.object as? UIScene else { return }
            Task { @MainActor [weak self] in
                guard let self, self.reader?.viewIfLoaded?.window?.windowScene === scene else { return }
                self.resume()
            }
        }
    }

    deinit {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }

    func resume() {
        guard task == nil, dialog == nil, let pending = pendingReload, let reader,
            canUse(reader), reader.presentedViewController == nil
        else { return }
        pendingReload = nil
        guard reader.bookURL == pending.bookURL, reader.book?.origin == pending.origin else { return }
        // A shared write may commit after leaving/backgrounding. Re-read current progress on return.
        reader.chapterLoadCoordinator.load(
            in: reader, index: reader.chapterIndex, restorePosition: nil, restoresBookProgress: true)
    }

    func presentImageStyle() {
        guard let reader, reader.canNavigateReaderPages, let context = beginSelection() else { return }
        let controller = ReaderImageStyleDialogViewController(
            onClose: { [weak self] in self?.selectionClosed(context) },
            onSelect: { [weak self] value in self?.save(.imageStyle(value), context: context) })
        present(controller, in: reader)
    }

    func presentCharset() {
        guard let reader, reader.book?.isLocal == true, let context = beginSelection() else { return }
        let controller = ReaderCharsetDialogViewController(
            charset: reader.book?.charset ?? "",
            onClose: { [weak self] in self?.selectionClosed(context) },
            onConfirm: { [weak self] value in self?.save(.charset(value), context: context) })
        present(controller, in: reader)
    }

    func suspend() {
        context = nil
        task?.cancel()
        dialog?.dismiss(animated: false)
        dialog = nil
        // The task owns its busy flag until the non-cancellable shared write has actually returned.
    }

    func presentSimulation() {
        guard let reader, let book = reader.book, let context = beginSelection() else { return }
        let controller = ReaderSimulatedReadingDialogViewController(
            draft: ReaderSimulatedReadingDates.initialDraft(
                book: book, currentChapterIndex: reader.readerActionChapterIndex),
            chapterCount: reader.chapters.count,
            onClose: { [weak self] in self?.selectionClosed(context) },
            onConfirm: { [weak self] request in self?.save(.simulation(request), context: context) })
        present(controller, in: reader)
    }

    private func beginSelection() -> Context? {
        guard task == nil, context == nil, let reader, canUse(reader),
            reader.presentedViewController == nil, !reader.pageAnimationSelectionCoordinator.isSaving,
            !reader.chapterLoadCoordinator.isLoading, !reader.sourceChangeActions.isBusy,
            let book = reader.book, book.bookUrl == reader.bookURL
        else { return nil }
        let selected = Context(reader, book: book)
        context = selected
        reader.setMenuVisible(false)
        reader.stopAutoPage(showMessage: false)
        return selected
    }

    private func present(_ controller: UIViewController, in reader: ReaderContainerViewController) {
        dialog = controller
        controller.overrideUserInterfaceStyle = reader.traitCollection.userInterfaceStyle
        reader.present(controller, animated: true)
    }

    private func selectionClosed(_ selected: Context) {
        guard context?.id == selected.id else { return }
        dialog = nil
        if task == nil { context = nil }
    }

    private func save(_ setting: Setting, context selected: Context) {
        guard task == nil, accepts(selected), let reader, reader.presentedViewController == nil else { return }
        dialog = nil
        if reader.pages.indices.contains(reader.currentPageIndex) { reader.stageProgress(immediate: true) }
        reader.chapterListRefreshCoordinator.cancel(in: reader)
        reader.chapterLoadCoordinator.cancel(in: reader)
        reader.loadingIndicator.startAnimating()
        task = Task { @MainActor [self, weak reader] in
            var reload: (index: Int, position: Int)?
            defer {
                let mayReload = accepts(selected)
                task = nil
                if context?.id == selected.id { context = nil }
                reader?.loadingIndicator.stopAnimating()
                if mayReload, let reader, let reload {
                    pendingReload = nil
                    reader.chapterLoadCoordinator.load(
                        in: reader, index: reload.index, restorePosition: reload.position,
                        successMessage: setting.successMessage)
                } else {
                    resume()
                }
            }
            guard let reader else { return }
            do {
                await reader.screen.flushReadingProgressNow()
                try check(selected)
                pendingReload = selected
                switch setting {
                case .simulation(let request):
                    let latest = try await ReaderSimulatedReadingPolicy.save(
                        request, bookURL: selected.bookURL, origin: selected.origin)
                    try check(selected)
                    reader.book = latest
                    let count = ReaderSimulatedReadingPolicy.count(book: latest, realCount: reader.chapters.count)
                    let index = min(selected.chapterIndex, max(0, count - 1))
                    reload = (index, index == selected.chapterIndex ? selected.position : 0)
                case .imageStyle(let value):
                    _ = try await reader.screen.setImageStyle(value)
                    try check(selected)
                    reader.book = try await reader.screen.resolveCurrentBook()
                    try check(selected)
                    // Android loadContent(false): reprocess cached content, never force a network refresh.
                    reload = (selected.chapterIndex, selected.position)
                case .charset(let value):
                    _ = try await reader.screen.setCharset(value)
                    try check(selected)
                    let result = try await reader.screen.refreshChapters()
                    try check(selected)
                    let latest = try await reader.screen.resolveCurrentBook()
                    try check(selected)
                    guard !result.chapters.isEmpty else {
                        throw NSError(
                            domain: "io.legado.reader.settings", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: L10n.BookDetail.emptyChapters])
                    }
                    reader.screen.rebindBookURL(selected.bookURL, book: latest, chapters: result.chapters)
                    reader.book = latest
                    reader.chapters = result.chapters
                    reload = selected.target(in: result.chapters)
                }
            } catch {
                guard accepts(selected), !(error is CancellationError) else { return }
                pendingReload = nil
                if case .charset = setting {
                    reader.showReaderLoadFailure(message: error.userFacingMessage, requestedIndex: selected.chapterIndex)
                } else {
                    reader.showToast(error.userFacingMessage)
                }
            }
        }
    }

    private func check(_ selected: Context) throws {
        try Task.checkCancellation()
        guard accepts(selected) else { throw CancellationError() }
    }

    private func accepts(_ selected: Context) -> Bool {
        guard context?.id == selected.id, let reader, canUse(reader) else { return false }
        return reader.bookURL == selected.bookURL && reader.book?.origin == selected.origin
    }

    private func canUse(_ reader: ReaderContainerViewController) -> Bool {
        !reader.isMovingFromParent && !reader.isBeingDismissed
            && reader.navigationController?.isBeingDismissed != true
            && reader.navigationController?.topViewController === reader
            && reader.viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive
    }
}
