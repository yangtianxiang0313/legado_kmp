import UIKit
import shared

@MainActor
final class ReaderChapterListPresentationCoordinator {
    private var task: Task<Void, Never>?
    private var requestID: UUID?

    deinit {
        task?.cancel()
    }

    func cancel() {
        requestID = nil
        task?.cancel()
        task = nil
    }

    func present(in reader: ReaderContainerViewController) {
        guard let book = reader.book,
            !book.bookUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            book.bookUrl == reader.bookURL, canPresent(in: reader)
        else { return }
        cancel()
        reader.setMenuVisible(false)
        let id = UUID()
        let bookURL = book.bookUrl
        let origin = book.origin
        let chapterIndex = reader.chapterIndex
        let chapterURL = reader.currentChapterURL
        requestID = id
        task = Task { @MainActor [weak self, weak reader] in
            guard let self, let reader else { return }
            defer {
                if self.requestID == id {
                    self.requestID = nil
                    self.task = nil
                }
            }
            let isCurrent = {
                !Task.isCancelled && self.requestID == id
                    && reader.bookURL == bookURL && reader.book?.bookUrl == bookURL
                    && reader.book?.origin == origin && reader.chapterIndex == chapterIndex
                    && reader.currentChapterURL == chapterURL && self.canPresent(in: reader)
            }
            guard isCurrent() else { return }
            await reader.screen.flushReadingProgressNow()
            guard isCurrent() else { return }
            let items: [ReaderChapterListItem]
            do {
                items = try await reader.screen.loadChapterListState()
            } catch {
                guard !(error is CancellationError), isCurrent() else { return }
                items = reader.localChapterListItems()
            }
            guard isCurrent() else { return }
            let list = reader.makeChapterListSheet(items: items)
            list.overrideUserInterfaceStyle = reader.readMenu.overflowInterfaceStyle
            list.modalPresentationStyle = .fullScreen
            reader.present(list, animated: true)
        }
    }

    private func canPresent(in reader: ReaderContainerViewController) -> Bool {
        !reader.isMovingFromParent && !reader.isBeingDismissed
            && reader.navigationController?.topViewController === reader
            && reader.presentedViewController == nil
            && reader.viewIfLoaded?.window != nil
    }
}
