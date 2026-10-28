import UIKit
import shared

@MainActor
final class ReaderTocBookmarkExportCoordinator {
    private var task: Task<Void, Never>?
    private var generation = UUID()

    deinit { task?.cancel() }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
    }

    func presentExport(
        markdown: Bool, screen: ReaderBookmarkListProviding, bookName: String, bookAuthor: String,
        in presenter: UIViewController, anchor: UIView
    ) {
        guard task == nil, presenter.presentedViewController == nil else { return }
        let generation = UUID()
        self.generation = generation
        task = Task { @MainActor [weak self, weak presenter, weak anchor] in
            defer {
                if self?.generation == generation { self?.task = nil }
            }
            do {
                // Read from the production adapter at command time, independent of list search.
                let bookmarks = try await screen.loadBookmarks().enumerated()
                    .filter { $0.element.bookName == bookName && $0.element.bookAuthor == bookAuthor }
                    .sorted {
                        $0.element.chapterIndex == $1.element.chapterIndex
                            ? $0.offset < $1.offset : $0.element.chapterIndex < $1.element.chapterIndex
                    }.map(\.element)
                try Task.checkCancellation()
                guard self?.generation == generation, let presenter, let anchor,
                    presenter.viewIfLoaded?.window != nil, !presenter.isBeingDismissed,
                    presenter.presentedViewController == nil
                else { return }
                let text =
                    try markdown
                    ? ReaderBookmarkExport.androidMarkdown(bookmarks, bookName: bookName, bookAuthor: bookAuthor)
                    : ReaderBookmarkExport.androidJSON(bookmarks)
                let name = ReaderBookmarkExport.androidFileName(bookName: bookName, bookAuthor: bookAuthor, markdown: markdown)
                let url = try ReaderBookmarkExport.fileURL(text: text, fileName: name)
                let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                activity.popoverPresentationController?.sourceView = anchor
                activity.popoverPresentationController?.sourceRect = anchor.bounds
                activity.completionWithItemsHandler = { _, _, _, _ in
                    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                }
                presenter.present(activity, animated: true)
            } catch {
                guard !Task.isCancelled, self?.generation == generation,
                    let presenter, presenter.viewIfLoaded?.window != nil
                else { return }
                presenter.showTransientMessage("\(L10n.AllBookmark.exportFailed): \(error.userFacingMessage)")
            }
        }
    }
}
