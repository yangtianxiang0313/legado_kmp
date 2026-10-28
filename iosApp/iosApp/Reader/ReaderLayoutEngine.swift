import CoreText
import UIKit
import shared

struct ReaderPageLayout {
    let textFragments: [ReaderTextLayoutFragment]
    let attachmentFragments: [ReaderAttachmentLayoutFragment]
    let chapterTitle: String
    let characterOffset: Int
    let previewText: String
    let contentSize: CGSize

    var isEmpty: Bool {
        textFragments.isEmpty && attachmentFragments.isEmpty
    }

    var pageText: String {
        textFragments
            .map { $0.attributedText.string.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
            .joined(separator: "\n")
    }

    var accessibilityText: String {
        var fragments: [(text: String, frame: CGRect, index: Int, fragment: ReaderTextLayoutFragment?)] =
            textFragments.enumerated().map { index, fragment in
                (fragment.attributedText.string, fragment.frame, index, fragment)
            }
        for (index, attachment) in attachmentFragments.enumerated() {
            guard case .remoteImage(_, let altText) = attachment.source else {
                continue
            }
            fragments.append((altText ?? "", attachment.frame, textFragments.count + index, nil))
        }
        fragments.sort { lhs, rhs in
            if lhs.frame.minY != rhs.frame.minY {
                return lhs.frame.minY < rhs.frame.minY
            }
            if lhs.frame.minX != rhs.frame.minX {
                return lhs.frame.minX < rhs.frame.minX
            }
            return lhs.index < rhs.index
        }

        var text = ""
        var previousTextFragment: ReaderTextLayoutFragment?
        for item in fragments {
            if item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, item.fragment == nil {
                previousTextFragment = nil
                continue
            }
            if item.text.isEmpty { continue }
            let continuesText: Bool
            if let previous = previousTextFragment, let current = item.fragment {
                continuesText = current.isContinuation && current.blockIndex == previous.blockIndex && current.kind == previous.kind
            } else {
                continuesText = false
            }
            // Soft wraps retain their original characters; only semantic boundaries need a break.
            if text.isEmpty == false, continuesText == false,
                text.last?.isNewline != true, item.text.first?.isNewline != true
            {
                text.append("\n")
            }
            text.append(item.text)
            previousTextFragment = item.fragment
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func rects(for range: NSRange) -> [CGRect] {
        guard range.length > 0 else { return [] }
        return textFragments.compactMap { fragment in
            NSIntersectionRange(fragment.sourceRange, range).length > 0 ? fragment.frame : nil
        }
    }

    func characterRange(at point: CGPoint) -> NSRange? {
        if let fragment = textFragments.first(where: { $0.frame.contains(point) }) {
            return fragment.sourceRange
        }
        if let attachment = attachmentFragments.first(where: { $0.frame.contains(point) }) {
            return attachment.sourceRange
        }
        return nil
    }

    func characterRangeForSelection(at point: CGPoint) -> NSRange? {
        guard attachmentFragments.contains(where: { $0.frame.contains(point) }) == false else { return nil }
        for fragment in textFragments {
            if let range = ReaderTextSelectionGeometry(fragment: fragment).characterRange(at: point) {
                return range
            }
        }
        return nil
    }

    /// Operable composed characters in chapter UTF-16 order, independent of visual bidi order.
    var selectionCharacterRanges: [NSRange] {
        let ranges = textFragments.flatMap {
            ReaderTextSelectionGeometry(fragment: $0).selectionCharacterRanges
        }
        return Array(Set(ranges)).sorted {
            $0.location == $1.location ? $0.length < $1.length : $0.location < $1.location
        }
    }

    /// Returns a word in chapter UTF-16 coordinates only when a text character is hit.
    func wordRange(at point: CGPoint) -> (range: NSRange, word: String)? {
        guard attachmentFragments.contains(where: { $0.frame.contains(point) }) == false else { return nil }
        let visibleBounds = CGRect(origin: .zero, size: contentSize)
        for (index, fragment) in textFragments.enumerated() where fragment.frame.contains(point) {
            // ReadView.onLongPress collects the touched paragraph's rows from its
            // relative page only; never borrow context from other chapter pages.
            let context = ReaderTextSelectionGeometry.WordContext(
                fragments: textFragments, attachments: attachmentFragments, containing: index, visibleBounds: visibleBounds)
            if let word = ReaderTextSelectionGeometry(fragment: fragment).wordRange(at: point, context: context) {
                return word
            }
        }
        return nil
    }

    /// Returns the attachment fragment (image) at the given point, if any.
    func imageFragment(at point: CGPoint) -> ReaderAttachmentLayoutFragment? {
        attachmentFragments.first { fragment in
            if case .remoteImage = fragment.source, fragment.frame.contains(point) { return true }
            return false
        }
    }

    /// Returns per-line typographic rectangles, including for whole-fragment selections.
    func selectionRects(for range: NSRange) -> [CGRect] {
        guard range.length > 0 else { return [] }
        return textFragments.flatMap { fragment -> [CGRect] in
            guard ReaderTextSelectionGeometry.localSelectionRange(for: range, in: fragment) != nil else { return [] }
            return ReaderTextSelectionGeometry(fragment: fragment).selectionRects(for: range)
        }
    }

    func selectionEndpoints(for range: NSRange) -> (start: CGRect, end: CGRect)? {
        guard ReaderTextSelectionGeometry.isValidSelectionRange(range) else { return nil }
        let endpoints = textFragments.compactMap { fragment -> (range: NSRange, start: CGRect, end: CGRect)? in
            let geometry = ReaderTextSelectionGeometry(fragment: fragment)
            let characters = geometry.selectionCharacterRanges.filter { NSIntersectionRange($0, range).length > 0 }
            guard let first = characters.first, let last = characters.last,
                let carets = geometry.selectionEndpoints(for: range)
            else { return nil }
            let sourceRange = NSRange(location: first.location, length: last.upperBound - first.location)
            return (sourceRange, carets.start, carets.end)
        }
        guard let first = endpoints.min(by: { $0.range.location < $1.range.location }),
            let last = endpoints.max(by: { $0.range.upperBound < $1.range.upperBound })
        else { return nil }
        return (first.start, last.end)
    }

    /// Returns the text content within the given source range.
    func selectedText(for range: NSRange) -> String {
        guard range.length > 0 else { return "" }
        var parts: [String] = []
        for fragment in textFragments {
            guard let localRange = ReaderTextSelectionGeometry.localSelectionRange(for: range, in: fragment) else {
                continue
            }
            let nsString = fragment.attributedText.string as NSString
            parts.append(nsString.substring(with: localRange))
        }
        return parts.joined()
    }

    /// Collects only the supplied visible pages; callers keep them within one chapter.
    static func selectedText(for range: NSRange, in pages: [ReaderPageLayout]) -> String {
        guard ReaderTextSelectionGeometry.isValidSelectionRange(range) else { return "" }
        let fragments = pages.flatMap(\.textFragments).enumerated().sorted {
            let lhs = $0.element.sourceRange
            let rhs = $1.element.sourceRange
            if lhs.location != rhs.location { return lhs.location < rhs.location }
            if lhs.length != rhs.length { return lhs.length > rhs.length }
            return $0.offset < $1.offset
        }
        let attachments = pages.flatMap(\.attachmentFragments).map(\.sourceRange).filter {
            ReaderTextSelectionGeometry.isValidSelectionRange($0)
        }
        var result = ""
        var previousEnd: Int?
        var previousFragment: ReaderTextLayoutFragment?
        for item in fragments {
            let fragment = item.element
            guard ReaderTextSelectionGeometry.isValidSelectionRange(fragment.sourceRange),
                var localRange = ReaderTextSelectionGeometry.localSelectionRange(for: range, in: fragment)
            else { continue }
            let text = fragment.attributedText.string as NSString
            if let previousEnd {
                let consumedLength = max(previousEnd - fragment.sourceRange.location, 0)
                guard consumedLength < localRange.upperBound else { continue }
                if consumedLength > localRange.location {
                    let character = text.rangeOfComposedCharacterSequence(at: consumedLength)
                    let start = character.location < consumedLength ? character.upperBound : consumedLength
                    guard start < localRange.upperBound else { continue }
                    localRange = NSRange(location: start, length: localRange.upperBound - start)
                }
            }
            let sourceStart = fragment.sourceRange.location + localRange.location
            if let previousEnd, let previous = previousFragment, sourceStart > previousEnd,
                fragment.blockIndex != previous.blockIndex || fragment.kind != previous.kind || !fragment.isContinuation
            {
                let gapStart = max(previousEnd, range.location)
                let gapEnd = min(sourceStart, range.upperBound)
                if gapEnd > gapStart {
                    let gap = NSRange(location: gapStart, length: gapEnd - gapStart)
                    // Only a source gap at a paragraph boundary implies a break.
                    // Image placeholders and visual spacing are not text.
                    if attachments.contains(where: { NSIntersectionRange($0, gap).length > 0 }) == false {
                        result.append("\n")
                    }
                }
            }
            result.append(text.substring(with: localRange))
            previousEnd = fragment.sourceRange.location + localRange.upperBound
            previousFragment = fragment
        }
        return result
    }

    func contains(blockIndex: Int) -> Bool {
        textFragments.contains { $0.blockIndex == blockIndex }
    }

    var leadingBlockIndex: Int? {
        textFragments.first?.blockIndex
    }
}

struct ReaderTextLayoutFragment {
    let attributedText: NSAttributedString
    let sourceRange: NSRange
    let frame: CGRect
    let kind: ReaderTextBlockKind
    let blockIndex: Int
    let isContinuation: Bool

    func offsetBy(dx: CGFloat, dy: CGFloat) -> ReaderTextLayoutFragment {
        ReaderTextLayoutFragment(
            attributedText: attributedText,
            sourceRange: sourceRange,
            frame: frame.offsetBy(dx: dx, dy: dy),
            kind: kind,
            blockIndex: blockIndex,
            isContinuation: isContinuation
        )
    }
}

struct ReaderAttachmentLayoutFragment {
    let sourceRange: NSRange
    let frame: CGRect
    let contentMode: UIView.ContentMode
    let source: ReaderAttachmentSource
}

enum ReaderAttachmentSource {
    case remoteImage(url: URL, altText: String?)
    case spacer(height: CGFloat)
}

enum ReaderTextBlockKind {
    case heading
    case paragraph
}

final class ReaderLayoutEngine {
    struct PaginationResult {
        let pages: [ReaderPageLayout]
    }

    private let coreTextMeasurementBackend = CoreTextMeasurementBackend()
    private let cache = ReaderPaginationCache<ReaderPaginationCacheKey>()

    var cacheStatistics: ReaderPaginationCacheStatistics {
        cache.statistics
    }

    func paginate(
        layout: ReaderChapterLayout,
        in bounds: CGRect,
        theme: ReaderThemeController
    ) -> PaginationResult {
        let pageGeometry = ReaderPageGeometry.estimated(bounds: bounds, theme: theme)
        let key = ReaderPaginationCacheKey(
            layout: layout,
            bounds: bounds,
            pageGeometry: pageGeometry,
            theme: theme,
            imageStyle: layout.normalizedImageStyle
        )
        if let cached = cache.value(for: key) {
            return cached
        }

        let contentSize = CGSize(
            width: max(pageGeometry.contentFrame.width, 1),
            height: max(pageGeometry.contentFrame.height, 1)
        )

        let pages = renderMeasuredPages(
            layout: layout,
            contentSize: contentSize,
            theme: theme,
            imageStyle: layout.normalizedImageStyle
        )
        let result = PaginationResult(pages: pages.isEmpty ? [emptyPage(chapterTitle: layout.chapterTitle, contentSize: contentSize)] : pages)
        cache.insert(result, for: key)
        return result
    }

    private func renderMeasuredPages(
        layout: ReaderChapterLayout,
        contentSize: CGSize,
        theme: ReaderThemeController,
        imageStyle: String
    ) -> [ReaderPageLayout] {
        var pages: [ReaderPageLayout] = []
        var page = ReaderPageBuildState(contentSize: contentSize, bodyLineAdvance: theme.bodyLineHeight)
        var pendingTextFragments: [ReaderPageFragment] = []
        let searchableText = layout.searchableText as NSString
        var searchableLocation = 0

        func flushTextFragments() {
            guard let first = pendingTextFragments.first, let last = pendingTextFragments.last else { return }
            let sourceLength = max(Int(last.chapterEndPosition - first.chapterStartPosition), 0)
            let searchRange = NSRange(location: searchableLocation, length: sourceLength)
            let logicalText: String
            if searchRange.location <= searchableText.length, searchRange.length <= searchableText.length - searchRange.location {
                logicalText = searchableText.substring(with: searchRange)
            } else {
                // Without canonical source text, retain ambiguous newlines rather than erase hard breaks.
                logicalText = pendingTextFragments.map(\.text).joined()
            }
            // Search text LF-joins text blocks; image placeholders advance only chapter coordinates.
            searchableLocation = searchRange.upperBound + 1
            appendTextFragments(
                pendingTextFragments,
                logicalText: logicalText,
                to: &page,
                pages: &pages,
                chapterTitle: layout.chapterTitle,
                contentSize: contentSize,
                theme: theme
            )
            pendingTextFragments.removeAll(keepingCapacity: true)
        }

        func flushPage() {
            guard !page.isEmpty else { return }
            pages.append(page.build(chapterTitle: layout.chapterTitle, bottomJustify: theme.prefersBottomAlignedContent))
            page = ReaderPageBuildState(contentSize: contentSize, bodyLineAdvance: theme.bodyLineHeight)
        }

        for sourcePage in layout.pages {
            for fragment in sourcePage.fragments {
                switch fragment.kind {
                case .heading, .paragraph:
                    if let previous = pendingTextFragments.last,
                        canJoinTextFragments(previous, fragment) == false
                    {
                        flushTextFragments()
                    }
                    pendingTextFragments.append(fragment)

                case .image:
                    flushTextFragments()
                    appendImageFragment(
                        fragment,
                        to: &page,
                        pages: &pages,
                        chapterTitle: layout.chapterTitle,
                        contentSize: contentSize,
                        theme: theme,
                        imageStyle: imageStyle
                    )

                case .spacer:
                    flushTextFragments()
                    appendSpacerFragment(
                        fragment,
                        to: &page,
                        pages: &pages,
                        chapterTitle: layout.chapterTitle,
                        contentSize: contentSize,
                        theme: theme
                    )

                default:
                    flushTextFragments()
                    continue
                }
            }
        }

        flushTextFragments()
        flushPage()
        return pages
    }

    private func canJoinTextFragments(_ previous: ReaderPageFragment, _ next: ReaderPageFragment) -> Bool {
        previous.kind == next.kind && previous.blockIndex == next.blockIndex && previous.isParagraphEnd == false && next.isContinuation
            && previous.chapterEndPosition == next.chapterStartPosition
    }

    private func appendTextFragments(
        _ fragments: [ReaderPageFragment],
        logicalText: String,
        to page: inout ReaderPageBuildState,
        pages: inout [ReaderPageLayout],
        chapterTitle: String,
        contentSize: CGSize,
        theme: ReaderThemeController
    ) {
        guard let fragment = fragments.first, let lastFragment = fragments.last else { return }
        let kind: ReaderTextBlockKind = fragment.kind == .heading ? .heading : .paragraph
        guard logicalText.isEmpty == false else { return }
        let sourceStart = Int(fragment.chapterStartPosition)
        let sourceEnd = max(Int(lastFragment.chapterEndPosition), sourceStart)
        if kind == .heading, fragment.isContinuation == false {
            page.pendingBlockSpacing += max(theme.titleTopSpacing, 0)
        }

        let block = ReaderContentBlock(
            blockIndex: Int32(fragment.blockIndex),
            type: fragment.kind == .heading ? .heading : .paragraph,
            text: logicalText,
            imageUrl: nil,
            imageAlt: nil,
            imageWidth: 0,
            imageHeight: 0
        )
        let attributed = adjustedContinuation(
            makeAttributedText(block: block, theme: theme),
            isContinuation: fragment.isContinuation,
            kind: kind
        )
        appendAttributedText(
            attributed,
            sourceRange: NSRange(location: sourceStart, length: sourceEnd - sourceStart),
            kind: kind,
            blockIndex: Int(fragment.blockIndex),
            isContinuation: fragment.isContinuation,
            isParagraphEnd: lastFragment.isParagraphEnd,
            to: &page,
            pages: &pages,
            chapterTitle: chapterTitle,
            contentSize: contentSize,
            theme: theme
        )
        if lastFragment.isParagraphEnd {
            page.pendingBlockSpacing = paragraphSpacing(for: kind, theme: theme)
            if kind == .heading {
                page.pendingBlockSpacing += max(theme.titleBottomSpacing, 0)
            }
        }
    }

    private func appendAttributedText(
        _ attributed: NSAttributedString,
        sourceRange: NSRange,
        kind: ReaderTextBlockKind,
        blockIndex: Int,
        isContinuation: Bool,
        isParagraphEnd: Bool,
        to page: inout ReaderPageBuildState,
        pages: inout [ReaderPageLayout],
        chapterTitle: String,
        contentSize: CGSize,
        theme: ReaderThemeController
    ) {
        // Wrap the whole paragraph before allocating rows; CoreText's vertical fit includes leading.
        appendVisualTextLines(
            attributed,
            sourceLocation: sourceRange.location,
            sourceEnd: sourceRange.upperBound,
            kind: kind,
            blockIndex: blockIndex,
            isContinuation: isContinuation,
            isParagraphEnd: isParagraphEnd,
            to: &page,
            pages: &pages,
            chapterTitle: chapterTitle,
            contentSize: contentSize,
            theme: theme
        )
    }

    @discardableResult
    private func appendVisualTextLines(
        _ attributed: NSAttributedString,
        sourceLocation: Int,
        sourceEnd: Int,
        kind: ReaderTextBlockKind,
        blockIndex: Int,
        isContinuation: Bool,
        isParagraphEnd: Bool,
        to page: inout ReaderPageBuildState,
        pages: inout [ReaderPageLayout],
        chapterTitle: String,
        contentSize: CGSize,
        theme: ReaderThemeController
    ) -> Int {
        let lineRanges = visualLineRanges(for: attributed, contentSize: contentSize)
        guard lineRanges.isEmpty == false else {
            return appendFallbackText(
                attributed,
                sourceLocation: sourceLocation,
                sourceEnd: sourceEnd,
                kind: kind,
                blockIndex: blockIndex,
                isContinuation: isContinuation,
                to: &page,
                pages: &pages,
                chapterTitle: chapterTitle,
                contentSize: contentSize,
                theme: theme
            )
        }

        var consumedLength = 0
        let text = attributed.string as NSString
        for lineRange in lineRanges {
            guard lineRange.length > 0, lineRange.location + lineRange.length <= attributed.length else { continue }
            let lineContinuation =
                lineRange.location == 0
                ? isContinuation : text.paragraphRange(for: NSRange(location: lineRange.location, length: 0)).location < lineRange.location
            let endsParagraph = text.rangeOfCharacter(from: .newlines, options: [], range: lineRange).location != NSNotFound
            let visualLine = adjustedFragmentText(
                attributed.attributedSubstring(from: lineRange),
                isContinuation: lineContinuation,
                isParagraphEnd: endsParagraph || (isParagraphEnd && lineRange.upperBound == attributed.length),
                kind: kind,
                suppressParagraphSpacing: true,
                contentWidth: contentSize.width,
                theme: theme
            )
            // ChapterProvider fits the glyph box, then advances by textHeight * lineSpacingExtra.
            let lineHeight = minimumLineHeight(for: kind, theme: theme)
            let lineAdvance = kind == .heading ? theme.titleLineHeight : theme.bodyLineHeight
            preparePageForContent(
                height: lineHeight,
                sourceLocation: sourceLocation + lineRange.location,
                to: &page,
                pages: &pages,
                chapterTitle: chapterTitle,
                contentSize: contentSize,
                theme: theme
            )
            page.appendText(
                visualLine,
                sourceRange: NSRange(
                    location: sourceLocation + lineRange.location,
                    length: sourceRangeLength(lineRange.length, from: sourceLocation + lineRange.location, to: sourceEnd)),
                height: lineHeight,
                kind: kind,
                blockIndex: blockIndex,
                isContinuation: lineContinuation,
                advance: lineAdvance
            )
            if endsParagraph {
                page.pendingBlockSpacing = paragraphSpacing(for: kind, theme: theme)
            }
            consumedLength = max(consumedLength, lineRange.location + lineRange.length)
        }
        return max(consumedLength, attributed.length)
    }

    private func appendFallbackText(
        _ attributed: NSAttributedString,
        sourceLocation: Int,
        sourceEnd: Int,
        kind: ReaderTextBlockKind,
        blockIndex: Int,
        isContinuation: Bool,
        to page: inout ReaderPageBuildState,
        pages: inout [ReaderPageLayout],
        chapterTitle: String,
        contentSize: CGSize,
        theme: ReaderThemeController
    ) -> Int {
        let measuredHeight = lineFrameHeight(for: attributed, kind: kind, contentSize: contentSize, theme: theme)
        preparePageForContent(
            height: measuredHeight,
            sourceLocation: sourceLocation,
            to: &page,
            pages: &pages,
            chapterTitle: chapterTitle,
            contentSize: contentSize,
            theme: theme
        )
        page.appendText(
            attributed,
            sourceRange: NSRange(location: sourceLocation, length: sourceRangeLength(attributed.length, from: sourceLocation, to: sourceEnd)),
            height: measuredHeight,
            kind: kind,
            blockIndex: blockIndex,
            isContinuation: isContinuation
        )
        return attributed.length
    }

    private func preparePageForContent(
        height: CGFloat,
        sourceLocation: Int,
        to page: inout ReaderPageBuildState,
        pages: inout [ReaderPageLayout],
        chapterTitle: String,
        contentSize: CGSize,
        theme: ReaderThemeController
    ) {
        let spacing = page.spacingBeforeContent(height: height)
        if !page.isEmpty, page.cursorY + spacing + height > contentSize.height {
            pages.append(page.build(chapterTitle: chapterTitle, bottomJustify: theme.prefersBottomAlignedContent))
            page = ReaderPageBuildState(contentSize: contentSize, bodyLineAdvance: theme.bodyLineHeight)
        }
        page.appendPendingBlockSpacing(before: sourceLocation, contentHeight: height)
    }

    private func sourceRangeLength(_ attributedLength: Int, from sourceLocation: Int, to sourceEnd: Int) -> Int {
        min(attributedLength, max(sourceEnd - sourceLocation, 0))
    }

    private func appendImageFragment(
        _ fragment: ReaderPageFragment,
        to page: inout ReaderPageBuildState,
        pages: inout [ReaderPageLayout],
        chapterTitle: String,
        contentSize: CGSize,
        theme: ReaderThemeController,
        imageStyle: String
    ) {
        guard let urlString = fragment.imageUrl, let url = URL(string: urlString) else { return }
        let imageHeight = imageFrameHeight(style: imageStyle, contentSize: contentSize, theme: theme)
        let imageWidth = imageFrameWidth(style: imageStyle, contentSize: contentSize, height: imageHeight, theme: theme)
        preparePageForContent(
            height: imageHeight,
            sourceLocation: Int(fragment.chapterStartPosition),
            to: &page,
            pages: &pages,
            chapterTitle: chapterTitle,
            contentSize: contentSize,
            theme: theme
        )
        let imageX = max((contentSize.width - imageWidth) / 2, 0)
        page.appendAttachment(
            sourceRange: NSRange(
                location: Int(fragment.chapterStartPosition), length: max(Int(fragment.chapterEndPosition - fragment.chapterStartPosition), 1)),
            frame: CGRect(x: imageX, y: page.cursorY, width: imageWidth, height: imageHeight),
            contentMode: imageStyle == "FULL" ? .scaleAspectFill : .scaleAspectFit,
            source: .remoteImage(url: url, altText: fragment.imageAlt),
            previewText: fragment.imageAlt
        )
        page.pendingBlockSpacing = max(theme.paragraphSpacing, 0)
    }

    private func appendSpacerFragment(
        _ fragment: ReaderPageFragment,
        to page: inout ReaderPageBuildState,
        pages: inout [ReaderPageLayout],
        chapterTitle: String,
        contentSize: CGSize,
        theme: ReaderThemeController
    ) {
        let spacerHeight = min(theme.bodyLineHeight / 2 + theme.paragraphSpacing, max(contentSize.height - page.cursorY, 0))
        if !page.isEmpty, page.cursorY + spacerHeight > contentSize.height {
            pages.append(page.build(chapterTitle: chapterTitle, bottomJustify: theme.prefersBottomAlignedContent))
            page = ReaderPageBuildState(contentSize: contentSize, bodyLineAdvance: theme.bodyLineHeight)
        }
        page.appendAttachment(
            sourceRange: NSRange(location: Int(fragment.chapterStartPosition), length: 0),
            frame: CGRect(x: 0, y: page.cursorY, width: contentSize.width, height: spacerHeight),
            contentMode: .scaleToFill,
            source: .spacer(height: spacerHeight),
            previewText: nil
        )
    }

    private func emptyPage(chapterTitle: String, contentSize: CGSize) -> ReaderPageLayout {
        ReaderPageLayout(
            textFragments: [],
            attachmentFragments: [],
            chapterTitle: chapterTitle,
            characterOffset: 0,
            previewText: chapterTitle,
            contentSize: contentSize
        )
    }

    private func makeAttributedText(
        block: ReaderContentBlock,
        theme: ReaderThemeController,
        lineBreakMode: NSLineBreakMode = .byWordWrapping
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = lineBreakMode
        paragraph.lineBreakStrategy = theme.useZhLayout ? [.standard, .pushOut, .hangulWordPriority] : []
        let font = block.type == .heading ? theme.titleFont : theme.font
        let targetLineHeight = block.type == .heading ? theme.titleLineHeight : theme.bodyLineHeight
        paragraph.lineSpacing = max(targetLineHeight - font.lineHeight, 0)
        paragraph.paragraphSpacing = 0
        paragraph.alignment = block.type == .heading && theme.titleMode == 1 ? .center : theme.textAlignment
        let indentWidth =
            (fullWidthSpaceWidth(font: theme.font) + theme.letterSpacing * theme.font.pointSize)
            * CGFloat(theme.paragraphIndentCount)
        paragraph.firstLineHeadIndent = block.type == .paragraph ? indentWidth : 0

        let strokeWidth = block.type == .heading ? theme.titleStrokeWidth : theme.bodyStrokeWidth
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: theme.textColor,
            .paragraphStyle: paragraph,
            .kern: theme.letterSpacing * font.pointSize,
            .underlineStyle: theme.underline ? NSUnderlineStyle.single.rawValue : 0,
        ]
        if strokeWidth != 0 {
            attributes[.strokeWidth] = strokeWidth
            attributes[.strokeColor] = theme.textColor
        }
        let convertedText = convert(text: block.text, mode: theme.chineseMode)
        return NSAttributedString(
            string: convertedText,
            attributes: attributes
        )
    }

    private func adjustedFragmentText(
        _ attributedText: NSAttributedString,
        isContinuation: Bool,
        isParagraphEnd: Bool,
        kind: ReaderTextBlockKind,
        suppressParagraphSpacing: Bool,
        contentWidth: CGFloat,
        theme: ReaderThemeController
    ) -> NSAttributedString {
        guard kind == .paragraph, attributedText.length > 0 else {
            return attributedText
        }
        let adjusted = NSMutableAttributedString(attributedString: attributedText)
        let fullRange = NSRange(location: 0, length: adjusted.length)
        adjusted.enumerateAttribute(.paragraphStyle, in: fullRange) { value, range, _ in
            guard let style = value as? NSParagraphStyle else { return }
            let mutableStyle = style.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            if isContinuation {
                mutableStyle.firstLineHeadIndent = 0
            }
            if suppressParagraphSpacing {
                mutableStyle.paragraphSpacing = 0
            }
            adjusted.addAttribute(.paragraphStyle, value: mutableStyle, range: range)
        }
        if theme.textAlignment == .justified, isParagraphEnd == false {
            justifySingleLine(adjusted, contentWidth: contentWidth)
        }
        return adjusted
    }

    private func justifySingleLine(_ attributedText: NSMutableAttributedString, contentWidth: CGFloat) {
        guard attributedText.length > 1 else { return }
        var paragraphIndent: CGFloat = 0
        if let style = attributedText.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle {
            paragraphIndent = style.firstLineHeadIndent
        }
        let targetWidth = max(contentWidth - paragraphIndent, 1)
        let residualWidth = targetWidth - ceil(textLineWidth(attributedText))
        guard residualWidth > 0.05 else { return }
        let nsString = attributedText.string as NSString
        let gapRanges = justificationGapRanges(in: nsString)
        guard gapRanges.isEmpty == false else { return }
        let extraSpacing = residualWidth / CGFloat(gapRanges.count)
        guard extraSpacing > 0.05, extraSpacing < 12 else { return }
        gapRanges.forEach { addKernOffset(extraSpacing, to: $0, in: attributedText) }
    }

    private func textLineWidth(_ attributedText: NSAttributedString) -> CGFloat {
        let line = CTLineCreateWithAttributedString(attributedText)
        return max(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line)), 0)
    }

    private func justificationGapRanges(in string: NSString) -> [NSRange] {
        guard string.length > 0 else { return [] }
        let first = string.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted)
        let last = string.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted, options: .backwards)
        guard first.location != NSNotFound, last.location != NSNotFound else { return [] }
        let visibleEnd = last.upperBound
        let spaces: [NSRange] = (first.location..<visibleEnd).compactMap { index in
            string.substring(with: NSRange(location: index, length: 1)) == " "
                ? NSRange(location: index, length: 1)
                : nil
        }
        if spaces.isEmpty == false { return spaces }

        // For unspaced text, expand only legal breaks, never the inside of a word or grapheme.
        guard
            let tokenizer = CFStringTokenizerCreate(
                nil, string as CFString, CFRange(location: 0, length: string.length),
                kCFStringTokenizerUnitLineBreak, nil
            )
        else { return [] }
        var gaps: [NSRange] = []
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != CFStringTokenizerTokenType() {
            let tokenRange = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let boundary = tokenRange.location + tokenRange.length
            guard tokenRange.location != kCFNotFound, tokenRange.length > 0,
                boundary > first.location, boundary < visibleEnd
            else { continue }
            let gap = string.rangeOfComposedCharacterSequence(at: boundary - 1)
            if gap.upperBound == boundary { gaps.append(gap) }
        }
        return gaps
    }

    private func addKernOffset(_ offset: CGFloat, to range: NSRange, in attributedText: NSMutableAttributedString) {
        guard range.length > 0, range.location + range.length <= attributedText.length else { return }
        let baseKern = (attributedText.attribute(.kern, at: range.location, effectiveRange: nil) as? CGFloat) ?? 0
        attributedText.addAttribute(.kern, value: baseKern + offset, range: range)
    }

    private func lineFrameHeight(
        for attributed: NSAttributedString,
        kind: ReaderTextBlockKind,
        contentSize: CGSize,
        theme: ReaderThemeController
    ) -> CGFloat {
        max(
            coreTextMeasurementBackend.measureHeight(attributed, width: contentSize.width),
            minimumLineHeight(for: kind, theme: theme))
    }

    private func visualLineRanges(
        for attributed: NSAttributedString,
        contentSize: CGSize
    ) -> [NSRange] {
        guard attributed.length > 0 else { return [] }
        let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
        let path = CGPath(
            rect: CGRect(x: 0, y: 0, width: max(contentSize.width, 1), height: .greatestFiniteMagnitude),
            transform: nil
        )
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: attributed.length), path, nil)
        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        return lines.compactMap { line in
            let range = CTLineGetStringRange(line)
            guard range.location != kCFNotFound, range.length > 0 else { return nil }
            let upperBound = min(range.location + range.length, attributed.length)
            guard upperBound > range.location else { return nil }
            return NSRange(location: range.location, length: upperBound - range.location)
        }
    }

    private func minimumLineHeight(for kind: ReaderTextBlockKind, theme: ReaderThemeController) -> CGFloat {
        max(kind == .heading ? theme.titleFont.lineHeight : theme.font.lineHeight, 1)
    }

    private func paragraphSpacing(for kind: ReaderTextBlockKind, theme: ReaderThemeController) -> CGFloat {
        max(kind == .heading ? theme.headingParagraphSpacing : theme.paragraphSpacing, 0)
    }

    private func adjustedContinuation(
        _ attributedText: NSAttributedString,
        isContinuation: Bool,
        kind: ReaderTextBlockKind
    ) -> NSAttributedString {
        guard isContinuation, kind == .paragraph, attributedText.length > 0 else {
            return attributedText
        }
        let adjusted = NSMutableAttributedString(attributedString: attributedText)
        let firstParagraphRange = (adjusted.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
        adjusted.enumerateAttribute(.paragraphStyle, in: firstParagraphRange) { value, range, _ in
            guard let style = value as? NSParagraphStyle else { return }
            let mutableStyle = style.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            mutableStyle.firstLineHeadIndent = 0
            adjusted.addAttribute(.paragraphStyle, value: mutableStyle, range: range)
        }
        return adjusted
    }
}

private func imageFrameHeight(style: String, contentSize: CGSize, theme: ReaderThemeController) -> CGFloat {
    switch style {
    case "TEXT":
        return max(theme.bodyLineHeight, 24)
    case "FULL":
        return min(contentSize.height, max(contentSize.height * 0.72, theme.bodyLineHeight * 8))
    case "SINGLE":
        return contentSize.height
    default:
        return min(max(theme.bodyLineHeight * 6, 120), contentSize.height)
    }
}

private func imageFrameWidth(style: String, contentSize: CGSize, height: CGFloat, theme _: ReaderThemeController) -> CGFloat {
    switch style {
    case "TEXT":
        return min(max(height * 1.4, 32), contentSize.width)
    default:
        return contentSize.width
    }
}

private func convert(text: String, mode: Int) -> String {
    guard mode != 0 else { return text }
    let transform =
        mode == 1
        ? StringTransform("Traditional-Simplified")
        : StringTransform("Simplified-Traditional")
    let converted = text.applyingTransform(transform, reverse: false) ?? text
    // Selection and progress use the original chapter's UTF-16 coordinates.
    return (converted as NSString).length == (text as NSString).length ? converted : text
}

private func fullWidthSpaceWidth(font: UIFont) -> CGFloat {
    ("　" as NSString).size(withAttributes: [.font: font]).width
}

extension ReaderChapterLayout {
    fileprivate var normalizedImageStyle: String {
        switch imageStyle?.uppercased() {
        case "FULL":
            return "FULL"
        case "TEXT":
            return "TEXT"
        case "SINGLE":
            return "SINGLE"
        default:
            return "DEFAULT"
        }
    }
}
