import UIKit
import shared

@MainActor
final class ReaderSourceChangeActions {
    private struct ChapterContext {
        let bookURL: String
        let index: Int
        let url: String?

        @MainActor init(_ reader: ReaderContainerViewController) {
            bookURL = reader.bookURL
            index = reader.chapterIndex
            url = reader.currentChapterURL
        }
    }

    private weak var reader: ReaderContainerViewController?
    private var commitTask: Task<Void, Never>?
    private var operationID: UUID?
    private weak var pickerNavigation: UINavigationController?
    private(set) var isCommitting = false
    var isBusy: Bool {
        operationID != nil || isCommitting
    }

    init(reader: ReaderContainerViewController) {
        self.reader = reader
    }

    func cancelPreparation() {
        guard !isCommitting else { return }
        // Our picker owns a presentation without leaving the reader's identity.
        if let reader, let pickerNavigation, ownsPicker(pickerNavigation, reader: reader),
            !reader.isMovingFromParent, !reader.isBeingDismissed,
            reader.navigationController?.topViewController === reader,
            reader.navigationController?.isBeingDismissed != true
        {
            return
        }
        (pickerNavigation?.viewControllers.first as? ChangeSourceViewController)?.cancelPendingBookSelection()
        pickerNavigation = nil
        operationID = nil
        reader?.loadingIndicator.stopAnimating()
    }

    private func cancelPreparation(ifCurrent id: UUID) {
        guard operationID == id, !isCommitting else { return }
        // Cancelling a preview releases its request, not the still-visible picker's ownership.
        operationID = nil
        reader?.loadingIndicator.stopAnimating()
    }

    func presentReaderSourceChangePicker(mode: ReaderSourceChangeMode = .book) {
        guard let reader else { return }
        guard !isCommitting, !reader.isAutoChangingSource, reader.presentedViewController == nil else { return }
        cancelPreparation()
        guard reader.book?.isLocal != true else {
            reader.showToast(L10n.BookDetail.changeSourceEmpty)
            return
        }
        guard reader.book?.origin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            reader.showToast(L10n.BookDetail.editSourceUnavailable)
            return
        }
        let currentOrigin = reader.book?.origin ?? ""
        let screenRef = reader.screen
        let controller = ChangeSourceViewController(
            currentSourceUrl: currentOrigin,
            currentBook: reader.book,
            titleText: mode.title,
            sessionFactory: { onCandidate, onProgress, onFinished in
                try await screenRef.createSourceChangeSearchSession(
                    onCandidate: onCandidate,
                    onProgress: onProgress,
                    onFinished: onFinished
                )
            }
        )
        if case .chapter = mode {
            configureChapterSelection(controller, reader: reader)
        } else {
            configureBookSelection(controller, reader: reader)
        }
        controller.onDeletedCurrentSource = { [weak self] in self?.recoverDeletedCurrentSource() }
        let navigation = ChangeSourceNavigationController(rootViewController: controller)
        pickerNavigation = navigation
        reader.stopAutoPage(showMessage: false)
        reader.present(navigation, animated: true)
    }

    private func configureBookSelection(_ controller: ChangeSourceViewController, reader: ReaderContainerViewController) {
        let context = ChapterContext(reader)
        let sourceURL = reader.book?.origin
        var requestID: UUID?
        var committed: BookDetailRefreshResult?
        controller.wholeBookSelection = .init(
            canSelect: { [weak self, weak reader, weak controller] in
                guard let self, let reader, let controller else { return false }
                return self.matchesChapter(context) && reader.book?.origin == sourceURL
                    && !self.isCommitting && controller.navigationController === self.pickerNavigation
                    && self.pickerNavigation.map { self.ownsPicker($0, reader: reader) } == true
            },
            prepare: { [weak self, weak reader] candidate in
                guard let self, let reader, self.matchesChapter(context), !self.isCommitting else { throw CancellationError() }
                let id = UUID()
                requestID = id
                self.operationID = id
                reader.chapterListRefreshCoordinator.cancel(in: reader)
                reader.chapterLoadCoordinator.cancel(in: reader)
                try await reader.screen.stopReadAloud()
                try Task.checkCancellation()
                return try await reader.screen.prepareSourceChange(candidateBookUrl: candidate.bookUrl, sourceUrl: candidate.sourceUrl)
            },
            commit: { [weak self, weak reader] prepared in
                guard let self, let reader, let id = requestID, self.operationID == id,
                    self.matchesChapter(context), prepared.originalBookUrl == context.bookURL, !self.isCommitting
                else { throw CancellationError() }
                self.isCommitting = true
                defer { self.isCommitting = false }
                let targets = reader.navigationController?.viewControllers ?? []
                let result = try await reader.screen.commitSourceChange(prepared)
                reader.adoptSourceChangeResult(result)
                reader.publishCommittedSourceChange(result, replacing: context.bookURL, to: targets)
                committed = result
            },
            onSettled: { [weak self] in
                guard let self else { return }
                if self.operationID == requestID { self.operationID = nil }
                requestID = nil
            },
            onCommitted: { [weak self, weak reader] in
                guard let self, let reader, let result = committed else { return }
                committed = nil
                self.pickerNavigation = nil
                guard self.isActive(reader), reader.bookURL == result.book.bookUrl else { return }
                reader.loadingIndicator.stopAnimating()
                reader.chapterLoadCoordinator.load(
                    in: reader, index: Int(result.book.durChapterIndex), restorePosition: Int(result.book.durChapterPos),
                    successMessage: L10n.Reader.changeSourceSuccess)
            })
    }

    private func recoverDeletedCurrentSource() {
        guard let reader, isActive(reader), !isCommitting, reader.presentedViewController == nil else { return }
        cancelPreparation()
        let previousURL = reader.bookURL
        let targets = reader.navigationController?.viewControllers ?? []
        isCommitting = true
        reader.chapterLoadCoordinator.cancel(in: reader)
        reader.loadingIndicator.startAnimating()
        commitTask = Task { @MainActor [self, reader] in
            defer {
                isCommitting = false
                commitTask = nil
                reader.loadingIndicator.stopAnimating()
            }
            do {
                guard let result = try await reader.screen.autoChangeSource(chapterIndex: reader.chapterIndex) else {
                    if isActive(reader) { reader.showToast("自动换源失败\n没有有效源") }
                    return
                }
                reader.adoptSourceChangeResult(result)
                reader.publishCommittedSourceChange(result, replacing: previousURL, to: targets)
                isCommitting = false
                reader.chapterLoadCoordinator.load(
                    in: reader, index: Int(result.book.durChapterIndex),
                    restorePosition: Int(result.book.durChapterPos),
                    successMessage: L10n.Reader.changeSourceSuccess)
            } catch {
                if isActive(reader) { reader.showToast("自动换源失败\n\(error.userFacingMessage)") }
            }
        }
    }

    private func isActive(_ reader: ReaderContainerViewController) -> Bool {
        reader.viewIfLoaded?.window != nil && !reader.isMovingFromParent && !reader.isBeingDismissed
            && reader.navigationController?.topViewController === reader
    }

    private func ownsPicker(_ picker: UINavigationController, reader: ReaderContainerViewController) -> Bool {
        guard let presenter = picker.presentingViewController, presenter.presentedViewController === picker else { return false }
        var page: UIViewController? = reader
        while let current = page {
            if current === presenter { return true }
            page = current.parent
        }
        return false
    }

    private func configureChapterSelection(
        _ controller: ChangeSourceViewController, reader: ReaderContainerViewController
    ) {
        let context = ChapterContext(reader)
        var requestID: UUID?
        controller.chapterSelection = .init(
            title: reader.chapterTitle,
            load: { [weak self, weak reader] candidate in
                guard let self, let reader, self.matchesChapter(context), !self.isCommitting else {
                    throw CancellationError()
                }
                try Task.checkCancellation()
                let id = UUID()
                requestID = id
                self.operationID = id
                do {
                    let toc = try await reader.screen.loadChapterSourceToc(
                        candidateBookUrl: candidate.bookUrl, sourceUrl: candidate.sourceUrl, chapterIndex: context.index
                    )
                    try Task.checkCancellation()
                    guard self.operationID == id, requestID == id, self.matchesChapter(context) else {
                        throw CancellationError()
                    }
                    return toc
                } catch {
                    self.cancelPreparation(ifCurrent: id)
                    throw error
                }
            },
            replace: { [weak self, weak reader] candidate, chapter in
                guard let self, let reader, let id = requestID, self.operationID == id,
                    self.matchesChapter(context), !self.isCommitting
                else { throw CancellationError() }
                try Task.checkCancellation()
                self.isCommitting = true
                defer { self.isCommitting = false }
                // This call persists content; do not discard a successful write on dismissal.
                try await reader.screen.replaceChapterContentFromSource(
                    currentChapterIndex: context.index, candidateBookUrl: candidate.bookUrl,
                    sourceUrl: candidate.sourceUrl, candidateChapterIndex: Int(chapter.index))
            },
            onReplaced: { [weak self, weak reader] in
                guard let self, let reader, let id = requestID else { return }
                if self.operationID == id { self.operationID = nil }
                requestID = nil
                guard self.matchesChapter(context), self.isActive(reader) else { return }
                reader.setMenuVisible(false)
                reader.chapterLoadCoordinator.load(
                    in: reader, index: context.index, restorePosition: 0,
                    successMessage: L10n.Reader.chapterChangeSourceSuccess)
            },
            onCancel: { [weak self] in
                guard let self, let id = requestID else { return }
                requestID = nil
                self.cancelPreparation(ifCurrent: id)
            })
    }

    private func matchesChapter(_ context: ChapterContext) -> Bool {
        guard let reader, !reader.isMovingFromParent, !reader.isBeingDismissed,
            reader.navigationController?.topViewController === reader
        else { return false }
        return reader.bookURL == context.bookURL && reader.chapterIndex == context.index
            && reader.currentChapterURL == context.url && !reader.isAutoChangingSource
    }
}

enum ReaderSourceChangeMode {
    case book
    case chapter

    fileprivate var title: String {
        switch self {
        case .book:
            return L10n.Reader.bookChangeSource
        case .chapter:
            return L10n.Reader.chapterChangeSource
        }
    }
}
