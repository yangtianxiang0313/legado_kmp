import UIKit
import shared

/// BookInfoActivity.startReadActivity and bookshelf entry share the same book-type dispatch.
@MainActor
enum BookReadingDestination {
    static func open(
        _ book: Book, from presenter: UIViewController,
        chapterIndex: Int? = nil, chapterPosition: Int? = nil
    ) {
        guard presenter.canPerformNavigationAction, presenter.presentedViewController == nil else { return }
        if book.isWebFile {
            presenter.navigationController?.pushViewController(
                AndroidReplicaBookDetailViewController(bookURL: book.bookUrl), animated: true)
            return
        }
        let index = max(chapterIndex ?? Int(book.durChapterIndex), 0)
        if book.isAudio {
            presenter.present(
                AudioPlayViewController(
                    bookUrl: book.bookUrl, initialChapterIndex: chapterIndex,
                    initialChapterPosition: chapterPosition), animated: true)
        } else if book.isLocal && LocalBookFileBinding.shared.format(book: book) == "pdf",
            let navigation = presenter.navigationController
        {
            let controller = PdfReaderViewController(bookURL: book.bookUrl, initialChapterIndex: chapterIndex)
            navigation.pushViewController(controller.configuredForDrillDownPresentation(), animated: true)
        } else if book.isImage, let navigation = presenter.navigationController {
            let controller = MangaReaderViewController(
                bookURL: book.bookUrl, initialChapterIndex: index, initialChapterPosition: chapterPosition)
            navigation.pushViewController(controller.configuredForDrillDownPresentation(), animated: true)
        } else if let navigation = presenter.navigationController {
            let controller = ReaderContainerViewController(
                bookURL: book.bookUrl, initialChapterIndex: index,
                initialChapterPosition: chapterPosition)
            controller.isInBookshelf = !book.isNotShelf
            _ = controller.configuredForDrillDownPresentation()
            navigation.pushViewController(controller, animated: true)
        }
    }
}
