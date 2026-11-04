import CoreText
import UIKit

struct ReaderTextSelectionGeometry {
    struct Hit {
        /// Always a whole source UTF-16 grapheme, including when clamped to a row edge.
        let range: NSRange
        let startBoundary: Int
        let endBoundary: Int
        let isCharacter: Bool
        let startCaret: CGRect?
        let endCaret: CGRect?
    }

    struct WordContext {
        private let text: NSString
        private let sourceRange: NSRange
        private let sourceMap: ReaderTextSourceMap?

        init?(
            fragments: [ReaderTextLayoutFragment], attachments: [ReaderAttachmentLayoutFragment],
            containing index: Int, visibleBounds: CGRect
        ) {
            guard fragments.indices.contains(index),
                Self.mappedSourceRange(in: fragments[index], visibleBounds: visibleBounds) != nil
            else { return nil }
            var first = index
            var last = index
            while first > 0,
                Self.canJoin(fragments[first - 1], fragments[first], attachments: attachments, visibleBounds: visibleBounds)
            {
                first -= 1
            }
            while last + 1 < fragments.count,
                Self.canJoin(fragments[last], fragments[last + 1], attachments: attachments, visibleBounds: visibleBounds)
            {
                last += 1
            }
            if fragments[first...last].contains(where: { $0.sourceMap != nil }) {
                let joined = NSMutableString(capacity: 0)
                var spans: [ReaderTextSourceMap.Span] = []
                for fragment in fragments[first...last] {
                    let offset = joined.length
                    if let map = fragment.sourceMap {
                        let length = fragment.attributedText.length
                        spans.append(
                            contentsOf: map.submap(in: NSRange(location: 0, length: length)).spans.map {
                                ReaderTextSourceMap.Span(
                                    displayRange: NSRange(location: offset + $0.displayRange.location, length: $0.displayRange.length),
                                    sourceRange: $0.sourceRange, kind: $0.kind)
                            })
                        joined.append(fragment.attributedText.string)
                    } else {
                        let mapped = ReaderTextSelectionGeometry.mappedTextRange(in: fragment)
                        spans.append(
                            ReaderTextSourceMap.Span(
                                displayRange: NSRange(location: offset, length: mapped.length),
                                sourceRange: NSRange(location: fragment.sourceRange.location, length: mapped.length),
                                kind: .text(blockIndex: fragment.blockIndex)))
                        joined.append((fragment.attributedText.string as NSString).substring(with: mapped))
                    }
                }
                let map = ReaderTextSourceMap(spans: spans)
                text = joined
                sourceRange = map.sourceRange
                sourceMap = map
                return
            }
            guard let start = Self.mappedSourceRange(in: fragments[first], visibleBounds: visibleBounds),
                let end = Self.mappedSourceRange(in: fragments[last], visibleBounds: visibleBounds)
            else { return nil }
            let range = NSRange(location: start.location, length: end.upperBound - start.location)
            let joined = NSMutableString(capacity: range.length)
            for fragment in fragments[first...last] {
                let mapped = ReaderTextSelectionGeometry.mappedTextRange(in: fragment)
                joined.append((fragment.attributedText.string as NSString).substring(with: mapped))
            }
            // Adjacency gives an exact, one-to-one chapter UTF-16 mapping: no inserted
            // soft-wrap separators, trimmed whitespace or reconstructed source gaps.
            guard joined.length == range.length else { return nil }
            text = joined
            sourceRange = range
            sourceMap = nil
        }

        fileprivate init(fragment: ReaderTextLayoutFragment) {
            if let map = fragment.sourceMap {
                text = fragment.attributedText.string as NSString
                sourceRange = map.sourceRange
                sourceMap = map
                return
            }
            let mapped = ReaderTextSelectionGeometry.mappedTextRange(in: fragment)
            text = (fragment.attributedText.string as NSString).substring(with: mapped) as NSString
            sourceRange = NSRange(location: fragment.sourceRange.location, length: mapped.length)
            sourceMap = nil
        }

        fileprivate func wordRange(containing sourceHit: NSRange) -> (range: NSRange, word: String)? {
            guard ReaderTextSelectionGeometry.isValidSelectionRange(sourceRange),
                ReaderTextSelectionGeometry.isValidSelectionRange(sourceHit),
                NSIntersectionRange(sourceRange, sourceHit) == sourceHit
            else { return nil }
            let hit: NSRange
            let textBounds: NSRange
            if let sourceMap {
                guard let displayHit = sourceMap.selectionDisplayRanges(in: text as String, sourceRange: sourceHit).first,
                    sourceMap.sourceRange(forDisplayRange: displayHit) == sourceHit,
                    let run = sourceMap.textRange(containingDisplayRange: displayHit)
                else { return nil }
                hit = displayHit
                textBounds = NSIntersectionRange(run, NSRange(location: 0, length: text.length))
            } else {
                hit = NSRange(location: sourceHit.location - sourceRange.location, length: sourceHit.length)
                textBounds = NSRange(location: 0, length: text.length)
            }
            // A hard break is a tokenizer boundary even if legacy fragment metadata
            // labels both sides as continuations. The original characters stay intact.
            let before = text.rangeOfCharacter(
                from: .newlines, options: .backwards,
                range: NSRange(location: textBounds.location, length: hit.location - textBounds.location))
            let after = text.rangeOfCharacter(
                from: .newlines, options: [], range: NSRange(location: hit.upperBound, length: textBounds.upperBound - hit.upperBound))
            let start = before.location == NSNotFound ? textBounds.location : before.upperBound
            let end = after.location == NSNotFound ? textBounds.upperBound : after.location
            let paragraph = NSRange(location: start, length: end - start)
            var selected = NSIntersectionRange(text.rangeOfComposedCharacterSequences(for: hit), paragraph)
            if let tokenizer = CFStringTokenizerCreate(
                nil, text as CFString, CFRange(location: paragraph.location, length: paragraph.length),
                kCFStringTokenizerUnitWordBoundary, nil
            ), CFStringTokenizerGoToTokenAtIndex(tokenizer, hit.location) != CFStringTokenizerTokenType() {
                let token = CFStringTokenizerGetCurrentTokenRange(tokenizer)
                if token.location >= 0, token.location < text.length, token.length > 0 {
                    let boundedToken = NSRange(location: token.location, length: min(token.length, text.length - token.location))
                    let candidate = NSIntersectionRange(text.rangeOfComposedCharacterSequences(for: boundedToken), paragraph)
                    // Keep punctuation hits local if the tokenizer returns a neighbour;
                    // composed-character expansion also preserves emoji/ZWJ sequences.
                    if NSIntersectionRange(candidate, hit) == hit { selected = candidate }
                }
            }
            guard NSIntersectionRange(selected, hit) == hit else { return nil }
            if let sourceMap {
                guard let source = sourceMap.sourceRange(forDisplayRange: selected) else { return nil }
                return (source, sourceMap.selectedText(in: text as String, sourceRange: source))
            }
            return (
                NSRange(location: sourceRange.location + selected.location, length: selected.length),
                text.substring(with: selected)
            )
        }

        private static func mappedSourceRange(in fragment: ReaderTextLayoutFragment, visibleBounds: CGRect) -> NSRange? {
            if let map = fragment.sourceMap {
                guard fragment.frame.intersects(visibleBounds),
                    map.sourceRange(forDisplayRange: NSRange(location: 0, length: fragment.attributedText.length)) != nil
                else { return nil }
                return map.sourceRange
            }
            let mapped = ReaderTextSelectionGeometry.mappedTextRange(in: fragment)
            guard mapped.length > 0, fragment.frame.intersects(visibleBounds) else { return nil }
            return NSRange(location: fragment.sourceRange.location, length: mapped.length)
        }

        private static func canJoin(
            _ previous: ReaderTextLayoutFragment, _ next: ReaderTextLayoutFragment,
            attachments: [ReaderAttachmentLayoutFragment], visibleBounds: CGRect
        ) -> Bool {
            if previous.sourceMap != nil || next.sourceMap != nil {
                guard previous.kind == next.kind, next.isContinuation,
                    let start = mappedSourceRange(in: previous, visibleBounds: visibleBounds),
                    let end = mappedSourceRange(in: next, visibleBounds: visibleBounds), start.upperBound == end.location
                else { return false }
                // Inline images are token boundaries inside the map, not a reason to
                // discard all soft-wrap context on both sides of the image.
                return !attachments.contains { attachment in
                    guard case .remoteImage = attachment.source else { return false }
                    let image = attachment.sourceRange
                    return image.length == 0 && image.location == end.location
                }
            }
            guard previous.blockIndex == next.blockIndex, previous.kind == next.kind, next.isContinuation,
                let start = mappedSourceRange(in: previous, visibleBounds: visibleBounds),
                let end = mappedSourceRange(in: next, visibleBounds: visibleBounds), start.upperBound == end.location
            else { return false }
            let previousText = (previous.attributedText.string as NSString).substring(
                with: ReaderTextSelectionGeometry.mappedTextRange(in: previous))
            let nextText = (next.attributedText.string as NSString).substring(
                with: ReaderTextSelectionGeometry.mappedTextRange(in: next))
            guard previousText.last?.isNewline != true, nextText.first?.isNewline != true else { return false }
            let span = NSRange(location: start.location, length: end.upperBound - start.location)
            return !attachments.contains { attachment in
                guard case .remoteImage = attachment.source else { return false }
                let imageRange = attachment.sourceRange
                if ReaderTextSelectionGeometry.isValidSelectionRange(imageRange), NSIntersectionRange(imageRange, span).length > 0 {
                    return true
                }
                return (imageRange.length == 0 && imageRange.location == end.location)
                    || attachment.frame.intersects(previous.frame.union(next.frame))
            }
        }
    }

    private struct CharacterCell {
        let range: NSRange
        let sourceRange: NSRange
        let rect: CGRect
        let startCaret: CGRect?
        let endCaret: CGRect?
    }

    private struct LineGeometry {
        let cells: [CharacterCell]
        let excludedRects: [CGRect]
    }

    private struct CaretSpan {
        let range: NSRange
        var minX: CGFloat
        var maxX: CGFloat
        var leading: (index: Int, x: CGFloat)?
        var trailing: (index: Int, x: CGFloat)?
    }

    private let fragment: ReaderTextLayoutFragment
    private let lines: [LineGeometry]

    init(fragment: ReaderTextLayoutFragment) {
        self.fragment = fragment
        let mappedRange = Self.mappedTextRange(in: fragment)
        let frame = Self.makeFrame(for: fragment.attributedText, size: fragment.frame.size)
        let frameLines = CTFrameGetLines(frame) as? [CTLine] ?? []
        var origins = [CGPoint](repeating: .zero, count: frameLines.count)
        if frameLines.isEmpty == false {
            CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        }
        let pathOrigin = CTFrameGetPath(frame).boundingBoxOfPath.origin
        lines = zip(frameLines, origins).map { line, origin in
            Self.lineGeometry(
                line, origin: CGPoint(x: origin.x + pathOrigin.x, y: origin.y + pathOrigin.y),
                fragment: fragment, mappedRange: mappedRange)
        }
    }

    // Drawing and selection must use the same framesetter, path and text range.
    static func makeFrame(for text: NSAttributedString, size: CGSize) -> CTFrame {
        let framesetter = CTFramesetterCreateWithAttributedString(text as CFAttributedString)
        let path = CGPath(rect: CGRect(origin: .zero, size: size), transform: nil)
        let range = CFRange(location: 0, length: text.length)
        let frame = CTFramesetterCreateFrame(framesetter, range, path, nil)
        guard text.length > 0, size.width > 0, size.height > 0, CFArrayGetCount(CTFrameGetLines(frame)) == 0 else {
            return frame
        }
        let measured = ceil(
            CTFramesetterSuggestFrameSizeWithConstraints(
                framesetter, range, nil, CGSize(width: size.width, height: CGFloat.greatestFiniteMagnitude), nil
            ).height)
        guard measured.isFinite, measured > size.height else { return frame }
        // Android advances by lineSpacingExtra but still paints the complete glyph.
        // Extend below the logical row without changing its top or pagination stride.
        let extendedPath = CGPath(
            rect: CGRect(x: 0, y: size.height - measured, width: size.width, height: measured), transform: nil)
        return CTFramesetterCreateFrame(framesetter, range, extendedPath, nil)
    }

    func wordRange(at point: CGPoint, context: WordContext? = nil) -> (range: NSRange, word: String)? {
        // Caret cells identify the character under the finger, not the nearest
        // insertion index (which can belong to the next word or the line end).
        let hits = lines.compactMap { line in
            line.cells.first { $0.rect.contains(point) }
        }
        guard
            let hit = hits.min(by: {
                abs($0.rect.midY - point.y) < abs($1.rect.midY - point.y)
            })
        else { return nil }

        let sourceHit = hit.sourceRange
        return context?.wordRange(containing: sourceHit)
            ?? WordContext(fragment: fragment).wordRange(containing: sourceHit)
    }

    /// Rough selection clamps x only within a real text row, never across blank rows.
    func characterRange(at point: CGPoint) -> NSRange? {
        selectionHit(at: point)?.range
    }

    /// touchRough's before/after-row positions are insertion edges, not extra selected characters.
    func selectionHit(at point: CGPoint) -> Hit? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        let hits = lines.compactMap { line -> (cell: CharacterCell, isCharacter: Bool)? in
            guard !line.excludedRects.contains(where: { $0.contains(point) }) else { return nil }
            guard let first = line.cells.first, let last = line.cells.last else { return nil }
            if fragment.sourceMap != nil {
                guard line.cells.contains(where: { point.y >= $0.rect.minY && point.y < $0.rect.maxY }) else { return nil }
            } else {
                guard point.y >= first.rect.minY, point.y < first.rect.maxY else { return nil }
            }
            if let hit = line.cells.first(where: { $0.rect.contains(point) }) { return (hit, true) }
            if point.x <= first.rect.minX { return (first, false) }
            if point.x >= last.rect.maxX { return (last, false) }
            return nil
        }
        guard
            let hit = hits.min(by: {
                abs($0.cell.rect.midY - point.y) < abs($1.cell.rect.midY - point.y)
            })
        else { return nil }
        let range = hit.cell.sourceRange
        if hit.isCharacter {
            return Hit(
                range: range, startBoundary: range.location, endBoundary: range.upperBound, isCharacter: true,
                startCaret: hit.cell.startCaret, endCaret: hit.cell.endCaret)
        }
        let boundary: Int
        if let start = hit.cell.startCaret, let end = hit.cell.endCaret {
            // Use logical caret edges for RTL/bidi instead of assuming visual left means source start.
            boundary = abs(point.x - start.minX) <= abs(point.x - end.minX) ? range.location : range.upperBound
        } else {
            boundary = point.x <= hit.cell.rect.minX ? range.location : range.upperBound
        }
        let caret = boundary == range.location ? hit.cell.startCaret : hit.cell.endCaret
        return Hit(
            range: range, startBoundary: boundary, endBoundary: boundary, isCharacter: false,
            startCaret: caret, endCaret: caret)
    }

    var selectionCharacterRanges: [NSRange] {
        let ranges = lines.flatMap(\.cells).map(\.sourceRange)
        return Array(Set(ranges)).sorted { $0.location < $1.location }
    }

    /// The endpoints follow source order, not the visual bounding box of bidi text.
    func selectionEndpoints(for sourceRange: NSRange) -> (start: CGRect, end: CGRect)? {
        if fragment.sourceMap != nil {
            guard Self.isValidSelectionRange(sourceRange) else { return nil }
            let cells = lines.flatMap(\.cells).filter { NSIntersectionRange($0.sourceRange, sourceRange).length > 0 }
            guard let first = cells.min(by: { $0.sourceRange.location < $1.sourceRange.location }),
                let last = cells.max(by: { $0.sourceRange.upperBound < $1.sourceRange.upperBound }),
                let start = first.startCaret, let end = last.endCaret
            else { return nil }
            return (start, end)
        }
        guard Self.isValidSelectionRange(sourceRange),
            let localRange = Self.localSelectionRange(for: sourceRange, in: fragment)
        else { return nil }
        let cells = lines.flatMap(\.cells).filter { NSIntersectionRange($0.range, localRange).length > 0 }
        guard let first = cells.min(by: { $0.range.location < $1.range.location }),
            let last = cells.max(by: { $0.range.upperBound < $1.range.upperBound }),
            let start = first.startCaret, let end = last.endCaret
        else { return nil }
        return (start, end)
    }

    func selectionRects(for sourceRange: NSRange) -> [CGRect] {
        let localRange: NSRange?
        if fragment.sourceMap != nil {
            guard Self.isValidSelectionRange(sourceRange) else { return [] }
            localRange = nil
        } else {
            guard let range = Self.localSelectionRange(for: sourceRange, in: fragment) else { return [] }
            localRange = range
        }
        var result: [CGRect] = []
        for line in lines {
            var row: [CGRect] = []
            for cell in line.cells {
                let selected =
                    localRange.map { NSIntersectionRange(cell.range, $0).length > 0 }
                    ?? (NSIntersectionRange(cell.sourceRange, sourceRange).length > 0)
                guard selected else { continue }
                if let last = row.last, cell.rect.minX <= last.maxX + 0.001 {
                    row[row.count - 1] = last.union(cell.rect)
                } else {
                    row.append(cell.rect)
                }
            }
            result.append(contentsOf: row)
        }
        return result
    }

    static func localSelectionRange(for sourceRange: NSRange, in fragment: ReaderTextLayoutFragment) -> NSRange? {
        if fragment.sourceMap != nil {
            let ranges = localSelectionRanges(for: sourceRange, in: fragment)
            guard let first = ranges.first, let last = ranges.last else { return nil }
            // Legacy callers only use this as an overlap check. Disjoint ranges
            // must use localSelectionRanges, never copy or highlight this hull.
            return NSRange(location: first.location, length: last.upperBound - first.location)
        }
        guard sourceRange.location >= 0, sourceRange.location != NSNotFound, sourceRange.length > 0 else { return nil }
        let mappedRange = mappedTextRange(in: fragment)
        guard mappedRange.length > 0 else { return nil }
        let sourceStart = fragment.sourceRange.location
        let requestedEnd = sourceRange.location + min(sourceRange.length, Int.max - sourceRange.location)
        let start = max(sourceRange.location, sourceStart)
        let end = min(requestedEnd, sourceStart + mappedRange.length)
        guard end > start else { return nil }
        let localRange = NSRange(location: start - sourceStart, length: end - start)
        let text = fragment.attributedText.string as NSString
        return NSIntersectionRange(text.rangeOfComposedCharacterSequences(for: localRange), mappedRange)
    }

    static func localSelectionRanges(for sourceRange: NSRange, in fragment: ReaderTextLayoutFragment) -> [NSRange] {
        if let map = fragment.sourceMap {
            return map.selectionDisplayRanges(in: fragment.attributedText.string, sourceRange: sourceRange)
        }
        return localSelectionRange(for: sourceRange, in: fragment).map { [$0] } ?? []
    }

    static func isValidSelectionRange(_ range: NSRange) -> Bool {
        range.location >= 0 && range.location != NSNotFound && range.length > 0
            && range.length <= Int.max - range.location
    }

    private static func mappedTextRange(in fragment: ReaderTextLayoutFragment) -> NSRange {
        if fragment.sourceMap != nil { return NSRange(location: 0, length: fragment.attributedText.length) }
        let sourceRange = fragment.sourceRange
        guard sourceRange.location >= 0, sourceRange.location != NSNotFound, sourceRange.length > 0 else {
            return NSRange(location: 0, length: 0)
        }
        let text = fragment.attributedText.string as NSString
        var length = min(text.length, sourceRange.length, Int.max - sourceRange.location)
        if length > 0, length < text.length {
            let lastCharacter = text.rangeOfComposedCharacterSequence(at: length - 1)
            if lastCharacter.upperBound > length {
                length = lastCharacter.location
            }
        }
        return NSRange(location: 0, length: length)
    }

    private static func lineGeometry(
        _ line: CTLine,
        origin: CGPoint,
        fragment: ReaderTextLayoutFragment,
        mappedRange: NSRange
    ) -> LineGeometry {
        let text = fragment.attributedText.string as NSString
        let lineRange = CTLineGetStringRange(line)
        guard lineRange.location >= 0, lineRange.location < mappedRange.length, lineRange.length > 0 else {
            return LineGeometry(cells: [], excludedRects: [])
        }
        let lineEnd = lineRange.location + min(lineRange.length, mappedRange.length - lineRange.location)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        let baseline = fragment.frame.maxY - origin.y
        let top = baseline - ascent
        let height = ascent + descent
        guard origin.x.isFinite, top.isFinite, height.isFinite, height > 0 else {
            return LineGeometry(cells: [], excludedRects: [])
        }

        // Logical leading/trailing caret edges disambiguate bidi boundaries and
        // ligatures. Combine UTF-16 indices into whole composed characters.
        var spans: [Int: CaretSpan] = [:]
        CTLineEnumerateCaretOffsets(line) { offset, index, leadingEdge, _ in
            guard offset.isFinite, index >= lineRange.location, index < lineEnd else { return }
            let range = text.rangeOfComposedCharacterSequence(at: index)
            guard range.location >= lineRange.location, range.upperBound <= lineEnd else { return }
            let x = CGFloat(offset)
            var span = spans[range.location] ?? CaretSpan(range: range, minX: x, maxX: x)
            span.minX = min(span.minX, x)
            span.maxX = max(span.maxX, x)
            if leadingEdge {
                if index < (span.leading?.index ?? Int.max) {
                    span.leading = (index, x)
                }
            } else if index > (span.trailing?.index ?? -1) {
                span.trailing = (index, x)
            }
            spans[range.location] = span
        }

        var excludedRects: [CGRect] = []
        let textRuns: [(range: NSRange, ascent: CGFloat, descent: CGFloat)]
        if let map = fragment.sourceMap {
            let textRanges = map.displayRanges(forSourceRange: map.sourceRange)
            textRuns = (CTLineGetGlyphRuns(line) as? [CTRun] ?? []).compactMap { run in
                let range = CTRunGetStringRange(run)
                guard range.location >= 0, range.length > 0,
                    textRanges.contains(where: {
                        NSIntersectionRange($0, NSRange(location: range.location, length: range.length)).length > 0
                    })
                else { return nil }
                var runAscent: CGFloat = 0
                var runDescent: CGFloat = 0
                CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), &runAscent, &runDescent, nil)
                return (NSRange(location: range.location, length: range.length), runAscent, runDescent)
            }
        } else {
            textRuns = []
        }
        let cells = spans.values.compactMap { span -> CharacterCell? in
            let source: NSRange
            if let map = fragment.sourceMap {
                guard map.textRange(containingDisplayRange: span.range) != nil,
                    let range = map.sourceRange(forDisplayRange: span.range), range.length == span.range.length
                else {
                    excludedRects.append(
                        CGRect(
                            x: fragment.frame.minX + origin.x + span.minX, y: top,
                            width: span.maxX - span.minX, height: height))
                    return nil
                }
                source = range
            } else {
                source = NSRange(location: fragment.sourceRange.location + span.range.location, length: span.range.length)
            }
            let string = text.substring(with: span.range)
            // Newlines and zero-width controls have no selection area. Spaces
            // are selectable TextColumns on Android and retain their advance.
            guard span.maxX > span.minX,
                string.unicodeScalars.contains(where: {
                    CharacterSet.newlines.contains($0) == false
                        && (CharacterSet.controlCharacters.contains($0) == false
                            || CharacterSet.whitespaces.contains($0))
                })
            else { return nil }
            let metrics = textRuns.filter { NSIntersectionRange($0.range, span.range).length > 0 }
            let cellAscent = metrics.map { $0.ascent }.max() ?? ascent
            let cellDescent = metrics.map { $0.descent }.max() ?? descent
            let cellTop = baseline - cellAscent
            let cellHeight = cellAscent + cellDescent
            guard cellTop.isFinite, cellHeight.isFinite, cellHeight > 0 else { return nil }
            let rect = CGRect(
                x: fragment.frame.minX + origin.x + span.minX,
                y: cellTop,
                width: span.maxX - span.minX,
                height: cellHeight
            )
            func caret(at x: CGFloat) -> CGRect {
                CGRect(x: fragment.frame.minX + origin.x + x, y: cellTop, width: 0, height: cellHeight)
            }
            return CharacterCell(
                range: span.range, sourceRange: source, rect: rect,
                startCaret: span.leading.map { caret(at: $0.x) },
                endCaret: span.trailing.map { caret(at: $0.x) }
            )
        }.sorted { $0.rect.minX < $1.rect.minX }
        return LineGeometry(cells: cells, excludedRects: excludedRects)
    }
}
