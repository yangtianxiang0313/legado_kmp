import shared
import UIKit

@MainActor
enum BookDetailNavigationActions {
    static func closeRemovedBook(_ url: String, in navigation: UINavigationController) {
        let remaining = navigation.viewControllers.filter { controller in
            if let reader = controller as? ReaderContainerViewController { return reader.bookURL != url }
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
