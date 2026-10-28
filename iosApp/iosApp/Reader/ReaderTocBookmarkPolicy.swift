import SQLite3
import shared

enum ReaderTocBookmarkPolicy {
    static func visibleIndices(in bookmarks: [Bookmark], query: String) -> [Int] {
        let pattern = query.allSatisfy(\.isWhitespace) ? nil : "%\(query)%"
        return bookmarks.indices.filter { index in
            guard let pattern else { return true }
            let bookmark = bookmarks[index]
            // Match SQLite LIKE without ESCAPE; filter only the provider's current-book scope.
            return sqlite3_strlike(pattern, bookmark.chapterName, 0) == 0
                || sqlite3_strlike(pattern, bookmark.content, 0) == 0
        }.sorted { lhs, rhs in
            let leftChapter = bookmarks[lhs].chapterIndex
            let rightChapter = bookmarks[rhs].chapterIndex
            return leftChapter == rightChapter ? lhs < rhs : leftChapter < rightChapter
        }
    }

    static func initialScrollRow(in bookmarks: [Bookmark], visibleIndices: [Int], currentChapterIndex: Int) -> Int? {
        guard !visibleIndices.isEmpty else { return nil }
        return visibleIndices.lastIndex { Int(bookmarks[$0].chapterIndex) < currentChapterIndex } ?? 0
    }

}
