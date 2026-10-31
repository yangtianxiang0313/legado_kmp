import Foundation
import shared

enum ReaderSearchSelectionMapper {
    private struct IndexedText {
        var units: [UInt16] = []
        var positions: [Int] = []

        mutating func append(_ text: NSString, range: NSRange, sourceStart: Int) {
            var cursor = range.location
            while cursor < range.upperBound {
                let local = text.rangeOfComposedCharacterSequence(at: cursor)
                guard local.upperBound <= range.upperBound else { break }
                cursor = local.upperBound
                let substring = text.substring(with: local)
                if substring.unicodeScalars.allSatisfy(CharacterSet.whitespacesAndNewlines.contains) { continue }
                for (offset, unit) in substring.utf16.enumerated() {
                    units.append(unit)
                    positions.append(sourceStart + local.location + offset)
                }
            }
        }
    }

    // Search indexes processed body text; layout indexes include the visible title and
    // image placeholders, but omit trimmed paragraph whitespace and HTML markup.
    static func range(for result: ContentSearchResult, content: String, pages: [ReaderPageLayout]) -> NSRange? {
        guard let (original, rendered) = indexedTexts(content: content, pages: pages) else { return nil }
        let first: Int
        let length: Int
        if let fingerprint = result.searchTextFingerprint,
            let position = result.queryIndexInVisibleText?.intValue,
            let count = result.queryLengthInVisibleText?.intValue
        {
            // Different replacement options may trim indentation, but may not change actual words.
            guard fingerprint == original.fingerprint else { return nil }
            first = position
            length = count
        } else {
            let text = content as NSString
            let query = result.query as NSString
            let start = Int(result.queryIndexInChapter)
            guard start >= 0, start <= text.length, query.length > 0,
                query.length <= text.length - start,
                text.substring(with: NSRange(location: start, length: query.length)) == result.query,
                let range = original.visibleRange(sourceStart: Int32(start), sourceLength: Int32(query.length))
            else { return nil }
            first = Int(range.start)
            length = Int(range.length)
        }
        guard first >= 0, length > 0, first <= rendered.positions.count,
            length <= rendered.positions.count - first
        else { return nil }
        let normalizedQuery = Array(ReaderSearchTextIndex(content: result.query).normalizedText.utf16)
        guard normalizedQuery == Array(rendered.units[first..<(first + length)]) else { return nil }
        let last = first + length - 1
        let location = rendered.positions[first]
        return NSRange(location: location, length: rendered.positions[last] + 1 - location)
    }

    static func contentPosition(for sourcePosition: Int, content: String, pages: [ReaderPageLayout]) -> Int? {
        guard let (original, rendered) = indexedTexts(content: content, pages: pages),
            let first = rendered.positions.firstIndex(where: { $0 >= sourcePosition })
                ?? rendered.positions.indices.last
        else { return nil }
        return original.sourcePosition(visibleIndex: Int32(first))?.intValue
    }

    private static func indexedTexts(content: String, pages: [ReaderPageLayout]) -> (ReaderSearchTextIndex, IndexedText)? {
        let original = ReaderSearchTextIndex(content: content)
        var rendered = IndexedText()
        for page in pages {
            for fragment in page.textFragments where fragment.kind == .paragraph {
                let text = fragment.attributedText.string as NSString
                let length = min(text.length, fragment.sourceRange.length)
                guard fragment.sourceRange.location >= 0, length > 0 else { continue }
                rendered.append(
                    text, range: NSRange(location: 0, length: length), sourceStart: fragment.sourceRange.location)
            }
        }

        // Preserve occurrence identity rather than guessing a nearby duplicate match.
        // Stale or differently processed results must never select unrelated words.
        return Array(original.normalizedText.utf16) == rendered.units ? (original, rendered) : nil
    }
}
