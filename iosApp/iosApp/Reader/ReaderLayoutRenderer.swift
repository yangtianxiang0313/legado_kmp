import CoreText
import UIKit
import shared

// A fresh instance belongs to one synchronous operation; CoreText layout objects never escape it.
final class ReaderLayoutRenderer {
    private let coreTextMeasurementBackend = CoreTextMeasurementBackend()
    private let cancellation: ReaderPaginationCancellation?
    private var interrupted = false

    init(cancellation: ReaderPaginationCancellation? = nil) {
        self.cancellation = cancellation
    }

    var isCancelled: Bool {
        interrupted || cancellation?.isCancelled == true
    }

    func renderMeasuredPages(
        layout: ReaderChapterLayout,
        contentSize: CGSize,
        theme: ReaderThemeController,
        imageStyle: String,
        imageSizes: [String: CGSize] = [:],
        imageScale: CGFloat = 1,
        isScrollMode: Bool = false
    ) -> [ReaderPageLayout] {
        guard !isCancelled else { return [] }
        let contentSize = CGSize(
            width: contentSize.width.isFinite ? max(contentSize.width, 1) : 1,
            height: contentSize.height.isFinite ? max(contentSize.height, 1) : 1)
        var pages: [ReaderPageLayout] = []
        var page = ReaderPageBuildState(contentSize: contentSize, bodyLineAdvance: theme.bodyLineHeight)
        var pendingTextFragments: [ReaderPageFragment] = []
        let searchableText = layout.searchableText as NSString
        var searchableLocation = 0
        let inlineComposer = imageStyle == "TEXT" ? ReaderInlineImageComposer(layout: layout, isCancelled: { self.isCancelled }) : nil
        var composedGroups: Set<Int> = []
        var unavailableGroups: Set<Int> = []

        func flushTextFragments() {
            guard !isCancelled else { return }
            guard let first = pendingTextFragments.first, let last = pendingTextFragments.last else { return }
            let sourceLength = max(Int(last.chapterEndPosition - first.chapterStartPosition), 0)
            let searchRange = NSRange(location: searchableLocation, length: sourceLength)
            let logicalText: String
            if searchRange.location <= searchableText.length, searchRange.length <= searchableText.length - searchRange.location {
                logicalText = searchableText.substring(with: searchRange)
            } else {
                // Without canonical source text, retain ambiguous newlines rather than erase hard breaks.
                var text = ""
                for fragment in pendingTextFragments {
                    guard !isCancelled else { return }
                    text.append(fragment.text)
                }
                logicalText = text
            }
            guard !isCancelled else { return }
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
            guard !isCancelled else { return }
            guard !page.isEmpty else { return }
            pages.append(page.build(chapterTitle: layout.chapterTitle, bottomJustify: theme.prefersBottomAlignedContent))
            page = ReaderPageBuildState(contentSize: contentSize, bodyLineAdvance: theme.bodyLineHeight)
        }

        for sourcePage in layout.pages {
            guard !isCancelled else { return [] }
            for fragment in sourcePage.fragments {
                guard !isCancelled else { return [] }
                if let inlineComposer, let group = inlineComposer.groupIndex(for: Int(fragment.blockIndex)),
                    !unavailableGroups.contains(group)
                {
                    if composedGroups.contains(group) { continue }
                    flushTextFragments()
                    guard !isCancelled else { return [] }
                    let paragraph = inlineComposer.compose(
                        group: group, searchableText: searchableText, searchableStart: searchableLocation,
                        contentSize: contentSize, lineHeight: minimumLineHeight(for: .paragraph, theme: theme),
                        makeText: { text in
                            self.makeAttributedText(
                                block: ReaderContentBlock(
                                    blockIndex: 0, type: .paragraph, text: text, imageUrl: nil, imageAlt: nil,
                                    imageWidth: 0, imageHeight: 0),
                                theme: theme)
                        },
                        adjustLine: { text, continuation, end in
                            self.adjustedFragmentText(
                                text, isContinuation: continuation, isParagraphEnd: end, kind: .paragraph,
                                suppressParagraphSpacing: true, contentWidth: contentSize.width, theme: theme)
                        },
                        isCancelled: { self.isCancelled })
                    guard !isCancelled else { return [] }
                    if let paragraph {
                        searchableLocation = paragraph.searchableEnd
                        appendInlineParagraph(
                            paragraph, to: &page, pages: &pages, chapterTitle: layout.chapterTitle,
                            contentSize: contentSize, theme: theme)
                        composedGroups.insert(group)
                        continue
                    }
                    // Invalid caller-supplied hints must not hide the legacy chapter content.
                    unavailableGroups.insert(group)
                }
                switch fragment.kind {
                case .heading, .paragraph:
                    if let previous = pendingTextFragments.last,
                        canJoinTextFragments(previous, fragment) == false
                    {
                        flushTextFragments()
                    }
                    guard !isCancelled else { return [] }
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
                        imageStyle: imageStyle,
                        imageSizes: imageSizes,
                        imageScale: imageScale,
                        isScrollMode: isScrollMode
                    )

                case .spacer:
                    flushTextFragments()
                    if imageStyle == "SINGLE", page.isEmpty { continue }
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
        guard !isCancelled else { return [] }
        flushPage()
        return pages
    }

    private func canJoinTextFragments(_ previous: ReaderPageFragment, _ next: ReaderPageFragment) -> Bool {
        previous.kind == next.kind && previous.blockIndex == next.blockIndex && previous.isParagraphEnd == false
            && next.isContinuation
            && previous.chapterEndPosition == next.chapterStartPosition
    }

    private func appendInlineParagraph(
        _ paragraph: ReaderInlineImageComposer.Paragraph,
        to page: inout ReaderPageBuildState,
        pages: inout [ReaderPageLayout],
        chapterTitle: String,
        contentSize: CGSize,
        theme: ReaderThemeController
    ) {
        let height = minimumLineHeight(for: .paragraph, theme: theme)
        for line in paragraph.lines {
            guard !isCancelled else { return }
            let source = line.sourceMap.sourceRange
            preparePageForContent(
                height: height, sourceLocation: source.location, to: &page, pages: &pages,
                chapterTitle: chapterTitle, contentSize: contentSize, theme: theme)
            let y = page.cursorY
            page.appendText(
                line.text, sourceRange: source, height: height, kind: .paragraph, blockIndex: line.blockIndex,
                isContinuation: line.isContinuation, advance: theme.bodyLineHeight, sourceMap: line.sourceMap)
            for image in line.images {
                guard !isCancelled else { return }
                page.appendAttachment(
                    sourceRange: image.sourceRange, frame: image.frame.offsetBy(dx: 0, dy: y),
                    contentMode: .scaleAspectFit, source: .remoteImage(url: image.url, altText: image.altText),
                    previewText: nil, requestRule: image.requestRule, inlineAnchorSourceRange: source)
            }
            if line.endsParagraph { page.pendingBlockSpacing = paragraphSpacing(for: .paragraph, theme: theme) }
        }
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
        guard !isCancelled else { return }
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
        guard !isCancelled else { return }
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
        guard !isCancelled else { return }
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
        guard !isCancelled else { return 0 }
        guard let lineRanges = visualLineRanges(for: attributed, contentSize: contentSize) else {
            interrupted = true
            return 0
        }
        guard !isCancelled else { return 0 }
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
        var paragraphRange: NSRange?
        for lineRange in lineRanges {
            guard !isCancelled else { return consumedLength }
            guard lineRange.length > 0, lineRange.location + lineRange.length <= attributed.length else { continue }
            let lineContinuation: Bool
            if lineRange.location == 0 {
                lineContinuation = isContinuation
            } else {
                // NSString preserves CRLF and Unicode paragraph boundaries. Reuse
                // its range so each soft-wrapped row does not rescan a long block.
                if paragraphRange.map({ NSLocationInRange(lineRange.location, $0) }) != true {
                    paragraphRange = text.paragraphRange(for: NSRange(location: lineRange.location, length: 0))
                }
                lineContinuation = (paragraphRange?.location ?? lineRange.location) < lineRange.location
            }
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
            guard !isCancelled else { return consumedLength }
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
        guard !isCancelled else { return 0 }
        let measuredHeight = lineFrameHeight(for: attributed, kind: kind, contentSize: contentSize, theme: theme)
        guard !isCancelled else { return 0 }
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
            sourceRange: NSRange(
                location: sourceLocation, length: sourceRangeLength(attributed.length, from: sourceLocation, to: sourceEnd)),
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
        guard !isCancelled else { return }
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
        imageStyle: String,
        imageSizes: [String: CGSize],
        imageScale: CGFloat,
        isScrollMode: Bool
    ) {
        guard !isCancelled else { return }
        guard let urlString = fragment.imageUrl,
            let url = URL(string: urlString)
                ?? urlString.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed)
                .flatMap({ URL(string: $0) })
        else { return }
        let geometry = ReaderImageLayoutGeometry(
            style: imageStyle,
            pixelSize: imageSizes[urlString],
            imageScale: imageScale,
            contentSize: contentSize,
            bodyLineHeight: theme.bodyLineHeight,
            isScrollMode: isScrollMode
        )
        if geometry.occupiesWholePage {
            if !page.isEmpty {
                pages.append(page.build(chapterTitle: chapterTitle, bottomJustify: theme.prefersBottomAlignedContent))
            }
            page = ReaderPageBuildState(contentSize: contentSize, bodyLineAdvance: theme.bodyLineHeight)
        } else {
            if geometry.allowsVerticalOverflow, !page.cursorY.isFinite {
                if !page.isEmpty {
                    pages.append(page.build(chapterTitle: chapterTitle, bottomJustify: false))
                }
                page = ReaderPageBuildState(contentSize: contentSize, bodyLineAdvance: theme.bodyLineHeight)
            }
            // FULL scroll keeps preceding text: only the image's start must fit the base page.
            preparePageForContent(
                height: geometry.allowsVerticalOverflow ? 0 : geometry.size.height,
                sourceLocation: Int(fragment.chapterStartPosition),
                to: &page,
                pages: &pages,
                chapterTitle: chapterTitle,
                contentSize: contentSize,
                theme: theme
            )
        }
        guard !isCancelled else { return }
        if geometry.allowsVerticalOverflow, !(page.cursorY + geometry.size.height).isFinite {
            if !page.isEmpty {
                pages.append(page.build(chapterTitle: chapterTitle, bottomJustify: false))
            }
            page = ReaderPageBuildState(contentSize: contentSize, bodyLineAdvance: theme.bodyLineHeight)
        }
        let imageFrame = geometry.frame(cursorY: page.cursorY)
        page.appendAttachment(
            sourceRange: NSRange(
                location: Int(fragment.chapterStartPosition),
                length: max(Int(fragment.chapterEndPosition - fragment.chapterStartPosition), 1)),
            frame: imageFrame,
            contentMode: .scaleAspectFit,
            source: .remoteImage(url: url, altText: fragment.imageAlt),
            previewText: fragment.imageAlt,
            requestRule: urlString
        )
        if geometry.allowsVerticalOverflow, imageFrame.maxY.isFinite, imageFrame.maxY > contentSize.height {
            page.fullScrollImageOverflowExtent = max(page.fullScrollImageOverflowExtent ?? 0, imageFrame.maxY)
        }
        if geometry.occupiesWholePage {
            // Commit the centered image without justification or synthetic source coordinates.
            pages.append(page.build(chapterTitle: chapterTitle, bottomJustify: false))
            page = ReaderPageBuildState(contentSize: contentSize, bodyLineAdvance: theme.bodyLineHeight)
        } else {
            page.pendingBlockSpacing = max(theme.paragraphSpacing, 0)
        }
    }

    private func appendSpacerFragment(
        _ fragment: ReaderPageFragment,
        to page: inout ReaderPageBuildState,
        pages: inout [ReaderPageLayout],
        chapterTitle: String,
        contentSize: CGSize,
        theme: ReaderThemeController
    ) {
        guard !isCancelled else { return }
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

    static func emptyPage(chapterTitle: String, contentSize: CGSize) -> ReaderPageLayout {
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
        guard !isCancelled else { return NSAttributedString(string: "") }
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
            .paragraphStyle: paragraph.copy(),
            .kern: theme.letterSpacing * font.pointSize,
            .underlineStyle: theme.underline ? NSUnderlineStyle.single.rawValue : 0,
        ]
        if strokeWidth != 0 {
            attributes[.strokeWidth] = strokeWidth
            attributes[.strokeColor] = theme.textColor
        }
        let convertedText = convert(text: block.text, mode: theme.chineseMode)
        guard !isCancelled else { return NSAttributedString(string: "") }
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
        adjusted.enumerateAttribute(.paragraphStyle, in: fullRange) { value, range, stop in
            guard !self.isCancelled else {
                stop.pointee = true
                return
            }
            guard let style = value as? NSParagraphStyle else { return }
            let mutableStyle = style.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            if isContinuation {
                mutableStyle.firstLineHeadIndent = 0
            }
            if suppressParagraphSpacing {
                mutableStyle.paragraphSpacing = 0
            }
            adjusted.addAttribute(.paragraphStyle, value: mutableStyle.copy(), range: range)
        }
        guard !isCancelled else { return attributedText }
        if theme.textAlignment == .justified, isParagraphEnd == false {
            justifySingleLine(adjusted, contentWidth: contentWidth)
        }
        return NSAttributedString(attributedString: adjusted)
    }

    private func justifySingleLine(_ attributedText: NSMutableAttributedString, contentWidth: CGFloat) {
        guard !isCancelled else { return }
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
        for range in gapRanges {
            guard !isCancelled else { return }
            addKernOffset(extraSpacing, to: range, in: attributedText)
        }
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
        var spaces: [NSRange] = []
        for index in first.location..<visibleEnd {
            guard !isCancelled else { return [] }
            if string.substring(with: NSRange(location: index, length: 1)) == " " {
                spaces.append(NSRange(location: index, length: 1))
            }
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
            guard !isCancelled else { return [] }
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
    ) -> [NSRange]? {
        ReaderVisualLineRanges.collect(for: attributed, contentSize: contentSize, isCancelled: { self.isCancelled })
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
        adjusted.enumerateAttribute(.paragraphStyle, in: firstParagraphRange) { value, range, stop in
            guard !self.isCancelled else {
                stop.pointee = true
                return
            }
            guard let style = value as? NSParagraphStyle else { return }
            let mutableStyle = style.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            mutableStyle.firstLineHeadIndent = 0
            adjusted.addAttribute(.paragraphStyle, value: mutableStyle.copy(), range: range)
        }
        return NSAttributedString(attributedString: adjusted)
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
