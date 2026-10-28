import UIKit
import shared

@MainActor
final class ReaderContentEditingCoordinator {
    private struct ChapterIdentity: Equatable {
        let bookURL: String
        let index: Int
        let chapterURL: String
    }

    private weak var reader: ReaderContainerViewController?
    private weak var editor: ReaderContentEditViewController?

    init(reader: ReaderContainerViewController) {
        self.reader = reader
    }

    func present(from presenter: UIViewController? = nil) {
        guard let reader, editor == nil,
            let identity = identity(in: reader), reader.canNavigateReaderPages, !reader.chapterContent.isEmpty
        else {
            reader?.showToast("当前章节内容尚未加载，无法编辑")
            return
        }
        let presenter = presenter ?? reader
        guard presenter.presentedViewController == nil else {
            reader.showToast(L10n.Reader.operationBusy)
            return
        }
        reader.setMenuVisible(false)
        reader.stopAutoPage(showMessage: false)
        let anchor = reader.currentCharacterOffset()
        let position =
            ReaderSearchSelectionMapper.contentPosition(
                for: anchor, content: reader.chapterContent, pages: reader.pages) ?? 0
        let controller = ReaderContentEditViewController(
            chapterTitle: reader.chapterTitle,
            content: reader.chapterContent,
            initialPosition: position,
            onReset: { [weak self] in
                guard let self else { throw CancellationError() }
                let reader = try self.requireReader(identity)
                let payload = try await reader.screen.resetEditedChapter(
                    index: identity.index, expectedURL: identity.chapterURL)
                // A completed cache write remains real even if the reader has since changed.
                _ = try self.requireReader(identity)
                reader.applyPayload(payload, restorePosition: anchor)
                return payload.content
            },
            rawChapterTitle: reader.chapters[reader.chapterIndex].title,
            onRename: { [weak self] rawTitle in
                guard let self else { throw CancellationError() }
                let reader = try self.requireReader(identity)
                let payload = try await reader.screen.renameEditedChapter(
                    index: identity.index, expectedURL: identity.chapterURL, title: rawTitle)
                _ = try self.requireReader(identity)
                reader.applyPayload(payload, restorePosition: anchor)
                return reader.chapterTitle
            },
            onSave: { [weak self] content in
                guard let self else { throw CancellationError() }
                let reader = try self.requireReader(identity)
                let payload = try await reader.screen.saveEditedChapter(
                    index: identity.index, expectedURL: identity.chapterURL, content: content)
                _ = try self.requireReader(identity)
                reader.applyPayload(payload, restorePosition: anchor)
                reader.showToast(L10n.Reader.saveContent)
            }
        )
        editor = controller
        controller.canEdit = { [weak self] in
            guard let self else { return false }
            return (try? self.requireReader(identity)) != nil
        }
        controller.modalPresentationStyle = .fullScreen
        presenter.present(controller, animated: true)
    }

    private func requireReader(_ identity: ChapterIdentity) throws -> ReaderContainerViewController {
        try Task.checkCancellation()
        guard let reader, self.identity(in: reader) == identity,
            !reader.isBeingDismissed, !reader.isMovingFromParent,
            reader.navigationController?.topViewController === reader,
            UIApplication.shared.applicationState == .active,
            let editor, editor.presentingViewController != nil, !editor.isBeingDismissed
        else {
            throw changedChapterError()
        }
        return reader
    }

    private func identity(in reader: ReaderContainerViewController) -> ChapterIdentity? {
        guard reader.chapters.indices.contains(reader.chapterIndex), let chapterURL = reader.currentChapterURL,
            reader.chapters[reader.chapterIndex].url == chapterURL
        else { return nil }
        return ChapterIdentity(bookURL: reader.bookURL, index: reader.chapterIndex, chapterURL: chapterURL)
    }

    private func changedChapterError() -> NSError {
        NSError(
            domain: "io.legado.kmp.ios", code: -1,
            userInfo: [NSLocalizedDescriptionKey: "当前书籍或章节已变化，请重新打开编辑页面。"])
    }
}
