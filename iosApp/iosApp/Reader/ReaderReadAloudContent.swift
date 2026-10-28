import Foundation
import shared

struct ReaderReadAloudContent {
    struct Position {
        let blockIndex: Int
        let textOffset: Int
    }

    private struct FragmentPage {
        let textRange: Range<Int>
        let pageIndex: Int
    }

    let blocks: [ReaderContentBlock]
    private let startPositions: [Position?]
    private let fragmentsByBlock: [Int: [FragmentPage]]

    init(pages: [ReaderPageLayout]) {
        var orderedBlockIndexes: [Int] = []
        var textByBlock: [Int: String] = [:]
        var typeByBlock: [Int: ReaderContentBlockType] = [:]
        var startPositions = [Position?](repeating: nil, count: pages.count)
        var fragmentsByBlock: [Int: [FragmentPage]] = [:]

        for (pageIndex, page) in pages.enumerated() {
            for fragment in page.textFragments {
                let blockIndex = fragment.blockIndex
                if typeByBlock[blockIndex] == nil {
                    orderedBlockIndexes.append(blockIndex)
                    typeByBlock[blockIndex] = fragment.kind == .heading ? .heading : .paragraph
                }
                let text = fragment.attributedText.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard text.isEmpty == false else { continue }

                let hasSeparator = textByBlock[blockIndex]?.isEmpty == false
                let previousEnd = fragmentsByBlock[blockIndex]?.last?.textRange.upperBound ?? 0
                let textOffset = previousEnd + (hasSeparator ? 1 : 0)
                textByBlock[blockIndex, default: ""].append(hasSeparator ? "\n\(text)" : text)
                fragmentsByBlock[blockIndex, default: []].append(
                    FragmentPage(textRange: textOffset..<(textOffset + text.utf16.count), pageIndex: pageIndex)
                )
                if startPositions[pageIndex] == nil {
                    startPositions[pageIndex] = Position(blockIndex: blockIndex, textOffset: textOffset)
                }
            }
        }

        blocks = orderedBlockIndexes.compactMap { index in
            guard let text = textByBlock[index], text.isEmpty == false else { return nil }
            return ReaderContentBlock(
                blockIndex: Int32(index),
                type: typeByBlock[index] ?? .paragraph,
                text: text,
                imageUrl: nil,
                imageAlt: nil,
                imageWidth: 0,
                imageHeight: 0
            )
        }
        self.startPositions = startPositions
        self.fragmentsByBlock = fragmentsByBlock
    }

    func startPosition(onPage pageIndex: Int) -> Position? {
        guard startPositions.indices.contains(pageIndex) else { return nil }
        return startPositions[pageIndex]
    }

    func pageIndex(blockIndex: Int, textOffset: Int) -> Int? {
        guard let fragments = fragmentsByBlock[blockIndex], fragments.isEmpty == false else { return nil }
        let offset = max(textOffset, 0)
        var lower = 0
        var upper = fragments.count - 1
        // Assign separator offsets to the next fragment and clamp past-end offsets to the last.
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if fragments[middle].textRange.upperBound <= offset {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return fragments[lower].pageIndex
    }
}
