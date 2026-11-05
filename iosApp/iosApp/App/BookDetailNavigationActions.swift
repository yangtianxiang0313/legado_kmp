import shared
import UIKit

@MainActor
enum BookDetailNavigationActions {
    static func bookEditor(
        book: Book, adapter: AndroidReplicaBookDetailAdapter, expectedBookURL: String,
        onSave: @escaping (Book) -> Void
    ) -> UINavigationController {
        let editor = BookInfoEditViewController(
            book: book,
            saveEditedBook: { name, author, cover, intro, type in
                try await adapter.saveEditedBookInfo(
                    expectedBookURL: expectedBookURL, name: name, author: author, coverURL: cover,
                    intro: intro, bookType: type)
            },
            createCoverSearchSession: { result, progress, finished in
                try await adapter.createCoverSearchSession(
                    expectedBookURL: expectedBookURL, onResult: result, onProgress: progress,
                    onFinished: finished)
            },
            onSave: onSave)
        let navigation = UINavigationController(rootViewController: editor)
        navigation.modalPresentationStyle = .fullScreen
        return navigation
    }

    static func closeRemovedBook(_ url: String, in navigation: UINavigationController) {
        let remaining = navigation.viewControllers.filter { controller in
            if let reader = controller as? ReaderContainerViewController { return reader.bookURL != url }
            if let reader = controller as? MangaReaderViewController { return reader.bookURL != url }
            if let detail = controller as? AndroidReplicaBookDetailViewController { return detail.bookURL != url }
            return true
        }
        guard !remaining.isEmpty, remaining.count != navigation.viewControllers.count else { return }
        navigation.setViewControllers(remaining, animated: navigation.viewIfLoaded?.window != nil)
    }

    static func search(author: Bool, book: Book?, seed: BookDetailPreviewSeed?, from owner: UIViewController) {
        let keyword = (author ? book?.getRealAuthor() ?? seed?.author : book?.name ?? seed?.name)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let keyword, !keyword.isEmpty else { return }
        owner.navigationController?.pushViewController(
            AndroidReplicaSearchViewController(initialKeyword: keyword), animated: true)
    }
}
