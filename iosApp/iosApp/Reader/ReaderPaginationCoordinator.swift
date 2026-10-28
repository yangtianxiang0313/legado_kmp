import UIKit
import shared

final class ReaderPaginationCoordinator {
    static func preferencesRequirePagination(
        previous: AppUiPreferences?, updated: AppUiPreferences, userInterfaceStyle: UIUserInterfaceStyle
    ) -> Bool {
        guard let previous else { return true }
        let old = previous.effectiveReaderStyle(userInterfaceStyle: userInterfaceStyle)
        let new = updated.effectiveReaderStyle(userInterfaceStyle: userInterfaceStyle)
        // Info colors repaint chrome only. Preserve the page, selection and scroll offset.
        return !new.isEqual(
            old.androidCopy(
                tipColorHex: .some(new.tipColorHex), tipDividerColorHex: .some(new.tipDividerColorHex)))
    }

    static func runtimeRequiresPagination(previous: AppRuntimeConfig?, updated: AppRuntimeConfig) -> Bool {
        guard let previous else { return true }
        let old = previous.reader
        let new = updated.reader
        // Only render/layout inputs may rebuild pages. A speed ACK must not restart an in-flight reveal.
        return old.pageAnimation != new.pageAnimation
            || old.shareLayout != new.shareLayout
            || old.readStyleIndex != new.readStyleIndex
            || old.comicStyleIndex != new.comicStyleIndex
            || old.textFullJustify != new.textFullJustify
            || old.textBottomJustify != new.textBottomJustify
            || old.hideStatusBar != new.hideStatusBar
            || old.hideNavigationBar != new.hideNavigationBar
            || old.chineseMode != new.chineseMode
            || old.useZhLayout != new.useZhLayout
            || old.isComic != new.isComic
            || previous.paddingDisplayCutouts != updated.paddingDisplayCutouts
            || previous.readBarStyleFollowPage != updated.readBarStyleFollowPage
    }

    private struct ChapterIdentity: Equatable {
        let bookURL: String
        let index: Int
        let url: String?
    }

    private let layoutEngine = ReaderLayoutEngine()
    private var task: Task<Void, Never>?
    private var requestID: UUID?
    private var chapter: ChapterIdentity?
    private var anchor: Int?
    private var displayedPageIndex: Int?
    private var hasRestoredChapter = false
    private var isApplyingPagination = false
    private var isSuspended = false
    private(set) var needsPagination = false

    deinit {
        task?.cancel()
    }

    func beginChapter(bookURL: String, index: Int, url: String?, restoreLocation: Int) {
        cancel()
        chapter = ChapterIdentity(bookURL: bookURL, index: index, url: url)
        anchor = max(restoreLocation, 0)
        displayedPageIndex = nil
        hasRestoredChapter = false
        needsPagination = true
    }

    func suspend() {
        isSuspended = true
        cancel()
    }

    func resume() {
        isSuspended = false
    }

    private func cancel() {
        requestID = nil
        task?.cancel()
        task = nil
        needsPagination = chapter != nil
    }

    @MainActor
    func canNavigate(in controller: ReaderContainerViewController) -> Bool {
        matchesChapter(in: controller) && hasRestoredChapter && !isApplyingPagination && !isSuspended
            && !controller.chapterLoadCoordinator.isLoading
            && !controller.bookSettingsCoordinator.isSaving
            && !controller.sourceChangeActions.isBusy
            && controller.loadFailureView.isHidden
    }

    @MainActor
    func currentPosition(in controller: ReaderContainerViewController) -> Int {
        guard matchesChapter(in: controller) else { return 0 }
        capturePageSelection(in: controller)
        return anchor ?? 0
    }

    @MainActor
    func progressPosition(in controller: ReaderContainerViewController) -> Int? {
        guard canNavigate(in: controller),
            controller.pages.indices.contains(controller.currentPageIndex)
        else { return nil }
        return currentPosition(in: controller)
    }

    @MainActor
    func repaginate(
        in controller: ReaderContainerViewController,
        restoreLocation: Int?,
        hasLaidOutRenderView: Bool
    ) {
        capturePageSelection(in: controller)
        cancel()
        guard matchesChapter(in: controller) else { return }
        if anchor == nil {
            anchor = max(restoreLocation ?? 0, 0)
        }
        guard !isSuspended,
            let preferences = controller.preferences,
            let runtimeConfig = controller.runtimeConfig,
            hasLaidOutRenderView,
            controller.view.window != nil
        else { return }

        // Never paginate the initial payload against UIView's provisional bounds.
        let bounds = controller.renderView.bounds
        guard bounds.width > 0, bounds.height > 0,
            bounds.size == controller.view.bounds.size
        else { return }

        controller.textSelectionCoordinator.dismiss(clearSelection: true)
        let chapter = self.chapter
        let chapterTitle = controller.chapterTitle
        let chapterContent = controller.chapterContent
        let imageStyle = controller.book?.config.imageStyle
        let safeAreaPolicy = controller.currentReaderSafeAreaPolicy()
        let renderTheme = safeAreaPolicy.applying(to: controller.themeController)
        let style = preferences.effectiveReaderStyle(userInterfaceStyle: controller.traitCollection.userInterfaceStyle)
        let doublePageMode = controller.doubleHorizontalPageMode(in: bounds)
        let paginationBounds = controller.paginationBounds(for: bounds, doubleHorizontalPageMode: doublePageMode)
        let requestID = UUID()
        self.requestID = requestID
        needsPagination = false
        task = Task { @MainActor [weak self, weak controller] in
            guard let self, let controller, let chapter else { return }
            defer {
                if self.requestID == requestID {
                    self.task = nil
                }
            }
            do {
                let chapterLayout = try await controller.screen.paginateChapter(
                    chapterIndex: chapter.index,
                    chapterTitle: chapterTitle,
                    content: chapterContent,
                    style: style,
                    runtime: runtimeConfig.reader,
                    viewport: ReaderViewport(
                        width: Float(paginationBounds.width), height: Float(paginationBounds.height)),
                    imageStyle: imageStyle
                )
                // Shared async bridges need not cooperate with Task cancellation.
                guard !Task.isCancelled, self.requestID == requestID,
                    self.chapter == chapter, self.matchesChapter(in: controller)
                else { return }
                guard controller.view.window != nil,
                    controller.renderView.bounds == bounds,
                    controller.currentReaderSafeAreaPolicy() == safeAreaPolicy,
                    controller.doubleHorizontalPageMode(in: bounds) == doublePageMode
                else {
                    self.needsPagination = true
                    controller.view.setNeedsLayout()
                    return
                }

                let pagination = self.layoutEngine.paginate(
                    layout: chapterLayout, in: paginationBounds, theme: renderTheme)
                self.capturePageSelection(in: controller)
                self.isApplyingPagination = true
                controller.pages = pagination.pages
                let searchAnchor = controller.updateSearchSelection()
                let restoreAnchor = searchAnchor ?? self.anchor ?? 0
                if let searchAnchor { self.anchor = searchAnchor }
                controller.currentPageIndex = controller.pageIndex(for: restoreAnchor)
                controller.readAloudService.updateBlocks(controller.chapterReadAloudBlocks())
                controller.restartReadAloudAfterChapterSwitchIfNeeded()
                controller.renderCurrentPage()
                controller.updateMenuState()
                self.displayedPageIndex = controller.currentPageIndex
                self.hasRestoredChapter = true
                if restoreAnchor == Int.max {
                    self.anchor = controller.pages[safe: controller.currentPageIndex]?.characterOffset ?? 0
                }
                self.isApplyingPagination = false
                controller.chapterMessageCoordinator.finishLoading(afterRendering: true)
                controller.chapterLoadCoordinator.didRenderChapter(in: controller)
                controller.updateMenuState()
                ReaderReadAloudStateSupport.applyPlayback(in: controller)
                controller.stageProgress(immediate: false)
            } catch {
                guard !Task.isCancelled, self.requestID == requestID,
                    self.chapter == chapter, self.matchesChapter(in: controller)
                else { return }
                if controller.loadFailureView.isShowingLoading {
                    controller.showReaderLoadFailure(message: error.userFacingMessage, requestedIndex: chapter.index)
                } else {
                    controller.showToast(error.userFacingMessage)
                }
            }
        }
    }

    @MainActor
    func renderCurrentPage(in controller: ReaderContainerViewController) {
        if controller.textSelectionCoordinator.isSelecting { controller.textSelectionCoordinator.dismiss(clearSelection: true) }
        controller.cancelPageTurnForContentChange()
        guard controller.pages.indices.contains(controller.currentPageIndex) else {
            controller.renderView.searchResultRange = nil
            controller.renderView.pageLayout = nil
            controller.scrollPagerView.render(
                pages: [],
                theme: controller.readerRenderTheme(),
                bookURL: controller.bookURL,
                highlightedBlockIndex: nil,
                selectionRange: nil,
                chromeProvider: { _ in controller.emptyChrome() },
                currentPageIndex: 0,
                dualPageMode: false
            )
            return
        }
        if controller.isScrollPageMode {
            let bounds = controller.renderView.bounds.width > 0 ? controller.renderView.bounds : controller.view.bounds
            let activeDoubleHorizontalPageMode = controller.doubleHorizontalPageMode(in: bounds)
            if activeDoubleHorizontalPageMode.isEnabledForLegacyDualPageMode {
                controller.currentPageIndex = min(
                    max((controller.currentPageIndex / 2) * 2, 0), max(controller.pages.count - 1, 0))
            }
            controller.renderView.isHidden = true
            controller.scrollPagerView.isHidden = false
            controller.renderView.pageLayout = nil
            let theme = controller.readerRenderTheme()
            controller.scrollPagerView.render(
                pages: controller.pages,
                theme: theme,
                bookURL: controller.bookURL,
                highlightedBlockIndex: controller.readAloudHighlightedBlockIndex(),
                selectionRange: controller.shouldPresentSearchSelection ? controller.pendingSearchSelectionRange : nil,
                searchResultRange: controller.pendingSearchSelectionRange,
                chromeProvider: { [weak controller] index in
                    controller?.makeChromeSnapshot(pageIndex: index)
                        ?? ReaderChromeSnapshot(
                            title: nil, headerLeft: nil, headerCenter: nil, headerRight: nil, footerLeft: nil, footerCenter: nil,
                            footerRight: nil)
                },
                currentPageIndex: controller.currentPageIndex,
                doubleHorizontalPageMode: activeDoubleHorizontalPageMode,
                retainsImageLine: controller.book?.isImage != true
                    && controller.book?.config.imageStyle?.caseInsensitiveCompare("TEXT") == .orderedSame
            )
            controller.stageProgress(immediate: false)
            Task { [screen = controller.screen] in
                try? await screen.onPageChanged()
            }
            return
        }
        controller.renderView.isHidden = false
        controller.scrollPagerView.isHidden = true
        controller.renderView.theme = controller.readerRenderTheme()
        controller.refreshChromeSnapshot(force: true)
        controller.renderView.selectionRange =
            controller.shouldPresentSearchSelection ? controller.pendingSearchSelectionRange : nil
        controller.renderView.searchResultRange = controller.pendingSearchSelectionRange
        controller.renderView.highlightedBlockIndex = controller.readAloudHighlightedBlockIndex()
        let bounds = controller.renderView.bounds.width > 0 ? controller.renderView.bounds : controller.view.bounds
        let dualPageMode = controller.shouldUseDualPageMode(in: bounds)
        if dualPageMode {
            controller.currentPageIndex = min(max((controller.currentPageIndex / 2) * 2, 0), max(controller.pages.count - 1, 0))
        }
        controller.renderView.setPageLayouts(
            primary: controller.pages[controller.currentPageIndex],
            trailing: dualPageMode ? controller.pages[safe: controller.currentPageIndex + 1] : nil
        )
        controller.stageProgress(immediate: false)
        Task { [screen = controller.screen] in
            try? await screen.onPageChanged()
        }
    }

    @MainActor
    private func matchesChapter(in controller: ReaderContainerViewController) -> Bool {
        chapter
            == ChapterIdentity(
                bookURL: controller.bookURL, index: controller.chapterIndex, url: controller.currentChapterURL)
    }

    @MainActor
    private func capturePageSelection(in controller: ReaderContainerViewController) {
        guard matchesChapter(in: controller), hasRestoredChapter, !isApplyingPagination,
            let page = controller.pages[safe: controller.currentPageIndex],
            displayedPageIndex != controller.currentPageIndex
        else { return }
        // A passive layout/render keeps the source anchor, not the new page's floor.
        anchor = page.characterOffset
        displayedPageIndex = controller.currentPageIndex
    }
}
