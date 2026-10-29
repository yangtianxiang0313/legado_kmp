import UIKit
import shared

@MainActor
enum ReaderAutoPageChapterPreview {
    struct Prepared {
        let view: ReaderRenderView
        let pages: [ReaderPageLayout]
    }

    static func prepare(in reader: ReaderContainerViewController, index: Int) async throws -> Prepared {
        guard let preferences = reader.preferences, let runtime = reader.runtimeConfig else {
            throw CancellationError()
        }
        let bookURL = reader.bookURL
        let origin = reader.book?.origin
        let sourceChapter = reader.currentChapterURL
        let bounds = reader.renderView.bounds
        let policy = reader.currentReaderSafeAreaPolicy()
        let theme = policy.applying(to: reader.themeController)
        let mode = reader.doubleHorizontalPageMode(in: bounds)
        let paginationBounds = reader.paginationBounds(for: bounds, doubleHorizontalPageMode: mode)
        let style = preferences.effectiveReaderStyle(
            userInterfaceStyle: reader.traitCollection.userInterfaceStyle)
        // Peek prepares content and cache only, never the displayed reading position.
        let payload = try await reader.screen.peekChapter(index: index)
        try Task.checkCancellation()
        guard payload.book.bookUrl == bookURL, payload.book.origin == origin,
            Int(payload.chapter.index) == index
        else { throw CancellationError() }
        let title = payload.displayTitle.nilIfEmpty ?? payload.chapter.title
        let layout = try await reader.screen.paginateChapter(
            chapterIndex: index, chapterTitle: title, content: payload.content,
            style: style, runtime: runtime.reader,
            viewport: ReaderViewport(
                width: Float(paginationBounds.width), height: Float(paginationBounds.height)),
            imageStyle: payload.book.config.imageStyle)
        try Task.checkCancellation()
        guard reader.bookURL == bookURL, reader.book?.origin == origin,
            reader.currentChapterURL == sourceChapter,
            reader.renderView.bounds == bounds, reader.currentReaderSafeAreaPolicy() == policy,
            reader.doubleHorizontalPageMode(in: bounds) == mode
        else { throw CancellationError() }
        let pages = try await ReaderLayoutEngine().paginateAsync(
            layout: layout, in: paginationBounds, theme: theme, traits: reader.traitCollection
        )
        .pages
        try Task.checkCancellation()
        guard reader.bookURL == bookURL, reader.book?.origin == origin,
            reader.currentChapterURL == sourceChapter,
            reader.renderView.bounds == bounds, reader.currentReaderSafeAreaPolicy() == policy,
            reader.doubleHorizontalPageMode(in: bounds) == mode,
            reader.preferences?.effectiveReaderStyle(
                userInterfaceStyle: reader.traitCollection.userInterfaceStyle
            ).isEqual(style) == true,
            let currentRuntime = reader.runtimeConfig,
            !ReaderPaginationCoordinator.runtimeRequiresPagination(previous: runtime, updated: currentRuntime)
        else { throw CancellationError() }
        guard let first = pages.first else { throw CancellationError() }
        let preview = ReaderRenderView(frame: bounds)
        preview.theme = theme
        preview.bookURL = bookURL
        preview.chrome = reader.makeChromeSnapshot(
            pageIndex: 0, chapterIndex: index, chapterTitle: title, pageCount: pages.count)
        preview.setPageLayouts(
            primary: first, trailing: mode.isEnabledForLegacyDualPageMode ? pages[safe: 1] : nil)
        preview.layoutIfNeeded()
        return Prepared(view: preview, pages: pages)
    }
}
