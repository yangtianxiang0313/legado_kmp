import UIKit
import shared

@MainActor
final class ReaderChapterListOrderCoordinator {
    private var isReordering = false

    func reverse(in reader: ReaderContainerViewController) async throws -> [ReaderChapterListItem] {
        try Task.checkCancellation()
        guard !isReordering, reader.book != nil, !reader.chapters.isEmpty,
            reader.navigationController?.topViewController === reader
        else { throw CancellationError() }
        isReordering = true
        defer { isReordering = false }
        let bookURL = reader.bookURL
        let position = reader.currentCharacterOffset()
        reader.chapterListRefreshCoordinator.cancel(in: reader)
        reader.chapterLoadCoordinator.cancel(in: reader)
        let result = try await reader.screen.reverseChapterList()
        guard result.book.bookUrl == bookURL, reader.bookURL == bookURL else { return [] }
        reader.applyChapterListOrder(result, restorePosition: position)
        if let items = try? await reader.screen.loadChapterListState(), !items.isEmpty {
            return items
        }
        return reader.localChapterListItems()
    }
}
