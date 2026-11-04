import Foundation

/// Display UTF-16 coordinates are local; source UTF-16 coordinates always belong to the chapter.
struct ReaderTextSourceMap: Equatable {
    struct Span: Equatable {
        let displayRange: NSRange
        let sourceRange: NSRange
        let kind: Kind
    }

    enum Kind: Equatable {
        case text(blockIndex: Int)
        case image(altText: String?)
        case spacing
    }

    let spans: [Span]

    init(spans: [Span]) {
        self.spans = spans.filter { span in
            guard Self.isValid(span.displayRange), span.displayRange.length > 0,
                Self.isValid(span.sourceRange)
            else { return false }
            switch span.kind {
            case .text:
                return span.displayRange.length == span.sourceRange.length
            case .image:
                return span.displayRange.length == 1 && span.sourceRange.length == 1
            case .spacing:
                return span.sourceRange.length == 0
            }
        }.sorted {
            if $0.displayRange.location != $1.displayRange.location {
                return $0.displayRange.location < $1.displayRange.location
            }
            return $0.displayRange.length < $1.displayRange.length
        }
    }

    var displayRange: NSRange {
        guard let first = spans.first, let last = spans.last else { return NSRange(location: 0, length: 0) }
        return NSRange(location: first.displayRange.location, length: last.displayRange.upperBound - first.displayRange.location)
    }

    /// Includes image source units and zero-length anchors, without inventing coordinates for spacing.
    var sourceRange: NSRange {
        guard let start = spans.map(\.sourceRange.location).min(),
            let end = spans.map(\.sourceRange.upperBound).max()
        else { return NSRange(location: 0, length: 0) }
        return NSRange(location: start, length: end - start)
    }

    var blockIndices: Set<Int> {
        Set(
            spans.compactMap { span in
                if case .text(let blockIndex) = span.kind { return blockIndex }
                return nil
            })
    }

    /// Returns local display ranges, not chapter source ranges.
    func textRanges(forBlockIndex blockIndex: Int) -> [NSRange] {
        spans.compactMap { span in
            if case .text(let index) = span.kind, index == blockIndex { return span.displayRange }
            return nil
        }
    }

    /// The hull of selectable text only. An image-only or spacing-only hit has no source selection.
    func sourceRange(forDisplayRange range: NSRange) -> NSRange? {
        guard Self.isValid(range), range.length > 0 else { return nil }
        let ranges = spans.compactMap { span -> NSRange? in
            guard case .text = span.kind else { return nil }
            let overlap = NSIntersectionRange(span.displayRange, range)
            guard overlap.length > 0 else { return nil }
            return NSRange(
                location: span.sourceRange.location + overlap.location - span.displayRange.location,
                length: overlap.length)
        }
        guard let start = ranges.map(\.location).min(), let end = ranges.map(\.upperBound).max() else { return nil }
        return NSRange(location: start, length: end - start)
    }

    /// Spacing is never a selectable character. Copying adds it separately when its anchor is crossed.
    func displayRanges(forSourceRange range: NSRange, includeImages: Bool = false) -> [NSRange] {
        guard Self.isValid(range), range.length > 0 else { return [] }
        return spans.compactMap { span in
            switch span.kind {
            case .text: break
            case .image where includeImages: break
            case .image, .spacing: return nil
            }
            let overlap = NSIntersectionRange(span.sourceRange, range)
            guard overlap.length > 0 else { return nil }
            return NSRange(
                location: span.displayRange.location + overlap.location - span.sourceRange.location,
                length: overlap.length)
        }
    }

    /// A continuous, one-to-one text run, bounded by images, virtual spacing and semantic block changes.
    func textRange(containingDisplayRange range: NSRange) -> NSRange? {
        guard Self.isValid(range), range.length > 0 else { return nil }
        var run: Span?
        for span in spans {
            if case .text = span.kind {
                if let previous = run, previous.kind == span.kind,
                    previous.displayRange.upperBound == span.displayRange.location,
                    previous.sourceRange.upperBound == span.sourceRange.location
                {
                    run = Span(
                        displayRange: NSUnionRange(previous.displayRange, span.displayRange),
                        sourceRange: NSUnionRange(previous.sourceRange, span.sourceRange), kind: span.kind)
                } else {
                    if let previous = run, NSIntersectionRange(previous.displayRange, range) == range {
                        return previous.displayRange
                    }
                    run = span
                }
            } else {
                if let previous = run, NSIntersectionRange(previous.displayRange, range) == range {
                    return previous.displayRange
                }
                run = nil
            }
        }
        guard let run, NSIntersectionRange(run.displayRange, range) == range else { return nil }
        return run.displayRange
    }

    /// Whole graphemes only; the returned ranges never bridge an image or a virtual-space span.
    func selectionDisplayRanges(in display: String, sourceRange range: NSRange) -> [NSRange] {
        let text = display as NSString
        let bounds = NSRange(location: 0, length: text.length)
        var result: [NSRange] = []
        for range in displayRanges(forSourceRange: range) {
            let clipped = NSIntersectionRange(range, bounds)
            guard clipped.length > 0 else { continue }
            let composed = text.rangeOfComposedCharacterSequences(for: clipped)
            guard textRange(containingDisplayRange: composed) != nil else { continue }
            if let previous = result.last, NSIntersectionRange(previous, composed).length > 0 {
                result[result.count - 1] = NSUnionRange(previous, composed)
            } else {
                result.append(composed)
            }
        }
        return result
    }

    func selectedText(in display: String, sourceRange range: NSRange) -> String {
        guard Self.isValid(range), range.length > 0 else { return "" }
        let text = display as NSString
        var ranges = selectionDisplayRanges(in: display, sourceRange: range)
        ranges.append(
            contentsOf: spans.compactMap { span in
                guard case .spacing = span.kind,
                    range.location < span.sourceRange.location, span.sourceRange.location < range.upperBound
                else { return nil }
                return span.displayRange
            })
        return ranges.sorted { $0.location < $1.location }.map { Self.substring(text, in: $0) }.joined()
    }

    /// Visible plain text retains original spacing, but never exposes object-replacement characters.
    func plainText(in display: String) -> String {
        let text = display as NSString
        return spans.map { span in
            if case .image = span.kind { return "" }
            return Self.substring(text, in: span.displayRange)
        }.joined()
    }

    func accessibilityText(in display: String) -> String {
        let text = display as NSString
        return spans.map { span in
            if case .image(let altText) = span.kind { return altText ?? "" }
            return Self.substring(text, in: span.displayRange)
        }.joined()
    }

    func submap(in range: NSRange) -> Self {
        guard Self.isValid(range), range.length > 0 else { return Self(spans: []) }
        return Self(
            spans: spans.compactMap { span in
                let overlap = NSIntersectionRange(span.displayRange, range)
                guard overlap.length > 0 else { return nil }
                let source: NSRange
                if case .spacing = span.kind {
                    source = span.sourceRange
                } else {
                    source = NSRange(
                        location: span.sourceRange.location + overlap.location - span.displayRange.location,
                        length: overlap.length)
                }
                return Span(
                    displayRange: NSRange(location: overlap.location - range.location, length: overlap.length),
                    sourceRange: source, kind: span.kind)
            })
    }

    private static func isValid(_ range: NSRange) -> Bool {
        range.location >= 0 && range.location != NSNotFound && range.length >= 0
            && range.length <= Int.max - range.location
    }

    private static func substring(_ text: NSString, in range: NSRange) -> String {
        let clipped = NSIntersectionRange(range, NSRange(location: 0, length: text.length))
        return clipped.length > 0 ? text.substring(with: clipped) : ""
    }
}
