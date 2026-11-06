import SafariServices
import UIKit
import shared

@MainActor
enum BookSourceChangeNavigation {
    static func flushReadingProgress(for bookURL: String, in controllers: [UIViewController]) async {
        for controller in controllers {
            if let reader = controller as? ReaderContainerViewController, reader.bookURL == bookURL {
                await reader.screen.flushReadingProgressNow()
            } else if let reader = controller as? MangaReaderViewController, reader.bookURL == bookURL {
                await reader.flushReadingProgressForBookInfo()
            }
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
            } else if let reader = controller as? ReaderContainerViewController,
                reader.bookURL == originalBookURL
            {
                reader.chapterLoadCoordinator.cancel(in: reader)
                reader.chapterListRefreshCoordinator.cancel(in: reader)
                reader.adoptSourceChangeResult(result)
                reader.chapterLoadCoordinator.load(
                    in: reader, index: Int(result.book.durChapterIndex), restorePosition: nil,
                    restoresBookProgress: true)
            } else if let reader = controller as? MangaReaderViewController,
                reader.bookURL == originalBookURL
            {
                reader.adoptBookInfoSourceChange(result, replacing: originalBookURL)
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
        BookSourceChangeNavigation.publish(
            result, replacing: originalBookURL, to: controllers, excluding: self)
    }

    func openReaderBookInfoFromMenu() {
        guard let book, !book.bookUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showToast(L10n.BookDetail.unavailable)
            return
        }
        let bookURL = self.bookURL
        let chapterIndex = self.chapterIndex
        let chapterURL = currentChapterURL
        let requestedIndex = chapterMessageCoordinator.requestedIndex
        let pageIndex = currentPageIndex
        let position = currentCharacterOffset()
        bookInfoNavigation.open(
            expectedOrigin: book.origin,
            isCurrent: { [weak self] in
                guard let self else { return false }
                return self.bookURL == bookURL && self.chapterIndex == chapterIndex
                    && self.chapterMessageCoordinator.requestedIndex == requestedIndex
                    && self.currentChapterURL == chapterURL && self.currentPageIndex == pageIndex
                    && self.currentCharacterOffset() == position
            })
    }

    func makeBookInfoNavigation() -> ReaderBookInfoNavigation {
        ReaderBookInfoNavigation(
            owner: self, bookURL: { [weak self] in self?.bookURL ?? "" },
            currentBook: { [weak self] in self?.book },
            snapshot: { [weak self] in
                guard let controller = self else { throw CancellationError() }
                let progress: (chapterIndex: Int, position: Int)?
                if controller.canNavigateReaderPages,
                    controller.pages.indices.contains(controller.currentPageIndex)
                {
                    controller.stageProgress(immediate: true)
                    progress = (controller.chapterIndex, controller.currentCharacterOffset())
                } else {
                    progress = nil
                }
                try await controller.screen.flushReadingProgressForNavigation()
                let persisted = try await controller.screen.resolveCurrentBook()
                if let progress,
                    Int(persisted.durChapterIndex) != progress.chapterIndex
                        || Int(persisted.durChapterPos) != progress.position
                {
                    throw NSError(
                        domain: "io.legado.readerProgress", code: 1,
                        userInfo: [
                            NSLocalizedDescriptionKey: L10n.text(
                                "reader.chapter.consumer.progress_not_saved", "阅读进度尚未保存，请稍后重试")
                        ])
                }
                return persisted
            },
            canInteract: { [weak self] in
                guard let self else { return false }
                return !self.exitCoordinator.isBusy && !self.isAutoChangingSource
                    && !self.screen.catalogRefresh.isBlockingObservation
                    && self.presentedViewController == nil
            },
            onWillNavigate: { [weak self] in self?.setMenuVisible(false) })
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
