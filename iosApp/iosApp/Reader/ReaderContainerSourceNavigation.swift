import SafariServices
import UIKit
import shared

@MainActor
enum BookSourceChangeNavigation {
    static func flushReadingProgress(for bookURL: String, in controllers: [UIViewController]) async {
        for case let reader as ReaderContainerViewController in controllers where reader.bookURL == bookURL {
            await reader.screen.flushReadingProgressNow()
        }
    }

    static func publish(
        _ result: BookDetailRefreshResult,
        replacing originalBookURL: String,
        to controllers: [UIViewController],
        excluding initiator: UIViewController?
    ) {
        for controller in controllers where controller !== initiator {
            if let detail = controller as? AndroidReplicaBookDetailViewController {
                detail.adoptCommittedSourceChange(result, replacing: originalBookURL)
            } else if let reader = controller as? ReaderContainerViewController, reader.bookURL == originalBookURL {
                reader.chapterLoadCoordinator.cancel(in: reader)
                reader.chapterListRefreshCoordinator.cancel(in: reader)
                reader.adoptSourceChangeResult(result)
                reader.chapterLoadCoordinator.load(
                    in: reader, index: Int(result.book.durChapterIndex), restorePosition: nil,
                    restoresBookProgress: true)
            }
        }
    }
}

extension ReaderContainerViewController {
    var readerActionChapterIndex: Int { chapterMessageCoordinator.requestedIndex ?? chapterIndex }

    var readerActionChapterURL: String? {
        guard let index = chapterMessageCoordinator.requestedIndex else { return currentChapterURL }
        return chapters[safe: index]?.getAbsoluteURL()
    }

    func publishCommittedSourceChange(
        _ result: BookDetailRefreshResult,
        replacing originalBookURL: String,
        to controllers: [UIViewController]
    ) {
        BookSourceChangeNavigation.publish(result, replacing: originalBookURL, to: controllers, excluding: self)
    }

    func openReaderBookInfoFromMenu() {
        setMenuVisible(false)
        guard let bookURL = book?.bookUrl.nilIfEmpty ?? bookURL.nilIfEmpty else {
            showToast(L10n.BookDetail.unavailable)
            return
        }
        navigationController?.pushViewController(AndroidReplicaBookDetailViewController(bookURL: bookURL), animated: true)
    }

    func openCurrentChapterSourceFromMenu() {
        setMenuVisible(false)
        let chapterURL = readerActionChapterURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard chapterURL.isEmpty == false else {
            showToast(L10n.Reader.chapterSourceInfoUnavailable)
            return
        }
        guard let url = URL(string: chapterURL), url.scheme?.hasPrefix("http") == true else {
            UIPasteboard.general.string = chapterURL
            showToast(L10n.BookDetail.copied)
            return
        }
        present(SFSafariViewController(url: url), animated: true)
    }
}
