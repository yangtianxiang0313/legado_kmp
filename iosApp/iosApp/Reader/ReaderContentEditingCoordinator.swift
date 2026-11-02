import UIKit
import shared

@MainActor
final class ReaderContentEditingCoordinator {
    private struct ChapterIdentity: Equatable {
        let bookURL: String
        let index: Int
        let chapterURL: String
        let origin: String
    }

    private final class EditSession {
        let chapter: ChapterIdentity
        weak var editor: ReaderContentEditViewController?

        init(chapter: ChapterIdentity) { self.chapter = chapter }
    }

    private weak var reader: ReaderContainerViewController?
    private var session: EditSession?
    private var isUpdatingChapter = false

    init(reader: ReaderContainerViewController) {
        self.reader = reader
    }

    func present(from presenter: UIViewController? = nil) {
        guard let reader else { return }
        guard session?.editor == nil, !isUpdatingChapter else {
            reader.showToast(L10n.Reader.operationBusy)
            return
        }
        guard let identity = identity(in: reader), reader.canNavigateReaderPages, !reader.chapterContent.isEmpty else {
            reader.showToast(
                NSLocalizedString(
                    "reader.content_edit.unavailable", value: "当前章节内容尚未加载，无法编辑", comment: ""))
            return
        }
        let presenter = presenter ?? reader
        guard presenter.presentedViewController == nil,
            reader.navigationController?.topViewController === reader,
            !reader.isBeingDismissed, !reader.isMovingFromParent,
            !presenter.isBeingPresented, !presenter.isBeingDismissed, !presenter.isMovingFromParent,
            UIApplication.shared.applicationState == .active,
            let window = reader.viewIfLoaded?.window, !window.isHidden, window.alpha > 0,
            presenter.viewIfLoaded?.window === window,
            window.windowScene?.activationState == .foregroundActive
        else {
            reader.showToast(L10n.Reader.operationBusy)
            return
        }
        reader.setMenuVisible(false)
        reader.stopAutoPage(showMessage: false)
        let anchor = reader.currentCharacterOffset()
        let position =
            ReaderSearchSelectionMapper.contentPosition(
                for: anchor, content: reader.chapterContent, pages: reader.pages) ?? 0
        let session = EditSession(chapter: identity)
        let controller = ReaderContentEditViewController(
            chapterTitle: reader.chapterTitle,
            content: reader.chapterContent,
            initialPosition: position,
            onReset: { [weak self] in
                guard let self else { throw CancellationError() }
                let payload = try await self.updateChapter(in: session, anchor: anchor) { screen in
                    try await screen.resetEditedChapter(index: identity.index, expectedURL: identity.chapterURL)
                }
                return payload.content
            },
            rawChapterTitle: reader.chapters[reader.chapterIndex].title,
            onRename: { [weak self] rawTitle in
                guard let self else { throw CancellationError() }
                let payload = try await self.updateChapter(in: session, anchor: anchor) { screen in
                    try await screen.renameEditedChapter(
                        index: identity.index, expectedURL: identity.chapterURL, title: rawTitle)
                }
                return payload.displayTitle.nilIfEmpty ?? payload.chapter.title
            },
            onSave: { [weak self] content in
                guard let self else { throw CancellationError() }
                _ = try await self.updateChapter(in: session, anchor: anchor) { screen in
                    try await screen.saveEditedChapter(
                        index: identity.index, expectedURL: identity.chapterURL, content: content)
                }
                self.reader?.showToast(L10n.Reader.editContentSaved)
            }
        )
        session.editor = controller
        self.session = session
        controller.canEdit = { [weak self] in
            guard let self else { return false }
            return (try? self.requireReader(session)) != nil
        }
        controller.modalPresentationStyle = .fullScreen
        presenter.present(controller, animated: true)
    }

    private func updateChapter(
        in session: EditSession, anchor: Int,
        action: (ReaderScreenAdapter) async throws -> ReaderChapterPayload
    ) async throws -> ReaderChapterPayload {
        let reader = try requireReader(session)
        guard !isUpdatingChapter else {
            throw NSError(
                domain: "io.legado.kmp.ios", code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Reader.operationBusy])
        }
        // Swift cancellation need not cancel the shared write. Keep it exclusive until it settles.
        isUpdatingChapter = true
        defer { isUpdatingChapter = false }
        let payload = try await action(reader.screen)
        // A completed cache write is real; only its stale UI delivery is rejected here.
        _ = try requireReader(session)
        guard payload.book.bookUrl == session.chapter.bookURL, payload.book.origin == session.chapter.origin,
            Int(payload.chapter.index) == session.chapter.index, payload.chapter.url == session.chapter.chapterURL
        else { throw changedChapterError() }
        reader.applyPayload(payload, restorePosition: anchor)
        return payload
    }

    private func requireReader(_ session: EditSession) throws -> ReaderContainerViewController {
        try Task.checkCancellation()
        guard self.session === session, let reader, identity(in: reader) == session.chapter,
            !reader.isBeingDismissed, !reader.isMovingFromParent,
            reader.navigationController?.topViewController === reader,
            let editor = session.editor, editor.hasCurrentEditingPresentation
        else {
            throw changedChapterError()
        }
        return reader
    }

    private func identity(in reader: ReaderContainerViewController) -> ChapterIdentity? {
        guard let book = reader.book, book.bookUrl == reader.bookURL,
            reader.chapters.indices.contains(reader.chapterIndex), let chapterURL = reader.currentChapterURL,
            reader.chapters[reader.chapterIndex].url == chapterURL
        else { return nil }
        return ChapterIdentity(
            bookURL: reader.bookURL, index: reader.chapterIndex, chapterURL: chapterURL, origin: book.origin)
    }

    private func changedChapterError() -> NSError {
        NSError(
            domain: "io.legado.kmp.ios", code: -1,
            userInfo: [
                NSLocalizedDescriptionKey: NSLocalizedString(
                    "reader.content_edit.context_changed", value: "当前书籍、章节或页面状态已变化，请重新打开编辑页面。", comment: "")
            ])
    }
}
