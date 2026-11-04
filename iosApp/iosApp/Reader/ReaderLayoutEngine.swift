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
        if textFragments.contains(where: { $0.sourceMap != nil }) {
            var text = ""
            var previous: ReaderTextLayoutFragment?
            for fragment in textFragments {
                let display = fragment.attributedText.string
                let part = fragment.sourceMap?.plainText(in: display) ?? display
                if !part.isEmpty, !text.isEmpty, !fragment.continuesText(from: previous),
                    text.last?.isNewline != true, part.first?.isNewline != true
                {
                    text.append("\n")
                }
                text.append(part)
                previous = fragment
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return
            textFragments
            .map { $0.attributedText.string.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
            .joined(separator: "\n")
    }

    var accessibilityText: String {
        var fragments: [(text: String, frame: CGRect, index: Int, fragment: ReaderTextLayoutFragment?)] =
            textFragments.enumerated().map { index, fragment in
                let display = fragment.attributedText.string
                return (fragment.sourceMap?.accessibilityText(in: display) ?? display, fragment.frame, index, fragment)
            }
        for (index, attachment) in attachmentFragments.enumerated() {
            guard case .remoteImage(_, let altText) = attachment.source else {
                continue
            }
            if textFragments.contains(where: { fragment in
                fragment.sourceMap?.spans.contains(where: { span in
                    guard case .image = span.kind else { return false }
                    return span.sourceRange == (attachment.inlineAnchorSourceRange ?? attachment.sourceRange)
                        || span.sourceRange == attachment.sourceRange
                }) == true
            }) {
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
            if item.text.isEmpty {
                if item.fragment?.sourceMap != nil { previousTextFragment = item.fragment }
                continue
            }
            let continuesText: Bool
            if let previous = previousTextFragment, let current = item.fragment {
                if previous.sourceMap != nil || current.sourceMap != nil {
                    continuesText = current.continuesText(from: previous)
                } else {
                    continuesText =
                        current.isContinuation && current.blockIndex == previous.blockIndex && current.kind == previous.kind
                }
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
            if let map = fragment.sourceMap {
                return map.displayRanges(forSourceRange: range).isEmpty ? nil : fragment.frame
            }
            return NSIntersectionRange(fragment.sourceRange, range).length > 0 ? fragment.frame : nil
        }
    }

    func characterRange(at point: CGPoint) -> NSRange? {
        if let fragment = textFragments.first(where: { $0.frame.contains(point) }) {
            if fragment.sourceMap != nil {
                if let attachment = attachmentFragments.first(where: { $0.frame.contains(point) }) {
                    return attachment.sourceRange
                }
                return ReaderTextSelectionGeometry(fragment: fragment).characterRange(at: point)
            }
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
        if textFragments.contains(where: { $0.sourceMap != nil }) {
            return Self.mappedSelectedText(for: range, in: [self])
        }
        var parts: [String] = []
        for fragment in textFragments {
            if let map = fragment.sourceMap {
                parts.append(map.selectedText(in: fragment.attributedText.string, sourceRange: range))
                continue
            }
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
        if pages.contains(where: { $0.textFragments.contains(where: { $0.sourceMap != nil }) }) {
            return mappedSelectedText(for: range, in: pages)
        }
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

    private static func mappedSelectedText(for range: NSRange, in pages: [ReaderPageLayout]) -> String {
        let selectedTextRanges = pages.flatMap(\.textFragments).flatMap { fragment -> [NSRange] in
            if let map = fragment.sourceMap {
                return map.selectionDisplayRanges(in: fragment.attributedText.string, sourceRange: range).compactMap {
                    map.sourceRange(forDisplayRange: $0)
                }
            }
            guard let local = ReaderTextSelectionGeometry.localSelectionRange(for: range, in: fragment) else { return [] }
            return [NSRange(location: fragment.sourceRange.location + local.location, length: local.length)]
        }
        guard let selectionStart = selectedTextRanges.map(\.location).min(),
            let selectionEnd = selectedTextRanges.map(\.upperBound).max(), selectionEnd > selectionStart
        else { return "" }
        // Images at the outer edges are not selectable text and cannot introduce copy-only spaces.
        let range = NSRange(location: selectionStart, length: selectionEnd - selectionStart)
        let fragments = pages.flatMap(\.textFragments).enumerated().sorted {
            let lhs = $0.element.sourceMap?.sourceRange ?? $0.element.sourceRange
            let rhs = $1.element.sourceMap?.sourceRange ?? $1.element.sourceRange
            if lhs.location != rhs.location { return lhs.location < rhs.location }
            // A soft-wrapped virtual-space row belongs before the text starting
            // at its anchor, even though it consumes no chapter source units.
            if (lhs.length == 0) != (rhs.length == 0) { return lhs.length == 0 }
            if lhs.length != rhs.length { return lhs.length > rhs.length }
            return $0.offset < $1.offset
        }
        var result = ""
        var previousEnd: Int?
        var previousFragment: ReaderTextLayoutFragment?
        var previousFragmentIndex: Int?
        var coveredEnd: Int?
        for item in fragments {
            let fragment = item.element
            let text = fragment.attributedText.string as NSString
            let map: ReaderTextSourceMap
            if let sourceMap = fragment.sourceMap {
                map = sourceMap
            } else {
                guard let local = ReaderTextSelectionGeometry.localSelectionRange(for: fragment.sourceRange, in: fragment) else {
                    continue
                }
                map = ReaderTextSourceMap(spans: [
                    ReaderTextSourceMap.Span(
                        displayRange: local,
                        sourceRange: NSRange(location: fragment.sourceRange.location, length: local.length),
                        kind: .text(blockIndex: fragment.blockIndex))
                ])
            }
            let coverage = map.sourceRange
            if let coveredEnd, coverage.length > 0, coverage.upperBound <= coveredEnd { continue }
            var pieces = map.selectionDisplayRanges(in: text as String, sourceRange: range)
            for span in map.spans {
                if case .spacing = span.kind,
                    range.location < span.sourceRange.location, span.sourceRange.location < range.upperBound,
                    coveredEnd.map({ span.sourceRange.location >= $0 }) ?? true
                {
                    pieces.append(NSIntersectionRange(span.displayRange, NSRange(location: 0, length: text.length)))
                }
            }
            for var displayRange in pieces.sorted(by: { $0.location < $1.location }) where displayRange.length > 0 {
                guard var source = map.sourceRange(forDisplayRange: displayRange) else {
                    result.append(text.substring(with: displayRange))
                    continue
                }
                if let previousEnd, source.location < previousEnd {
                    guard source.upperBound > previousEnd else { continue }
                    let consumed = displayRange.location + previousEnd - source.location
                    let character = text.rangeOfComposedCharacterSequence(at: consumed)
                    let start = character.location < consumed ? character.upperBound : consumed
                    guard start < displayRange.upperBound else { continue }
                    displayRange = NSRange(location: start, length: displayRange.upperBound - start)
                    guard let remaining = map.sourceRange(forDisplayRange: displayRange) else { continue }
                    source = remaining
                }
                if let previousEnd, let previous = previousFragment, source.location >= previousEnd,
                    previousFragmentIndex != item.offset,
                    !(fragment.isContinuation && fragment.blockIndex == previous.blockIndex && fragment.kind == previous.kind),
                    result.last?.isNewline != true, text.substring(with: displayRange).first?.isNewline != true
                {
                    result.append("\n")
                }
                result.append(text.substring(with: displayRange))
                previousEnd = source.upperBound
                previousFragment = fragment
                previousFragmentIndex = item.offset
            }
            coveredEnd = max(coveredEnd ?? coverage.upperBound, coverage.upperBound)
        }
        return result
    }

    func contains(blockIndex: Int) -> Bool {
        textFragments.contains { fragment in
            fragment.sourceMap?.blockIndices.contains(blockIndex) ?? (fragment.blockIndex == blockIndex)
        }
    }

    var leadingBlockIndex: Int? {
        textFragments.compactMap(\.leadingTextBlockIndex).first
    }
}

struct ReaderTextLayoutFragment {
    let attributedText: NSAttributedString
    let sourceRange: NSRange
    let frame: CGRect
    let kind: ReaderTextBlockKind
    let blockIndex: Int
    let isContinuation: Bool
    let sourceMap: ReaderTextSourceMap?

    init(
        attributedText: NSAttributedString, sourceRange: NSRange, frame: CGRect,
        kind: ReaderTextBlockKind, blockIndex: Int, isContinuation: Bool,
        sourceMap: ReaderTextSourceMap? = nil
    ) {
        self.attributedText = attributedText
        self.sourceRange = sourceRange
        self.frame = frame
        self.kind = kind
        self.blockIndex = blockIndex
        self.isContinuation = isContinuation
        self.sourceMap = sourceMap
    }

    var leadingTextBlockIndex: Int? {
        guard let sourceMap else { return blockIndex }
        return sourceMap.spans.compactMap { span in
            if case .text(let index) = span.kind { return index }
            return nil
        }.first
    }

    func continuesText(from previous: ReaderTextLayoutFragment?) -> Bool {
        guard let previous, isContinuation, kind == previous.kind else { return false }
        if sourceMap == nil && previous.sourceMap == nil { return blockIndex == previous.blockIndex }
        let start = previous.sourceMap?.sourceRange ?? previous.sourceRange
        let end = sourceMap?.sourceRange ?? sourceRange
        return start.upperBound == end.location
    }

    func offsetBy(dx: CGFloat, dy: CGFloat) -> ReaderTextLayoutFragment {
        ReaderTextLayoutFragment(
            attributedText: attributedText,
            sourceRange: sourceRange,
            frame: frame.offsetBy(dx: dx, dy: dy),
            kind: kind,
            blockIndex: blockIndex,
            isContinuation: isContinuation,
            sourceMap: sourceMap
        )
    }
}

struct ReaderAttachmentLayoutFragment {
    let sourceRange: NSRange
    let frame: CGRect
    let contentMode: UIView.ContentMode
    let source: ReaderAttachmentSource
    // URL is the UI/cache identity; image request rules must survive URL encoding unchanged.
    let requestRule: String?
    let inlineAnchorSourceRange: NSRange?

    init(
        sourceRange: NSRange,
        frame: CGRect,
        contentMode: UIView.ContentMode,
        source: ReaderAttachmentSource,
        requestRule: String? = nil,
        inlineAnchorSourceRange: NSRange? = nil
    ) {
        self.sourceRange = sourceRange
        self.frame = frame
        self.contentMode = contentMode
        self.source = source
        self.requestRule = requestRule
        self.inlineAnchorSourceRange = inlineAnchorSourceRange
    }
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

    private let cache: ReaderPaginationCache<ReaderPaginationCacheKey>
    private let worker: ReaderPaginationWorker

    init() {
        let cache = ReaderPaginationCache<ReaderPaginationCacheKey>()
        self.cache = cache
        worker = ReaderPaginationWorker(cache: cache)
    }

    deinit {
        worker.cancelAll()
    }

    var cacheStatistics: ReaderPaginationCacheStatistics {
        cache.statistics
    }

    // Compatibility/reference path: intentionally synchronous on the caller's thread.
    func paginate(
        layout: ReaderChapterLayout,
        in bounds: CGRect,
        theme: ReaderThemeController,
        imageSizes: [String: CGSize] = [:],
        imageScale: CGFloat = 1
    ) -> PaginationResult {
        let pageGeometry = ReaderPageGeometry.estimated(bounds: bounds, theme: theme)
        let key = ReaderPaginationCacheKey(
            layout: layout,
            bounds: bounds,
            pageGeometry: pageGeometry,
            theme: theme,
            imageStyle: layout.normalizedImageStyle,
            imageSizes: imageSizes,
            imageScale: imageScale
        )
        if let cached = cache.value(for: key) {
            return cached
        }
        let contentSize = CGSize(
            width: max(pageGeometry.contentFrame.width, 1),
            height: max(pageGeometry.contentFrame.height, 1)
        )
        let pages = ReaderLayoutRenderer().renderMeasuredPages(
            layout: layout,
            contentSize: contentSize,
            theme: theme,
            imageStyle: layout.normalizedImageStyle,
            imageSizes: imageSizes,
            imageScale: imageScale
        )
        let result = PaginationResult(
            pages: pages.isEmpty
                ? [ReaderLayoutRenderer.emptyPage(chapterTitle: layout.chapterTitle, contentSize: contentSize)]
                : pages
        )
        cache.insert(result, for: key)
        return result
    }

    @MainActor
    func paginateAsync(
        layout: ReaderChapterLayout,
        in bounds: CGRect,
        theme: ReaderThemeController,
        traits: UITraitCollection? = nil,
        imageSizes: [String: CGSize] = [:]
    ) async throws -> PaginationResult {
        try Task.checkCancellation()
        let input = ReaderPaginationInput.frozen(
            layout: layout, bounds: bounds, theme: theme, traits: traits ?? UITraitCollection.current,
            imageSizes: imageSizes)
        let result = try await worker.paginate(input)
        // Cancellation may arrive after the worker resumes us but before MainActor runs again.
        try Task.checkCancellation()
        return result
    }
}

extension ReaderChapterLayout {
    var normalizedImageStyle: String {
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
