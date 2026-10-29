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
                continuesText =
                    current.isContinuation && current.blockIndex == previous.blockIndex && current.kind == previous.kind
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
        let pages = ReaderLayoutRenderer().renderMeasuredPages(
            layout: layout,
            contentSize: contentSize,
            theme: theme,
            imageStyle: layout.normalizedImageStyle
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
        traits: UITraitCollection? = nil
    ) async throws -> PaginationResult {
        try Task.checkCancellation()
        let input = ReaderPaginationInput.frozen(
            layout: layout, bounds: bounds, theme: theme, traits: traits ?? UITraitCollection.current)
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
