import Foundation
import shared

/// Keeps the existing shared bookmark stream and persistence/export facade.
final class AllBookmarkScreenAdapter {
    private let bindings = ScreenBindingController(owner: "AllBookmarkScreen")
    private var bookmarkFacade: BookmarkFacade?
    private var bootstrapError: SharedRuntimeError?
    private var initialLoadTask: Task<Void, Never>?
    private var generation = UUID()
    private var receivedSnapshot = false

    var onBookmarksChange: (([Bookmark]) -> Void)?
    var onLoadFailure: ((Error) -> Void)?

    func bootstrap() -> Result<Void, SharedRuntimeError> {
        unbind()
        bookmarkFacade = nil
        bootstrapError = nil
        receivedSnapshot = false
        let generation = self.generation

        switch SharedRuntime.bookmarkFacade() {
        case .success(let bookmarkFacade):
            self.bookmarkFacade = bookmarkFacade
            bindings.bind(
                bookmarkFacade.watchAllBookmarks { [weak self] bookmarks in
                    DispatchQueue.main.async {
                        guard let self, self.generation == generation else { return }
                        self.receivedSnapshot = true
                        self.onBookmarksChange?(bookmarks)
                    }
                })
            // The watch API has no error callback. Read once so an initial
            // storage failure is not misrepresented as an empty list.
            initialLoadTask = Task { @MainActor [weak self] in
                defer {
                    if self?.generation == generation { self?.initialLoadTask = nil }
                }
                do {
                    let bookmarks = try await bookmarkFacade.getAllBookmarks()
                    try Task.checkCancellation()
                    guard let self, self.generation == generation, !self.receivedSnapshot else { return }
                    self.receivedSnapshot = true
                    self.onBookmarksChange?(bookmarks)
                } catch {
                    guard !Task.isCancelled, let self,
                        self.generation == generation, !self.receivedSnapshot
                    else { return }
                    self.onLoadFailure?(error)
                }
            }
            return .success(())
        case .failure(let error):
            bootstrapError = error
            return .failure(error)
        }
    }

    func exportBookmarks(markdown: Bool) async throws -> String {
        try Task.checkCancellation()
        let facade = try requireFacade()
        if markdown { return try await facade.exportBookmarksAsMarkdown() }
        return try await facade.exportBookmarksAsJson()
    }

    func updateBookmark(_ bookmark: Bookmark) async throws {
        try Task.checkCancellation()
        try await requireFacade().updateBookmark(bookmark: bookmark)
    }

    func deleteBookmark(_ bookmark: Bookmark) async throws {
        try Task.checkCancellation()
        try await requireFacade().deleteBookmark(time: bookmark.time)
    }

    func unbind() {
        generation = UUID()
        initialLoadTask?.cancel()
        initialLoadTask = nil
        bindings.cancelAll()
    }

    private func requireFacade() throws -> BookmarkFacade {
        if let bookmarkFacade { return bookmarkFacade }
        throw bootstrapError
            ?? SharedRuntimeError(
                operation: "AllBookmarkScreen",
                message: NSLocalizedString(
                    "all_bookmark.runtime_unavailable", value: "书签服务暂不可用，请稍后重试", comment: "Bookmark runtime unavailable"
                ),
                underlying: nil
            )
    }
}
