import CoreGraphics

struct ReaderScrollPageMetrics {
    struct Viewport: Equatable {
        let size: CGSize
        let visibleRect: CGRect
        let leadingHostFrame: CGRect
        let trailingHostFrame: CGRect?

        var pagesPerSlot: Int { trailingHostFrame == nil ? 1 : 2 }
        var slotHeight: CGFloat { size.height.isFinite ? max(size.height, 1) : 1 }
    }

    let viewport: Viewport
    let pageCount: Int
    let slotStarts: [CGFloat]
    let slotHeights: [CGFloat]
    let chapterHeight: CGFloat
    let continuationHeight: CGFloat
    let hasExtendedSlots: Bool
    private let pageExtraHeights: [CGFloat]
    private let continuationExtraHeights: [CGFloat]

    init(
        viewport: Viewport,
        pageContentHeights: [CGFloat],
        continuationContentHeights: [CGFloat],
        measuredVisibleHeight: CGFloat? = nil,
        continuationMeasuredVisibleHeight: CGFloat? = nil
    ) {
        self.viewport = viewport
        pageCount = pageContentHeights.count
        let extras = pageContentHeights.map {
            Self.extraHeight($0, visibleHeight: viewport.visibleRect.height, measuredVisibleHeight: measuredVisibleHeight)
        }
        pageExtraHeights = extras
        let continuationExtras =
            pageContentHeights.isEmpty
            ? []
            : continuationContentHeights.prefix(viewport.pagesPerSlot).map {
                Self.extraHeight($0, visibleHeight: viewport.visibleRect.height, measuredVisibleHeight: continuationMeasuredVisibleHeight)
            }
        continuationExtraHeights = continuationExtras
        var starts: [CGFloat] = []
        var heights: [CGFloat] = []
        var accumulatedExtra: CGFloat = 0
        for firstPage in stride(from: 0, to: extras.count, by: viewport.pagesPerSlot) {
            let end = min(firstPage + viewport.pagesPerSlot, extras.count)
            let extra = extras[firstPage..<end].max() ?? 0
            // Multiplication retains the old fixed-slot positions when every extra is zero.
            starts.append(CGFloat(starts.count) * viewport.slotHeight + accumulatedExtra)
            heights.append(viewport.slotHeight + extra)
            accumulatedExtra += extra
        }
        slotStarts = starts
        slotHeights = heights
        hasExtendedSlots = extras.contains { $0 > 0 }
        chapterHeight = CGFloat(starts.count) * viewport.slotHeight + accumulatedExtra
        continuationHeight = continuationExtras.isEmpty ? 0 : viewport.slotHeight + (continuationExtras.max() ?? 0)
    }

    var slotCount: Int { slotStarts.count }
    var contentHeight: CGFloat { chapterHeight + continuationHeight }
    var maximumChapterOffset: CGFloat { max(chapterHeight - viewport.slotHeight, 0) }
    var maximumContentOffset: CGFloat { max(contentHeight - viewport.slotHeight, 0) }
    // A long next-chapter preview must hand off at its origin, not replay its tail on chapter load.
    var autoReadEndOffset: CGFloat { continuationHeight > 0 ? chapterHeight : maximumChapterOffset }

    var visibleViewport: CGRect {
        let leading = viewport.visibleRect.offsetBy(dx: viewport.leadingHostFrame.minX, dy: viewport.leadingHostFrame.minY)
        guard let trailing = viewport.trailingHostFrame else { return leading }
        return leading.union(viewport.visibleRect.offsetBy(dx: trailing.minX, dy: trailing.minY))
    }

    func slotIndex(forPageIndex index: Int) -> Int {
        min(max(index, 0), max(pageCount - 1, 0)) / viewport.pagesPerSlot
    }

    func leadingPageIndex(forSlotIndex index: Int) -> Int {
        min(max(index, 0), max(slotCount - 1, 0)) * viewport.pagesPerSlot
    }

    func leadingPageIndex(forPageIndex index: Int) -> Int {
        leadingPageIndex(forSlotIndex: slotIndex(forPageIndex: index))
    }

    /// The leading page changes only after the entire slot passes, including half-pixel ties.
    func slotIndex(atY offset: CGFloat, displayScale: CGFloat? = nil) -> Int? {
        guard slotCount > 0, offset.isFinite else { return nil }
        var query = offset
        if let displayScale {
            let scale = displayScale.isFinite ? max(displayScale, 1) : 1
            query += 0.5 / scale
            query += max(abs(query), viewport.slotHeight) * CGFloat.ulpOfOne * 4
        }
        var lower = 0
        var upper = slotCount
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if slotStarts[middle] <= query {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        // Overscroll and the visual-only continuation never become current-chapter pages.
        return min(max(lower - 1, 0), slotCount - 1)
    }

    func roundedFixedSlotIndex(atY offset: CGFloat) -> Int? {
        guard offset.isFinite, !hasExtendedSlots, slotCount > 0 else { return nil }
        let rounded = (offset / viewport.slotHeight).rounded()
        return Int(min(max(rounded, -1), CGFloat(slotCount)))
    }

    func pageIndices(atY offset: CGFloat) -> ClosedRange<Int>? {
        guard offset >= 0, offset < chapterHeight, let slot = slotIndex(atY: offset) else { return nil }
        return pages(inSlots: slot...slot)
    }

    func renderedPageIndices(centeredAt pageIndex: Int, visibleBounds: CGRect, radius: Int) -> Set<Int> {
        guard pageCount > 0 else { return [] }
        let center = min(max(pageIndex, 0), pageCount - 1)
        let radius = max(radius, 0)
        let lower = slotIndex(forPageIndex: max(center - radius, 0))
        let upper = slotIndex(forPageIndex: min(center + radius, pageCount - 1))
        var needed = Set(pages(inSlots: lower...upper))
        if let first = slotIndex(atY: visibleBounds.minY), let last = slotIndex(atY: visibleBounds.maxY) {
            needed.formUnion(pages(inSlots: first...last))
        }
        return needed
    }

    func pageGeometry(at index: Int) -> (frame: CGRect, visibleRect: CGRect)? {
        guard pageExtraHeights.indices.contains(index) else { return nil }
        return geometry(
            column: index % viewport.pagesPerSlot, origin: slotStarts[slotIndex(forPageIndex: index)], extra: pageExtraHeights[index])
    }

    func continuationGeometry(at index: Int) -> (frame: CGRect, visibleRect: CGRect)? {
        guard continuationExtraHeights.indices.contains(index) else { return nil }
        return geometry(column: index, origin: chapterHeight, extra: continuationExtraHeights[index])
    }

    func reconciledOffset(from previous: ReaderScrollPageMetrics?, offset: CGFloat) -> CGFloat {
        guard offset.isFinite else { return 0 }
        var proposed = offset
        if let previous, previous.viewport != viewport {
            if !previous.hasExtendedSlots, !hasExtendedSlots,
                previous.viewport.pagesPerSlot == viewport.pagesPerSlot
            {
                if abs(previous.viewport.slotHeight - viewport.slotHeight) > 0.5 {
                    proposed = offset / previous.viewport.slotHeight * viewport.slotHeight
                }
            } else if offset >= previous.chapterHeight, previous.continuationHeight > 0, continuationHeight > 0 {
                let fraction = (offset - previous.chapterHeight) / previous.continuationHeight
                proposed = chapterHeight + fraction * continuationHeight
            } else if let oldSlot = previous.slotIndex(atY: offset), slotCount > 0 {
                let page = previous.leadingPageIndex(forSlotIndex: oldSlot)
                let slot = slotIndex(forPageIndex: page)
                let fraction = (offset - previous.slotStarts[oldSlot]) / previous.slotHeights[oldSlot]
                proposed = slotStarts[slot] + fraction * slotHeights[slot]
            }
        }
        return min(max(proposed, 0), maximumContentOffset)
    }

    private func pages(inSlots slots: ClosedRange<Int>) -> ClosedRange<Int> {
        let lower = leadingPageIndex(forSlotIndex: slots.lowerBound)
        let upper = min(leadingPageIndex(forSlotIndex: slots.upperBound) + viewport.pagesPerSlot - 1, pageCount - 1)
        return lower...upper
    }

    private func geometry(column: Int, origin: CGFloat, extra: CGFloat) -> (frame: CGRect, visibleRect: CGRect) {
        var frame = column == 1 ? viewport.trailingHostFrame ?? viewport.leadingHostFrame : viewport.leadingHostFrame
        frame.origin.y += origin
        frame.size.height += extra
        var visibleRect = viewport.visibleRect
        visibleRect.size.height += extra
        return (frame, visibleRect)
    }

    private static func extraHeight(_ height: CGFloat, visibleHeight: CGFloat, measuredVisibleHeight: CGFloat?) -> CGFloat {
        guard height.isFinite, visibleHeight.isFinite, visibleHeight > 0 else { return 0 }
        // A viewport resize alone cannot turn an ordinary measured page into an overflow page.
        if let measuredVisibleHeight, height <= measuredVisibleHeight { return 0 }
        return max(height - visibleHeight, 0)
    }
}
