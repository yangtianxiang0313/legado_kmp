import UIKit
import shared

@MainActor
enum ReaderTocBookmarkEditCoordinator {
    enum Mutation {
        case saved(Bookmark)
        case deleted(Bookmark)

        func applying(to bookmarks: [Bookmark]) -> [Bookmark] {
            switch self {
            case .saved(let updated):
                return bookmarks.map { $0.time == updated.time ? updated : $0 }
            case .deleted(let bookmark):
                return bookmarks.filter { $0.time != bookmark.time }
            }
        }
    }

    static func makeEditor(
        bookmark: Bookmark,
        screen: ReaderBookmarkListProviding,
        interfaceStyle: UIUserInterfaceStyle,
        onCommit: @escaping @MainActor (Mutation) -> Void
    ) -> UIViewController {
        let editor = ReaderTocBookmarkEditorViewController(
            bookmark: bookmark,
            onSave: { @MainActor bookText, content in
                let updated = updatedBookmark(bookmark, bookText: bookText, content: content)
                try await screen.updateBookmark(updated)
                onCommit(.saved(updated))
            },
            onDelete: { @MainActor in
                try await screen.deleteBookmark(bookmark)
                onCommit(.deleted(bookmark))
            })
        editor.overrideUserInterfaceStyle = interfaceStyle
        return editor
    }

    static func updatedBookmark(_ bookmark: Bookmark, bookText: String, content: String) -> Bookmark {
        Bookmark(
            time: bookmark.time,
            bookName: bookmark.bookName,
            bookAuthor: bookmark.bookAuthor,
            chapterIndex: bookmark.chapterIndex,
            chapterPos: bookmark.chapterPos,
            chapterName: bookmark.chapterName,
            bookText: bookText,
            content: content
        )
    }

    static func makeDeleteConfirmation(onDelete: @escaping () -> Void) -> UIAlertController {
        let alert = UIAlertController(
            title: L10n.Reader.bookmarkDeleteTitle,
            message: L10n.AllBookmark.deleteConfirm,
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.Common.delete, style: .destructive) { _ in onDelete() })
        return alert
    }
}
