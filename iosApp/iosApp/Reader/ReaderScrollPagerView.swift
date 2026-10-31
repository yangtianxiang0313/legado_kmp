import UIKit

final class ReaderScrollPagerView: UIView, UIScrollViewDelegate {
    enum Boundary {
        case previous
        case next
    }

    enum AutoReadAdvanceResult {
        case advanced(distance: CGFloat)
        case reachedEnd(remainingDistance: CGFloat)
        case noContent
        case layoutUnavailable
        // Touch tracking, dragging, deceleration or an existing manual scroll animation.
        case paused
        case invalidDistance
    }

    private struct RenderState {
        let pages: [ReaderPageLayout]
        let chromes: [ReaderChromeSnapshot]
        let theme: ReaderThemeController
        let bookURL: String
        let highlightedBlockIndex: Int?
        let selectionRange: NSRange?
        let searchResultRange: NSRange?
        let doubleHorizontalPageMode: ReaderDoubleHorizontalPageMode
        let retainsImageLine: Bool
    }

    private let chromeView = ReaderRenderView()
    private let scrollView = UIScrollView()
    private var renderState: RenderState?
    private var pageViews: [Int: ReaderPageContentView] = [:]
    private var autoReadContinuationViews: [ReaderPageContentView] = []
    private var isProgrammaticScroll = false
    private var isUpdatingContent = false
    private var lastReportedPageIndex = 0
    private var isBoundaryRequestInFlight = false
    private var lastLaidOutPageSlotHeight: CGFloat = 0
    private var chapterMessageVisible = false
    private let renderedPageRadius = 3

    var onPageIndexChange: ((Int) -> Void)?
    var onBoundaryRequest: ((Boundary) -> Bool)?

    var chapterMessageContentFrame: CGRect {
        chromeView.convert(chromeView.chapterMessageContentFrame, to: self)
    }

    func setChapterMessageVisible(_ visible: Bool) {
        chapterMessageVisible = visible
        scrollView.isHidden = visible
        scrollView.accessibilityElementsHidden = visible
        rebuildAccessibilityElements()
    }

    var isInteracting: Bool {
        scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating
    }

    // Android AutoPager uses the whole ReadView height, not the text rect or page overlap.
    var autoReadViewportHeight: CGFloat {
        guard bounds.width.isFinite, bounds.height.isFinite,
            bounds.width > 0, bounds.height > 0
        else { return 0 }
        return bounds.height
    }

    var hasAutoReadContinuation: Bool {
        !autoReadContinuationViews.isEmpty
    }

    func prioritizeNavigationBackGesture(_ gesture: UIGestureRecognizer) {
        scrollView.panGestureRecognizer.require(toFail: gesture)
    }

    func prioritizeTextSelectionGesture(_ gesture: UIGestureRecognizer) {
        scrollView.panGestureRecognizer.require(toFail: gesture)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        chromeView.pageLayout = nil
        chromeView.isUserInteractionEnabled = false
        addSubview(chromeView)
        scrollView.delegate = self
        scrollView.alwaysBounceVertical = true
        scrollView.alwaysBounceHorizontal = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.decelerationRate = .normal
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.contentInset = .zero
        scrollView.scrollIndicatorInsets = .zero
        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let previousPageSlotHeight = lastLaidOutPageSlotHeight
        let previousContentOffset = scrollView.contentOffset
        let wasUpdatingContent = isUpdatingContent
        isUpdatingContent = true
        chromeView.frame = bounds
        if let renderState {
            chromeView.theme = renderState.theme
            chromeView.chrome = renderState.chromes[safe: lastReportedPageIndex]
        }
        updateScrollFrame()
        layoutPageViews()
        reconcileContentOffsetAfterLayout(previousPageSlotHeight: previousPageSlotHeight, previousContentOffset: previousContentOffset)
        lastLaidOutPageSlotHeight = pageSlotHeight
        isUpdatingContent = wasUpdatingContent
        if !isProgrammaticScroll {
            reportVisiblePage()
        }
    }

    func render(
        pages: [ReaderPageLayout],
        theme: ReaderThemeController,
        bookURL: String,
        highlightedBlockIndex: Int?,
        selectionRange: NSRange?,
        searchResultRange: NSRange? = nil,
        chromeProvider: (Int) -> ReaderChromeSnapshot,
        currentPageIndex: Int,
        dualPageMode: Bool = false,
        retainsImageLine: Bool = false
    ) {
        render(
            pages: pages,
            theme: theme,
            bookURL: bookURL,
            highlightedBlockIndex: highlightedBlockIndex,
            selectionRange: selectionRange,
            searchResultRange: searchResultRange,
            chromeProvider: chromeProvider,
            currentPageIndex: currentPageIndex,
            doubleHorizontalPageMode: ReaderDoubleHorizontalPageMode.fromLegacyDualPageMode(dualPageMode),
            retainsImageLine: retainsImageLine
        )
    }

    func render(
        pages: [ReaderPageLayout],
        theme: ReaderThemeController,
        bookURL: String,
        highlightedBlockIndex: Int?,
        selectionRange: NSRange?,
        searchResultRange: NSRange? = nil,
        chromeProvider: (Int) -> ReaderChromeSnapshot,
        currentPageIndex: Int,
        doubleHorizontalPageMode: ReaderDoubleHorizontalPageMode,
        retainsImageLine: Bool = false
    ) {
        let wasUpdatingContent = isUpdatingContent
        isUpdatingContent = true
        defer { isUpdatingContent = wasUpdatingContent }
        clearAutoReadContinuation()
        renderState = RenderState(
            pages: pages,
            chromes: pages.indices.map { chromeProvider($0) },
            theme: theme,
            bookURL: bookURL,
            highlightedBlockIndex: highlightedBlockIndex,
            selectionRange: selectionRange,
            searchResultRange: searchResultRange,
            doubleHorizontalPageMode: doubleHorizontalPageMode,
            retainsImageLine: retainsImageLine
        )
        lastReportedPageIndex = leadingPageIndex(forPageIndex: min(max(currentPageIndex, 0), max(pages.count - 1, 0)))
        isBoundaryRequestInFlight = false
        chromeView.theme = theme
        chromeView.bookURL = bookURL
        chromeView.highlightedBlockIndex = nil
        chromeView.selectionRange = nil
        chromeView.searchResultRange = nil
        chromeView.pageLayout = nil
        chromeView.chrome = chromeProvider(lastReportedPageIndex)
        updateScrollFrame()
        rebuildPageViews()
        layoutPageViews()
        scrollToPage(index: lastReportedPageIndex, animated: false)
        lastLaidOutPageSlotHeight = pageSlotHeight
    }

    /// Supplies one visual-only next-chapter slot; an empty array explicitly removes it.
    func setAutoReadContinuation(pages: [ReaderPageLayout]) {
        let wasUpdatingContent = isUpdatingContent
        isUpdatingContent = true
        defer { isUpdatingContent = wasUpdatingContent }
        clearAutoReadContinuation()
        if let renderState, !renderState.pages.isEmpty {
            for page in pages.prefix(isDualPageMode ? 2 : 1) {
                let contentView = ReaderPageContentView()
                contentView.bookURL = renderState.bookURL
                contentView.theme = renderState.theme
                contentView.pageLayout = page
                contentView.backgroundColor = .clear
                contentView.isOpaque = false
                contentView.isUserInteractionEnabled = false
                contentView.isAccessibilityElement = false
                contentView.accessibilityElementsHidden = true
                contentView.accessibilityLabel = nil
                scrollView.addSubview(contentView)
                autoReadContinuationViews.append(contentView)
            }
        }
        layoutPageViews()
    }

    func scrollToPage(index: Int, animated: Bool) {
        guard pageCount > 0 else { return }
        let clamped = min(max(index, 0), pageCount - 1)
        let targetIndex = leadingPageIndex(forPageIndex: clamped)
        let targetSlot = slotIndex(forPageIndex: clamped)
        let pageHeight = pageSlotHeight
        ensureRenderedWindow(centeredAt: targetIndex)
        layoutPageViews()
        isProgrammaticScroll = true
        scrollView.setContentOffset(CGPoint(x: 0, y: CGFloat(targetSlot) * pageHeight), animated: animated)
        if animated == false {
            isProgrammaticScroll = false
        }
        reportPageIndexIfNeeded(targetIndex)
    }

    @discardableResult
    func scrollByViewport(forward: Bool, animated: Bool) -> Bool {
        guard pageCount > 0 else { return false }
        let pageHeight = pageSlotHeight
        if isDualPageMode {
            let currentSlot = Int((scrollView.contentOffset.y / pageHeight).rounded())
            let targetSlot = currentSlot + (forward ? 1 : -1)
            guard targetSlot >= 0, targetSlot < spreadCount else { return false }
            isProgrammaticScroll = true
            scrollView.setContentOffset(CGPoint(x: 0, y: CGFloat(targetSlot) * pageHeight), animated: animated)
            if animated == false {
                isProgrammaticScroll = false
                reportVisiblePage()
            }
            return true
        }
        let maxOffset = max(scrollView.contentSize.height - pageHeight, 0)
        let delta = scrollPageDistance(forward: forward)
        let target = scrollView.contentOffset.y + (forward ? delta : -delta)
        if forward, target >= maxOffset - 1, scrollView.contentOffset.y < maxOffset - 1 {
            isProgrammaticScroll = true
            scrollView.setContentOffset(CGPoint(x: 0, y: maxOffset), animated: animated)
            if animated == false {
                isProgrammaticScroll = false
                reportVisiblePage()
            }
            return true
        }
        if forward, scrollView.contentOffset.y >= maxOffset - 1 {
            return false
        }
        if !forward, target <= 1, scrollView.contentOffset.y > 1 {
            isProgrammaticScroll = true
            scrollView.setContentOffset(.zero, animated: animated)
            if animated == false {
                isProgrammaticScroll = false
                reportVisiblePage()
            }
            return true
        }
        if !forward, scrollView.contentOffset.y <= 1 {
            return false
        }
        isProgrammaticScroll = true
        scrollView.setContentOffset(
            CGPoint(x: 0, y: min(max(target, 0), maxOffset)),
            animated: animated
        )
        if animated == false {
            isProgrammaticScroll = false
            reportVisiblePage()
        }
        return true
    }

    private func scrollPageDistance(forward: Bool) -> CGFloat {
        let viewport = currentVisibleRect().offsetBy(dx: scrollView.contentOffset.x, dy: scrollView.contentOffset.y)
        guard viewport.height > 0 else { return 0 }
        var lines: [(frame: CGRect, isImage: Bool)] = []
        for pageView in pageViews.values {
            guard let page = pageView.pageLayout else { continue }
            for fragment in page.textFragments {
                let frame = pageView.convert(pageView.viewRect(for: fragment.frame), to: scrollView)
                if isScrollLineVisible(frame, in: viewport, isImage: false) { lines.append((frame, false)) }
            }
            for attachment in page.attachmentFragments {
                guard case .remoteImage = attachment.source else { continue }
                let frame = pageView.convert(pageView.viewRect(for: attachment.frame), to: scrollView)
                if isScrollLineVisible(frame, in: viewport, isImage: true) { lines.append((frame, true)) }
            }
        }
        lines.sort { $0.frame.minY < $1.frame.minY }
        guard let first = lines.first, let last = lines.last,
            renderState?.retainsImageLine == true || !lines.contains(where: \.isImage)
        else { return viewport.height }
        // ScrollPageDelegate retains the actual visible line, including its paragraph spacing.
        let distance =
            forward
            ? last.frame.minY - viewport.minY
            : viewport.maxY - first.frame.maxY
        return min(max(distance, 0), viewport.height)
    }

    private func isScrollLineVisible(_ frame: CGRect, in viewport: CGRect, isImage: Bool) -> Bool {
        guard frame.minY.isFinite, frame.height.isFinite, frame.height > 0,
            frame.maxY > viewport.minY, frame.minY < viewport.maxY
        else { return false }
        if isImage || (frame.minY >= viewport.minY && frame.maxY <= viewport.maxY)
            || (frame.minY <= viewport.minY && frame.maxY >= viewport.maxY)
        {
            return true
        }
        // TextLine.isVisible ignores edge rows with 60% or less of their glyph box visible.
        let visibleHeight = min(frame.maxY, viewport.maxY) - max(frame.minY, viewport.minY)
        return visibleHeight / frame.height > 0.6
    }

    /// Advances one frame without requesting chapters; the caller owns reachedEnd handling.
    @discardableResult
    func advanceAutoRead(by distance: CGFloat) -> AutoReadAdvanceResult {
        guard distance.isFinite, distance >= 0 else { return .invalidDistance }
        guard pageCount > 0 else { return .noContent }
        guard !isInteracting, !isProgrammaticScroll else { return .paused }
        guard !isUpdatingContent, autoReadViewportHeight > 0,
            scrollView.bounds.width.isFinite, scrollView.bounds.height.isFinite,
            scrollView.bounds.width > 0, scrollView.bounds.height > 0,
            scrollView.contentSize.height.isFinite,
            scrollView.contentSize.height >= scrollView.bounds.height,
            scrollView.contentOffset.y.isFinite
        else { return .layoutUnavailable }

        let maxOffset = max(scrollView.contentSize.height - pageSlotHeight, 0)
        let currentOffset = scrollView.contentOffset.y
        // Never clamp a bottom overscroll backwards during automatic reading.
        guard currentOffset < maxOffset else {
            reportVisiblePage()
            return .reachedEnd(remainingDistance: distance)
        }
        let startOffset = max(currentOffset, 0)
        let advancedDistance = min(distance, maxOffset - startOffset)
        let targetOffset = min(startOffset + advancedDistance, maxOffset)
        if targetOffset != currentOffset {
            isProgrammaticScroll = true
            scrollView.setContentOffset(CGPoint(x: 0, y: targetOffset), animated: false)
            isProgrammaticScroll = false
        }
        // Also moves the rendered window and reports the actual visible leading page in dual mode.
        reportVisiblePage()
        if targetOffset >= maxOffset {
            return .reachedEnd(remainingDistance: max(distance - advancedDistance, 0))
        }
        return .advanced(distance: advancedDistance)
    }

    func selectionTarget(at point: CGPoint) -> (pageIndex: Int, contentPoint: CGPoint)? {
        guard !chapterMessageVisible, scrollView.frame.contains(point) else {
            return nil
        }
        let location = convert(point, to: scrollView)
        guard let view = pageViews.values.first(where: { $0.frame.contains(location) }) else {
            return nil
        }
        let contentPoint = scrollView.convert(location, to: view)
        guard let layoutPoint = view.layoutPoint(at: contentPoint) else { return nil }
        return (view.tag, layoutPoint)
    }

    func imageTarget(at point: CGPoint) -> (pageIndex: Int, url: URL, image: UIImage?, requestRule: String?)? {
        guard !chapterMessageVisible, scrollView.frame.contains(point) else {
            return nil
        }
        let location = convert(point, to: scrollView)
        guard let view = pageViews.values.first(where: { $0.frame.contains(location) }) else {
            return nil
        }
        let contentPoint = scrollView.convert(location, to: view)
        guard let layoutPoint = view.layoutPoint(at: contentPoint),
            let fragment = renderState?.pages[safe: view.tag]?.imageFragment(at: layoutPoint),
            case .remoteImage(let url, _) = fragment.source
        else {
            return nil
        }
        return (view.tag, url, view.loadedImages[url], fragment.requestRule)
    }

    func refreshImage(url: URL) {
        for pageView in pageViews.values {
            pageView.removeCachedImage(for: url)
        }
    }

    func cacheLoadedImage(_ image: UIImage, for url: URL) {
        for pageView in pageViews.values { pageView.cacheLoadedImage(image, for: url) }
    }

    func clearTextSelection() {
        updateSelectionRange(nil)
    }

    func setSelectionRange(_ range: NSRange?) {
        updateSelectionRange(range)
    }

    func setSearchResultRange(_ range: NSRange?) {
        if let state = renderState {
            renderState = RenderState(
                pages: state.pages,
                chromes: state.chromes,
                theme: state.theme,
                bookURL: state.bookURL,
                highlightedBlockIndex: state.highlightedBlockIndex,
                selectionRange: state.selectionRange,
                searchResultRange: range,
                doubleHorizontalPageMode: state.doubleHorizontalPageMode,
                retainsImageLine: state.retainsImageLine
            )
        }
        for pageView in pageViews.values {
            pageView.searchResultRange = range
        }
    }

    var selectionVisiblePageIndices: [Int] {
        guard !chapterMessageVisible else { return [] }
        return pageViews.filter { !$0.value.isHidden && $0.value.frame.intersects(scrollView.bounds) }.map(\.key)
            .sorted()
    }

    func selectionViewRect(_ rect: CGRect, pageIndex: Int, in target: UIView) -> CGRect? {
        guard !chapterMessageVisible, let pageView = pageViews[pageIndex] else { return nil }
        return pageView.convert(pageView.viewRect(for: rect), to: target)
    }

    func updateChrome(theme: ReaderThemeController? = nil, chromeProvider: (Int) -> ReaderChromeSnapshot) {
        guard var renderState else { return }
        let chromes = renderState.pages.indices.map { chromeProvider($0) }
        renderState = RenderState(
            pages: renderState.pages,
            chromes: chromes,
            theme: theme ?? renderState.theme,
            bookURL: renderState.bookURL,
            highlightedBlockIndex: renderState.highlightedBlockIndex,
            selectionRange: renderState.selectionRange,
            searchResultRange: renderState.searchResultRange,
            doubleHorizontalPageMode: renderState.doubleHorizontalPageMode,
            retainsImageLine: renderState.retainsImageLine
        )
        self.renderState = renderState
        if let theme { chromeView.theme = theme }
        chromeView.chrome = chromes[safe: lastReportedPageIndex]
        for (_, pageView) in pageViews {
            pageView.setNeedsDisplay()
        }
        rebuildAccessibilityElements()
    }

    func selectionAnchorRect(for range: NSRange, pageIndex: Int, in coordinateSpace: UIView) -> CGRect? {
        guard let pageView = pageViews[pageIndex],
            let page = renderState?.pages[safe: pageIndex]
        else {
            return nil
        }
        let rects = page.selectionRects(for: range)
        let union = rects.reduce(CGRect.null) { $0.union($1) }
        guard union.isNull == false else { return nil }
        return pageView.convert(pageView.viewRect(for: union), to: coordinateSpace)
    }

    func resetBoundaryRequest() {
        isBoundaryRequestInFlight = false
    }

    func scrollViewDidScroll(_: UIScrollView) {
        guard isProgrammaticScroll == false else { return }
        reportVisiblePage()
    }

    func scrollViewWillBeginDragging(_: UIScrollView) {
        // An interrupted animation may not deliver didEndScrollingAnimation.
        isProgrammaticScroll = false
        reportVisiblePage()
    }

    func scrollViewDidEndScrollingAnimation(_: UIScrollView) {
        isProgrammaticScroll = false
        reportVisiblePage()
    }

    func scrollViewDidEndDecelerating(_: UIScrollView) {
        reportVisiblePage()
        requestBoundaryIfNeeded()
    }

    func scrollViewDidEndDragging(_: UIScrollView, willDecelerate decelerate: Bool) {
        if decelerate == false {
            reportVisiblePage()
        }
        requestBoundaryIfNeeded()
    }

    private func rebuildPageViews() {
        scrollView.accessibilityElements = []
        for pageView in pageViews.values {
            pageView.removeFromSuperview()
        }
        pageViews.removeAll()
        scrollView.contentSize = contentSize(for: scrollView.bounds.size)
        ensureRenderedWindow(centeredAt: lastReportedPageIndex)
    }

    private func layoutPageViews() {
        let pageSize = scrollView.bounds.size
        guard pageSize.width > 0, pageSize.height > 0 else { return }
        defer { scrollView.contentSize = contentSize(for: pageSize) }
        if isDualPageMode {
            layoutDualPageViews(pageSize: pageSize)
            return
        }
        let visibleRect = currentVisibleRect()
        for (index, pageView) in pageViews {
            pageView.frame = CGRect(
                x: 0,
                y: CGFloat(index) * pageSize.height,
                width: pageSize.width,
                height: pageSize.height
            )
            pageView.visibleRect = visibleRect
        }
        for pageView in autoReadContinuationViews {
            pageView.frame = CGRect(
                x: 0,
                y: CGFloat(spreadCount) * pageSize.height,
                width: pageSize.width,
                height: pageSize.height
            )
            pageView.visibleRect = visibleRect
        }
    }

    private func layoutDualPageViews(pageSize: CGSize) {
        guard let renderState else { return }
        let spreadGeometry = ReaderSpreadGeometry(
            bounds: CGRect(origin: .zero, size: pageSize),
            theme: renderState.theme,
            displayScale: chromeDisplayScale
        )
        for (index, pageView) in pageViews {
            let slot = slotIndex(forPageIndex: index)
            let columnFrame =
                index % 2 == 0
                ? spreadGeometry.leadingContentHostFrame
                : spreadGeometry.trailingContentHostFrame
            pageView.frame = columnFrame.offsetBy(dx: 0, dy: CGFloat(slot) * pageSize.height)
            pageView.visibleRect = spreadGeometry.visibleRect
        }
        for (index, pageView) in autoReadContinuationViews.enumerated() {
            let columnFrame = index == 0
                ? spreadGeometry.leadingContentHostFrame
                : spreadGeometry.trailingContentHostFrame
            pageView.frame = columnFrame.offsetBy(dx: 0, dy: CGFloat(spreadCount) * pageSize.height)
            pageView.visibleRect = spreadGeometry.visibleRect
        }
    }

    private func clearAutoReadContinuation() {
        for pageView in autoReadContinuationViews {
            pageView.removeFromSuperview()
        }
        autoReadContinuationViews.removeAll()
    }

    private func reconcileContentOffsetAfterLayout(previousPageSlotHeight: CGFloat, previousContentOffset: CGPoint) {
        guard pageCount > 0, pageSlotHeight > 0 else { return }
        let maxOffset = max(scrollView.contentSize.height - pageSlotHeight, 0)
        let proposedOffset: CGFloat
        if previousPageSlotHeight > 0, abs(previousPageSlotHeight - pageSlotHeight) > 0.5 {
            // Changing contentSize can clamp the old offset before it is converted.
            let pageProgress = previousContentOffset.y / previousPageSlotHeight
            proposedOffset = pageProgress * pageSlotHeight
        } else {
            proposedOffset = previousContentOffset.y
        }
        let clampedOffset = min(max(proposedOffset, 0), maxOffset)
        guard abs(scrollView.contentOffset.y - clampedOffset) > 0.5 || scrollView.contentOffset.x != 0 else { return }
        isProgrammaticScroll = true
        scrollView.setContentOffset(CGPoint(x: 0, y: clampedOffset), animated: false)
        isProgrammaticScroll = false
    }

    private func reportVisiblePage() {
        guard !chapterMessageVisible, !isUpdatingContent, pageCount > 0, pageSlotHeight > 0 else { return }
        let pageHeight = pageSlotHeight
        let visibleMidY = scrollView.contentOffset.y + currentVisibleRect().midY
        let slot = Int((visibleMidY / pageHeight).rounded(.down))
        let clampedSlot = min(max(slot, 0), max(spreadCount - 1, 0))
        reportPageIndexIfNeeded(leadingPageIndex(forSlotIndex: clampedSlot))
    }

    private func reportPageIndexIfNeeded(_ index: Int) {
        ensureRenderedWindow(centeredAt: index)
        layoutPageViews()
        chromeView.chrome = renderState?.chromes[safe: index]
        rebuildAccessibilityElements()
        guard index != lastReportedPageIndex else { return }
        lastReportedPageIndex = index
        onPageIndexChange?(index)
    }

    private var pageCount: Int {
        renderState?.pages.count ?? 0
    }

    private func ensureRenderedWindow(centeredAt pageIndex: Int) {
        defer { rebuildAccessibilityElements() }
        guard let renderState, renderState.pages.isEmpty == false else { return }
        let clampedIndex = min(max(pageIndex, 0), renderState.pages.count - 1)
        let lower = max(clampedIndex - renderedPageRadius, 0)
        let upper = min(clampedIndex + renderedPageRadius, renderState.pages.count - 1)
        let needed = Set(lower...upper)
        let obsoleteIndices = pageViews.keys.filter { needed.contains($0) == false }
        for index in obsoleteIndices {
            pageViews[index]?.removeFromSuperview()
            pageViews.removeValue(forKey: index)
        }
        for index in needed where pageViews[index] == nil {
            pageViews[index] = makePageView(index: index, renderState: renderState)
        }
    }

    private func rebuildAccessibilityElements() {
        let orderedPageViews = pageViews.keys.sorted().compactMap { pageViews[$0] }
        scrollView.accessibilityElements = orderedPageViews.filter { $0.isAccessibilityElement }
        accessibilityElements =
            chromeView.headerAccessibilityElements
            + (chapterMessageVisible ? [] : [scrollView]) + chromeView.footerAccessibilityElements
    }

    private func makePageView(index: Int, renderState: RenderState) -> ReaderPageContentView {
        let page = renderState.pages[index]
        let contentView = ReaderPageContentView()
        contentView.tag = index
        contentView.bookURL = renderState.bookURL
        contentView.theme = renderState.theme
        contentView.highlightedBlockIndex = renderState.highlightedBlockIndex
        contentView.selectionRange = renderState.selectionRange
        contentView.searchResultRange = renderState.searchResultRange
        contentView.pageLayout = page
        contentView.backgroundColor = .clear
        contentView.isOpaque = false
        scrollView.addSubview(contentView)
        return contentView
    }

    private func updateSelectionRange(_ range: NSRange?) {
        guard let state = renderState else {
            for pageView in pageViews.values {
                pageView.selectionRange = range
            }
            return
        }
        renderState = RenderState(
            pages: state.pages,
            chromes: state.chromes,
            theme: state.theme,
            bookURL: state.bookURL,
            highlightedBlockIndex: state.highlightedBlockIndex,
            selectionRange: range,
            searchResultRange: state.searchResultRange,
            doubleHorizontalPageMode: state.doubleHorizontalPageMode,
            retainsImageLine: state.retainsImageLine
        )
        for pageView in pageViews.values {
            pageView.selectionRange = range
        }
    }

    private func contentSize(for pageSize: CGSize) -> CGSize {
        guard pageSize.width > 0, pageSize.height > 0, pageCount > 0 else { return .zero }
        let slotCount = spreadCount + (hasAutoReadContinuation ? 1 : 0)
        return CGSize(width: pageSize.width, height: CGFloat(slotCount) * pageSize.height)
    }

    private func requestBoundaryIfNeeded() {
        guard isProgrammaticScroll == false,
            !isUpdatingContent,
            isBoundaryRequestInFlight == false,
            pageSlotHeight > 0
        else {
            return
        }
        let maxOffset = max(scrollView.contentSize.height - pageSlotHeight, 0)
        let threshold = max(28, min(84, currentVisibleRect().height * 0.16))
        let boundary: Boundary?
        if scrollView.contentOffset.y <= -threshold {
            boundary = .previous
        } else if scrollView.contentOffset.y >= maxOffset + threshold {
            boundary = .next
        } else {
            boundary = nil
        }
        guard let boundary else { return }
        isBoundaryRequestInFlight = true
        let accepted = onBoundaryRequest?(boundary) ?? false
        if accepted == false {
            isBoundaryRequestInFlight = false
        }
    }

    private var pageSlotHeight: CGFloat {
        max(scrollView.bounds.height, 1)
    }

    private var chromeDisplayScale: CGFloat {
        let scale = window?.screen.scale ?? traitCollection.displayScale
        return scale.isFinite ? max(scale, 1) : 1
    }

    private func updateScrollFrame() {
        guard isDualPageMode == false else {
            scrollView.frame = bounds
            return
        }
        let geometry = renderState.map {
            ReaderPageGeometry.estimated(bounds: bounds, theme: $0.theme, displayScale: chromeDisplayScale)
        }
        scrollView.frame = geometry?.contentHostFrame ?? bounds
    }

    private func currentVisibleRect() -> CGRect {
        guard let renderState else { return scrollView.bounds }
        if renderState.doubleHorizontalPageMode.isEnabledForLegacyDualPageMode {
            return ReaderSpreadGeometry(
                bounds: CGRect(origin: .zero, size: scrollView.bounds.size),
                theme: renderState.theme,
                displayScale: chromeDisplayScale
            ).visibleRect
        }
        let geometry = ReaderPageGeometry.estimated(bounds: bounds, theme: renderState.theme, displayScale: chromeDisplayScale)
        return geometry.contentFrame.offsetBy(dx: -geometry.contentHostFrame.minX, dy: -geometry.contentHostFrame.minY)
    }

    private var isDualPageMode: Bool {
        renderState?.doubleHorizontalPageMode.isEnabledForLegacyDualPageMode == true
    }

    private var spreadCount: Int {
        guard pageCount > 0 else { return 0 }
        return isDualPageMode ? Int(ceil(Double(pageCount) / 2.0)) : pageCount
    }

    private func slotIndex(forPageIndex pageIndex: Int) -> Int {
        isDualPageMode ? pageIndex / 2 : pageIndex
    }

    private func leadingPageIndex(forPageIndex pageIndex: Int) -> Int {
        guard isDualPageMode else { return pageIndex }
        return min(max((pageIndex / 2) * 2, 0), max(pageCount - 1, 0))
    }

    private func leadingPageIndex(forSlotIndex slotIndex: Int) -> Int {
        guard isDualPageMode else { return slotIndex }
        return min(max(slotIndex * 2, 0), max(pageCount - 1, 0))
    }
}
