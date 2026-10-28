import SQLite3
import shared

struct ReaderTocChapterState: Equatable {
    let currentChapterIndex: Int?
    let chapterCount: Int
    private let currentChapterTitle: String
    private let limitsChapterIndices: Bool

    init(items: [ReaderChapterListItem], book: Book?) {
        let index =
            book.map { Int($0.durChapterIndex) }
            ?? items.first(where: { $0.isCurrent }).map { Int($0.chapter.index) }
        currentChapterIndex = index
        let current = items.first(where: { Int($0.chapter.index) == index })
        let savedTitle = book?.durChapterTitle ?? ""
        currentChapterTitle =
            savedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? current?.displayTitle ?? "" : savedTitle
        limitsChapterIndices = book != nil
        if let book {
            let total = max(0, Int(book.totalChapterNum))
            if book.readConfig?.readSimulating == true, let facade = try? SharedRuntime.readerFacade().get() {
                chapterCount = Int(
                    facade.computeSimulatedChapterSize(readConfig: book.readConfig, realChapterSize: Int32(total)))
            } else {
                chapterCount = total
            }
        } else {
            chapterCount = items.count
        }
    }

    var currentChapterInfo: String {
        currentChapterIndex.map { "\(currentChapterTitle)(\($0 + 1)/\(chapterCount))" }
            ?? L10n.Reader.chapterCountText(chapterCount)
    }

    func visibleIndices(in items: [ReaderChapterListItem], query: String) -> [Int] {
        let indices = ReaderTocChapterPolicy.visibleIndices(in: items, query: query)
        guard limitsChapterIndices else { return indices }
        // ChapterListFragment applies the same simulated range to normal and searched rows.
        return indices.filter { (0..<chapterCount).contains(Int(items[$0].chapter.index)) }
    }

    func locateRow(visibleCount: Int) -> Int? {
        currentChapterIndex.flatMap {
            ReaderTocChapterPolicy.locateRow(currentChapterIndex: $0, visibleCount: visibleCount)
        }
    }
}

/// ChapterListFragment and BookChapterDao at Legado 5f5d314.
enum ReaderTocChapterPolicy {
    // BookChapter equality is URL-only; row presentation also depends on metadata and index.
    static func sameRow(_ lhs: ReaderChapterListItem, _ rhs: ReaderChapterListItem) -> Bool {
        let left = lhs.chapter
        let right = rhs.chapter
        return lhs.displayTitle == rhs.displayTitle && left.url == right.url && left.bookUrl == right.bookUrl
            && left.index == right.index && left.title == right.title && left.isVolume == right.isVolume
            && left.isVip == right.isVip && left.isPay == right.isPay && left.wordCount == right.wordCount
            && left.tag == right.tag
    }

    static func samePresentation(_ lhs: ReaderChapterListItem, _ rhs: ReaderChapterListItem) -> Bool {
        sameRow(lhs, rhs) && lhs.isCurrent == rhs.isCurrent && lhs.isCached == rhs.isCached
    }

    static func visibleIndices(in items: [ReaderChapterListItem], query: String) -> [Int] {
        let pattern = isBlank(query) ? nil : "%\(query)%"
        return items.indices.filter { index in
            guard let pattern else { return true }
            // LIKE has no ESCAPE clause: %/_ are wildcards, only ASCII case folds.
            return sqlite3_strlike(pattern, items[index].chapter.title, 0) == 0
        }.sorted { lhs, rhs in
            let left = items[lhs].chapter.index
            let right = items[rhs].chapter.index
            return left == right ? lhs < rhs : left < right
        }
    }

    static func initialScrollRow(in items: [ReaderChapterListItem], visibleIndices: [Int], currentChapterIndex: Int)
        -> Int?
    {
        guard !visibleIndices.isEmpty else { return nil }
        // onListChanged stops before the current chapter and retains the preceding row.
        return visibleIndices.lastIndex { Int(items[$0].chapter.index) < currentChapterIndex } ?? 0
    }

    static func locateRow(currentChapterIndex: Int, visibleCount: Int) -> Int? {
        // The footer passes durChapterIndex as an adapter position, without clearing search.
        (0..<visibleCount).contains(currentChapterIndex) ? currentChapterIndex : nil
    }

    private static func isBlank(_ text: String) -> Bool {
        // Kotlin/JVM isWhitespace = Character.isWhitespace || Character.isSpaceChar.
        // Swift's Unicode whitespace also includes U+0085 and omits U+001C...U+001F.
        text.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x0009...0x000D, 0x001C...0x0020, 0x00A0, 0x1680,
                0x2000...0x200A, 0x2028...0x2029, 0x202F, 0x205F, 0x3000:
                return true
            default:
                return false
            }
        }
    }
}
