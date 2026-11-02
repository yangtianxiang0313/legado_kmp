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

/// The directory panel's cancellable UI flight, separate from the real persisted reversal above.
@MainActor
final class ReaderChapterListPanelOrderOperation {
    private var task: Task<Void, Never>?
    private var requestID: UUID?
    var isRunning: Bool { task != nil }

    deinit { task?.cancel() }

    func cancel() { task?.cancel() }

    func reverse(
        action: @escaping () async throws -> [ReaderChapterListItem],
        canApply: @escaping () -> Bool,
        onStarted: () -> Void,
        onItems: @escaping ([ReaderChapterListItem]) -> Void,
        onError: @escaping (Error) -> Void,
        onFinished: @escaping () -> Void
    ) {
        guard task == nil else { return }
        let id = UUID()
        requestID = id
        task = Task { @MainActor [weak self] in
            defer {
                if let self, self.requestID == id {
                    self.requestID = nil
                    self.task = nil
                    onFinished()
                }
            }
            do {
                try Task.checkCancellation()
                guard canApply() else { throw CancellationError() }
                // onReverse retains responsibility for applying a real committed order to the reader.
                let items = try await action()
                guard !Task.isCancelled, self?.requestID == id, canApply() else { return }
                onItems(items)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError), self?.requestID == id, canApply() else { return }
                onError(error)
            }
        }
        onStarted()
    }
}

/// Retain the visible chapter and its fractional viewport offset across row/order updates.
@MainActor
enum ReaderChapterListViewportAnchor {
    static func preserve(
        in table: UITableView, urlAtRow: (Int) -> String?, rowForURL: (String) -> Int?, updates: () -> Void
    ) {
        let row = table.indexPathsForVisibleRows?.min()
        let url = row.flatMap { urlAtRow($0.row) }
        let offset = row.map { table.rectForRow(at: $0).minY - table.contentOffset.y }
        updates()
        table.layoutIfNeeded()
        guard let url, let offset, let row = rowForURL(url) else { return }
        let minY = -table.adjustedContentInset.top
        let maxY = max(minY, table.contentSize.height - table.bounds.height + table.adjustedContentInset.bottom)
        let y = table.rectForRow(at: IndexPath(row: row, section: 0)).minY - offset
        table.setContentOffset(CGPoint(x: 0, y: min(maxY, max(minY, y))), animated: false)
    }
}
