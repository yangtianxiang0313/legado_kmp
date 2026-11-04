import CoreText
import UIKit
import shared

// CoreText objects remain operation-local; published rows contain only immutable drawing values.
struct ReaderInlineImageComposer {
    struct Image {
        let sourceRange: NSRange
        let url: URL
        let requestRule: String
        let altText: String?
        let frame: CGRect
    }

    struct Line {
        let text: NSAttributedString
        let sourceMap: ReaderTextSourceMap
        let images: [Image]
        let blockIndex: Int
        let isContinuation: Bool
        let endsParagraph: Bool
    }

    struct Paragraph {
        let lines: [Line]
        let searchableEnd: Int
    }

    private struct Source {
        let kind: ReaderPageFragmentKind
        var range: NSRange
        let imageRule: String?
        let imageAlt: String?
    }

    private struct PendingImage {
        let location: Int
        let source: Source
        let url: URL
        let rule: String
    }

    private let groups: [ReaderInlineImageParagraph]
    private let groupByBlock: [Int: Int]
    private let sources: [Int: Source]

    init?(layout: ReaderChapterLayout, isCancelled: () -> Bool) {
        guard !layout.inlineImageParagraphs.isEmpty, !isCancelled() else { return nil }
        var groupByBlock: [Int: Int] = [:]
        for (index, group) in layout.inlineImageParagraphs.enumerated() {
            for run in group.runs {
                guard !isCancelled() else { return nil }
                let block = Int(run.blockIndex)
                guard block >= 0 else { continue }
                guard groupByBlock.updateValue(index, forKey: block) == nil else { return nil }
            }
        }
        var sources: [Int: Source] = [:]
        for page in layout.pages {
            for fragment in page.fragments {
                guard !isCancelled() else { return nil }
                let block = Int(fragment.blockIndex)
                guard groupByBlock[block] != nil else { continue }
                let start = Int(fragment.chapterStartPosition)
                let end = Int(fragment.chapterEndPosition)
                guard start >= 0, end >= start else { return nil }
                if var source = sources[block] {
                    guard source.kind == fragment.kind, source.range.upperBound == start, fragment.isContinuation else { return nil }
                    source.range.length = end - source.range.location
                    sources[block] = source
                } else {
                    sources[block] = Source(
                        kind: fragment.kind, range: NSRange(location: start, length: end - start),
                        imageRule: fragment.imageUrl, imageAlt: fragment.imageAlt)
                }
            }
        }
        self.groups = layout.inlineImageParagraphs
        self.groupByBlock = groupByBlock
        self.sources = sources
    }

    func groupIndex(for blockIndex: Int) -> Int? { groupByBlock[blockIndex] }

    func compose(
        group index: Int,
        searchableText: NSString,
        searchableStart: Int,
        contentSize: CGSize,
        lineHeight: CGFloat,
        makeText: (String) -> NSAttributedString,
        adjustLine: (NSAttributedString, Bool, Bool) -> NSAttributedString,
        isCancelled: () -> Bool
    ) -> Paragraph? {
        guard groups.indices.contains(index), !isCancelled() else { return nil }
        let group = groups[index]
        guard let first = group.runs.first(where: { $0.blockIndex >= 0 }), let firstSource = sources[Int(first.blockIndex)] else {
            return nil
        }
        let attributed = NSMutableAttributedString(string: "")
        var spans: [ReaderTextSourceMap.Span] = []
        var images: [PendingImage] = []
        var searchable = searchableStart
        var anchor = firstSource.range.location

        func append(_ text: String, source: NSRange, kind: ReaderTextSourceMap.Kind) {
            guard !text.isEmpty else { return }
            let offset = attributed.length
            // Android reserves this glyph for images, escaping an identical literal in body text.
            let value = makeText(text.replacingOccurrences(of: "\u{25a9}", with: "\u{25a3}"))
            attributed.append(value)
            spans.append(.init(displayRange: NSRange(location: offset, length: value.length), sourceRange: source, kind: kind))
        }

        for run in group.runs {
            guard !isCancelled() else { return nil }
            let block = Int(run.blockIndex)
            if let displayText = run.displayText {
                if block < 0 {
                    append(displayText, source: NSRange(location: anchor, length: 0), kind: .spacing)
                    continue
                }
                guard let source = sources[block], source.kind == .paragraph,
                    source.range.location == anchor, source.range.length == Int(run.textLength),
                    searchable >= 0, searchable <= searchableText.length,
                    source.range.length <= searchableText.length - searchable
                else { return nil }
                let raw = displayText as NSString
                let textStart = Int(run.textStart)
                let textLength = Int(run.textLength)
                guard textStart >= 0, textLength > 0, textStart <= raw.length, textLength <= raw.length - textStart else { return nil }
                append(raw.substring(to: textStart), source: NSRange(location: anchor, length: 0), kind: .spacing)
                append(
                    searchableText.substring(with: NSRange(location: searchable, length: textLength)),
                    source: source.range, kind: .text(blockIndex: block))
                anchor = source.range.upperBound
                append(raw.substring(from: textStart + textLength), source: NSRange(location: anchor, length: 0), kind: .spacing)
                searchable += textLength + 1
            } else {
                guard let source = sources[block], source.kind == .image, source.range.location == anchor, source.range.length == 1,
                    let rule = source.imageRule,
                    let url = URL(string: rule)
                        ?? rule.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap({ URL(string: $0) })
                else { return nil }
                let marker = NSMutableAttributedString(attributedString: makeText("\u{25a9}"))
                guard marker.length == 1 else { return nil }
                marker.addAttributes(
                    [.foregroundColor: UIColor.clear, .strokeColor: UIColor.clear, .strokeWidth: 0, .underlineStyle: 0],
                    range: NSRange(location: 0, length: 1))
                let offset = attributed.length
                attributed.append(marker)
                spans.append(
                    .init(
                        displayRange: NSRange(location: offset, length: 1), sourceRange: source.range,
                        kind: .image(altText: source.imageAlt)))
                images.append(PendingImage(location: offset, source: source, url: url, rule: rule))
                anchor = source.range.upperBound
            }
        }
        guard !images.isEmpty, !isCancelled(),
            let ranges = ReaderVisualLineRanges.collect(
                for: attributed, contentSize: contentSize, isCancelled: isCancelled), !ranges.isEmpty
        else { return nil }
        let map = ReaderTextSourceMap(spans: spans)
        let text = attributed.string as NSString
        var result: [Line] = []
        var imageIndex = 0
        for range in ranges {
            guard !isCancelled() else { return nil }
            let paragraph = text.paragraphRange(for: NSRange(location: range.location, length: 0))
            let continuation = range.location > paragraph.location
            let endsParagraph =
                text.rangeOfCharacter(from: .newlines, options: [], range: range).location != NSNotFound || range.upperBound == text.length
            let line = adjustLine(attributed.attributedSubstring(from: range), continuation, endsParagraph)
            let lineMap = map.submap(in: range)
            var attachments: [Image] = []
            while imageIndex < images.count, images[imageIndex].location < range.upperBound {
                guard !isCancelled() else { return nil }
                let image = images[imageIndex]
                guard image.location >= range.location,
                    let frame = ReaderInlineImageGeometry.columnFrame(
                        at: image.location - range.location, text: line, contentSize: contentSize, lineHeight: lineHeight)
                else { return nil }
                attachments.append(
                    Image(
                        sourceRange: image.source.range, url: image.url, requestRule: image.rule, altText: image.source.imageAlt,
                        frame: frame))
                imageIndex += 1
            }
            result.append(
                Line(
                    text: line, sourceMap: lineMap, images: attachments, blockIndex: Int(first.blockIndex), isContinuation: continuation,
                    endsParagraph: endsParagraph))
        }
        guard imageIndex == images.count, !isCancelled() else { return nil }
        return Paragraph(lines: result, searchableEnd: searchable)
    }

}
