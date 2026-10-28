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
        let content = content as NSString
        let query = result.query as NSString
        let start = Int(result.queryIndexInChapter)
        guard start >= 0, start <= content.length, query.length > 0,
            query.length <= content.length - start
        else { return nil }
        let requested = NSRange(location: start, length: query.length)
        guard content.substring(with: requested) == result.query else { return nil }

        guard let (original, rendered) = indexedTexts(content: content, pages: pages),
            let first = original.positions.firstIndex(where: { $0 >= requested.location }),
            let last = original.positions.lastIndex(where: { $0 < requested.upperBound }),
            first <= last
        else { return nil }
        let location = rendered.positions[first]
        return NSRange(location: location, length: rendered.positions[last] + 1 - location)
    }

    static func contentPosition(for sourcePosition: Int, content: String, pages: [ReaderPageLayout]) -> Int? {
        guard let (original, rendered) = indexedTexts(content: content as NSString, pages: pages),
            let first = rendered.positions.firstIndex(where: { $0 >= sourcePosition })
                ?? rendered.positions.indices.last
        else { return nil }
        return original.positions[first]
    }

    private static func indexedTexts(content: NSString, pages: [ReaderPageLayout]) -> (IndexedText, IndexedText)? {

        var original = IndexedText()
        let tags = try? NSRegularExpression(pattern: "<[^>]+>")
        var cursor = 0
        for tag in tags?.matches(in: content as String, range: NSRange(location: 0, length: content.length)) ?? [] {
            original.append(
                content, range: NSRange(location: cursor, length: tag.range.location - cursor), sourceStart: 0)
            cursor = tag.range.upperBound
        }
        original.append(content, range: NSRange(location: cursor, length: content.length - cursor), sourceStart: 0)

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
        return original.units == rendered.units ? (original, rendered) : nil
    }
}
