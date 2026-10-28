import UIKit
import shared

@MainActor
final class ReaderChapterListRefreshCoordinator: NSObject {
    private struct Context {
        let bookURL: String
        let origin: String
        let index: Int
        let url: String?
        let title: String
        let position: Int

        init?(_ controller: ReaderContainerViewController) {
            guard let book = controller.book, book.bookUrl == controller.bookURL else { return nil }
            bookURL = controller.bookURL
            origin = book.origin
            index = controller.chapterIndex
            url = controller.currentChapterURL
            title = controller.chapterTitle
            position = controller.currentCharacterOffset()
        }

        var progress: ReaderProgressQueue.Snapshot {
            .init(chapterIndex: index, chapterTitle: title, chapterPosition: position)
        }

        func matches(_ controller: ReaderContainerViewController) -> Bool {
            matchesBook(in: controller) && index == controller.chapterIndex && url == controller.currentChapterURL
        }

        func matchesBook(in controller: ReaderContainerViewController) -> Bool {
            guard let book = controller.book, bookURL == controller.bookURL else { return false }
            return matches(book)
        }

        func matches(_ book: Book) -> Bool {
            book.bookUrl == bookURL && book.origin == origin
        }

        func target(in chapters: [BookChapter]) -> ReaderProgressQueue.Snapshot {
            if let url, !url.isEmpty,
                let chapter = chapters.first(where: { $0.url == url || $0.getAbsoluteURL() == url })
            {
                return .init(chapterIndex: Int(chapter.index), chapterTitle: chapter.title, chapterPosition: position)
            }
            let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty,
                let chapter = chapters.first(where: {
                    $0.title.trimmingCharacters(in: .whitespacesAndNewlines) == title
                })
            {
                return .init(chapterIndex: Int(chapter.index), chapterTitle: chapter.title, chapterPosition: position)
            }
            return .init(
                chapterIndex: min(max(index, 0), max(chapters.count - 1, 0)),
                chapterTitle: nil, chapterPosition: 0)
        }
    }

    private var requestID: UUID?
    private var lifetimeID: UUID?
    private var task: Task<[ReaderChapterListItem], Error>?
    private weak var owner: ReaderContainerViewController?

    override init() {
        super.init()
        for name in [
            UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
            UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification,
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(interrupted(_:)), name: name, object: nil)
        }
    }

    deinit {
        task?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    func cancel(in controller: ReaderContainerViewController) {
        requestID = nil
        task?.cancel()
        // Keep the task until the shared terminal callback and read-only recovery settle.
        if task != nil { controller.loadingIndicator.stopAnimating() }
    }

    func refresh(in controller: ReaderContainerViewController) async throws -> [ReaderChapterListItem] {
        try Task.checkCancellation()
        let previous = task
        cancel(in: controller)
        _ = try? await previous?.value
        try Task.checkCancellation()
        guard isVisible(controller), let context = Context(controller), let book = controller.book else {
            throw CancellationError()
        }
        controller.chapterLoadCoordinator.cancel(in: controller)
        let client = controller.screen.catalogRefresh
        let session = try client.begin(before: ReaderCatalogSnapshot(book: book, chapters: controller.chapters))
        let id = UUID()
        requestID = id
        lifetimeID = id
        owner = controller
        controller.loadingIndicator.startAnimating()
        let task = Task { @MainActor [weak self, weak controller] () throws -> [ReaderChapterListItem] in
            guard let self, let controller else {
                client.finish(session, persisted: nil, acceptsPresentation: false)
                throw CancellationError()
            }
            do {
                try self.check(id, context: context, in: controller)
                let result = try await client.refresh(session)
                try self.check(id, context: context, in: controller)
                guard context.matches(result.book) else { throw CancellationError() }
                if result.chapters.isEmpty {
                    client.finish(
                        session, persisted: ReaderCatalogSnapshot(book: result.book, chapters: []),
                        acceptsPresentation: false)
                    controller.updateMenuState()
                    return []
                }

                var target = try self.target(for: result, in: controller)
                var payload: ReaderChapterPayload
                while true {
                    payload = try await client.load(session, index: target.chapterIndex)
                    try self.check(id, context: context, in: controller)
                    let latest = try self.target(for: result, in: controller)
                    if latest.chapterIndex != target.chapterIndex {
                        target = latest
                        continue
                    }
                    target = latest
                    break
                }
                let persisted = ReaderCatalogSnapshot(book: result.book, chapters: result.chapters)
                guard persisted.hasSameCatalog(as: ReaderCatalogSnapshot(book: payload.book, chapters: payload.chapters)),
                    Int(payload.chapter.index) == target.chapterIndex
                else { throw CancellationError() }
                let title = payload.displayTitle.isEmpty ? payload.chapter.title : payload.displayTitle
                let keepsPresentation =
                    Int(payload.chapter.index) == controller.chapterIndex
                    && payload.chapter.url == controller.currentChapterURL
                    && title == controller.chapterTitle && payload.content == controller.chapterContent
                    && target.chapterPosition == controller.currentCharacterOffset()
                    && payload.book.config.imageStyle == controller.book?.config.imageStyle
                if keepsPresentation {
                    controller.currentChapterSameTitleRemoved = payload.sameTitleRemoved
                    controller.readMenu.updateChapter(title: title, source: payload.book.originName, url: payload.chapter.url)
                    controller.refreshChromeSnapshot(force: true)
                } else {
                    controller.cancelPageTurnForContentChange()
                    controller.applyPayload(payload, restorePosition: target.chapterPosition)
                }
                guard context.matchesBook(in: controller), let displayed = Context(controller) else {
                    throw CancellationError()
                }
                client.finish(session, persisted: persisted, acceptsPresentation: true, presented: target)
                controller.updateMenuState()
                // Only the newly accepted generation may flush after the catalog commit.
                await controller.screen.flushReadingProgressNow()
                try self.check(id, context: displayed, in: controller, checksChapter: true)
                let items = try await controller.screen.loadChapterListState()
                try self.check(id, context: displayed, in: controller, checksChapter: true)
                return items.isEmpty ? controller.localChapterListItems() : items
            } catch {
                if client.isCurrent(session) {
                    // Recovery must not inherit the cancelled UI task's cancellation flag.
                    await Task { @MainActor in
                        await self.recover(session, client: client, context: context, in: controller)
                    }.value
                } else {
                    client.finish(session, persisted: nil, acceptsPresentation: false)
                }
                throw error
            }
        }
        self.task = task
        defer {
            if lifetimeID == id {
                lifetimeID = nil
                requestID = nil
                self.task = nil
                controller.loadingIndicator.stopAnimating()
            }
        }
        let items = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        guard requestID == id, context.matchesBook(in: controller) else { throw CancellationError() }
        return items
    }

    private func target(
        for result: BookDetailRefreshResult, in controller: ReaderContainerViewController
    ) throws -> ReaderProgressQueue.Snapshot {
        guard let current = Context(controller) else { throw CancellationError() }
        guard let plan = result.epubReflowPlan else { return current.target(in: result.chapters) }
        if let location = plan.mapLocation(
            chapterIndex: Int32(clamping: current.index), chapterPosition: Int32(clamping: current.position)),
            result.chapters.contains(where: { $0.index == location.chapterIndex })
        {
            return .init(
                chapterIndex: Int(location.chapterIndex), chapterTitle: location.chapterTitle,
                chapterPosition: Int(location.chapterPosition))
        }
        // Never carry an old range-relative offset into a different EPUB range.
        return ReaderCatalogSnapshot(book: result.book, chapters: result.chapters).progress
    }

    private func recover(
        _ session: ReaderCatalogRefreshClient.Session, client: ReaderCatalogRefreshClient,
        context: Context, in controller: ReaderContainerViewController
    ) async {
        var persisted = try? await client.read(session)
        guard let initial = persisted else {
            client.finish(session, persisted: nil, acceptsPresentation: false)
            return
        }
        if let before = session.before, before.hasSameCatalog(as: initial),
            (!session.didStartMutation || before.progress == initial.progress),
            context.matchesBook(in: controller), let current = Context(controller),
            initial.chapters.contains(where: {
                Int($0.index) == current.index && ($0.url == current.url || $0.getAbsoluteURL() == current.url)
            })
        {
            client.finish(session, persisted: initial, acceptsPresentation: true, presented: current.progress)
            return
        }

        // A cancelled directory transaction may have committed. Its durable location wins over all old UI stages.
        if client.isCurrent(session), context.matchesBook(in: controller) {
            controller.chapterLoadCoordinator.cancel(in: controller)
        }
        var restored = false
        for _ in 0..<2 {
            guard let snapshot = persisted, context.matchesBook(in: controller), client.isCurrent(session),
                !snapshot.chapters.isEmpty, canRestorePresentation(in: controller),
                snapshot.chapters.contains(where: { Int($0.index) == snapshot.progress.chapterIndex })
            else { break }
            do {
                let payload = try await client.load(session, index: snapshot.progress.chapterIndex)
                let latest = try await client.read(session)
                persisted = latest
                guard latest.hasSameCatalog(as: snapshot), latest.progress == snapshot.progress else { continue }
                guard context.matchesBook(in: controller), client.isCurrent(session),
                    canRestorePresentation(in: controller),
                    Int(payload.chapter.index) == latest.progress.chapterIndex,
                    latest.hasSameCatalog(as: ReaderCatalogSnapshot(book: payload.book, chapters: payload.chapters))
                else { break }
                controller.cancelPageTurnForContentChange()
                controller.applyPayload(payload, restorePosition: latest.progress.chapterPosition)
                restored = true
                break
            } catch {
                break
            }
        }
        let accepted = client.finish(session, persisted: persisted, acceptsPresentation: restored)
        if accepted {
            controller.updateMenuState()
            if !restored, let persisted, !persisted.chapters.isEmpty,
                context.matchesBook(in: controller), !controller.isMovingFromParent, !controller.isBeingDismissed,
                controller.navigationController?.viewControllers.contains(where: { $0 === controller }) == true
            {
                // Hidden readers retain a persisted-progress reload for their next appearance.
                controller.chapterLoadCoordinator.load(
                    in: controller, index: persisted.progress.chapterIndex, restorePosition: nil,
                    restoresBookProgress: true)
            }
        }
    }

    private func check(
        _ id: UUID, context: Context, in controller: ReaderContainerViewController, checksChapter: Bool = false
    ) throws {
        try Task.checkCancellation()
        guard requestID == id, context.matchesBook(in: controller), isVisible(controller),
            !checksChapter || context.matches(controller)
        else { throw CancellationError() }
    }

    @objc private func interrupted(_ notification: Notification) {
        guard let owner else { return }
        if let scene = notification.object as? UIScene,
            owner.viewIfLoaded?.window?.windowScene !== scene
        {
            return
        }
        cancel(in: owner)
    }

    private func canRestorePresentation(in controller: ReaderContainerViewController) -> Bool {
        !controller.isMovingFromParent && !controller.isBeingDismissed
            && controller.navigationController?.topViewController === controller
            && !controller.chapterLoadCoordinator.isLoading
    }

    private func isVisible(_ controller: ReaderContainerViewController) -> Bool {
        let directory = controller.presentedViewController as? AndroidChapterListSheetViewController
        let hasVisibleDirectory =
            directory?.viewIfLoaded?.window != nil
            && directory?.isBeingDismissed == false
        let window = controller.viewIfLoaded?.window ?? directory?.viewIfLoaded?.window
        return !controller.isMovingFromParent && !controller.isBeingDismissed
            && controller.navigationController?.topViewController === controller
            && (controller.viewIfLoaded?.window != nil || hasVisibleDirectory)
            && window?.windowScene?.activationState == .foregroundActive
    }
}
