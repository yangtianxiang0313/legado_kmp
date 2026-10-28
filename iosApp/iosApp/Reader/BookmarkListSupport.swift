import UIKit
import shared

protocol BookmarkListDelegate: AnyObject {
    func bookmarkList(_ controller: BookmarkListViewController, didSelectChapterIndex index: Int, position: Int)
}

protocol ReaderBookmarkListProviding: AnyObject {
    func loadBookmarks() async throws -> [Bookmark]
    func watchBookmarks(onUpdate: @escaping ([Bookmark]) -> Void) -> FlowSubscription?
    func updateBookmark(_ bookmark: Bookmark) async throws
    func deleteBookmark(_ bookmark: Bookmark) async throws
}

extension ReaderBookmarkListProviding {
    func watchBookmarks(onUpdate _: @escaping ([Bookmark]) -> Void) -> FlowSubscription? { nil }
}

enum ReaderBookmarkListSortMode: Int, CaseIterable {
    case latest, earliest, chapterAscending, chapterDescending

    var title: String {
        switch self {
        case .latest: return L10n.Reader.bookmarkSortLatest
        case .earliest: return L10n.Reader.bookmarkSortEarliest
        case .chapterAscending: return L10n.Reader.bookmarkSortChapterAscending
        case .chapterDescending: return L10n.Reader.bookmarkSortChapterDescending
        }
    }

    func precedes(_ lhs: Bookmark, _ rhs: Bookmark) -> Bool {
        switch self {
        case .latest: return lhs.time > rhs.time
        case .earliest: return lhs.time < rhs.time
        case .chapterAscending:
            if lhs.chapterIndex != rhs.chapterIndex { return lhs.chapterIndex < rhs.chapterIndex }
            return lhs.chapterPos < rhs.chapterPos
        case .chapterDescending:
            if lhs.chapterIndex != rhs.chapterIndex { return lhs.chapterIndex > rhs.chapterIndex }
            return lhs.chapterPos > rhs.chapterPos
        }
    }
}

enum ReaderBookmarkExport {
    // TocViewModel.saveBookmark/saveBookmarkMd at Legado 5f5d314 export all of this book,
    // not the currently filtered rows. Keep the standalone page's older format separate.
    static func androidJSON(_ bookmarks: [Bookmark]) throws -> String {
        let objects = bookmarks.map { bookmark -> [String: Any] in
            [
                "time": bookmark.time, "bookName": bookmark.bookName, "bookAuthor": bookmark.bookAuthor,
                "chapterIndex": bookmark.chapterIndex, "chapterPos": bookmark.chapterPos,
                "chapterName": bookmark.chapterName, "bookText": bookmark.bookText, "content": bookmark.content,
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    static func androidMarkdown(_ bookmarks: [Bookmark], bookName: String, bookAuthor: String) -> String {
        var text = "## \(bookName) \(bookAuthor)\n\n"
        for bookmark in bookmarks {
            text += "#### \(bookmark.chapterName)\n\n"
            text += "###### 原文\n \(bookmark.bookText)\n\n"
            text += "###### 摘要\n \(bookmark.content)\n\n"
        }
        return text
    }

    static func androidFileName(bookName: String, bookAuthor: String, markdown: Bool) -> String {
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        let stem = "\(bookName) \(bookAuthor)".unicodeScalars.map { forbidden.contains($0) ? "_" : String($0) }.joined()
        return "bookmark-\(stem).\(markdown ? "md" : "json")"
    }

    static func json(_ bookmarks: [Bookmark]) -> String? {
        let objects = bookmarks.map { bookmark -> [String: Any] in
            [
                "chapterName": bookmark.chapterName,
                "chapterIndex": bookmark.chapterIndex,
                "content": bookmark.content,
                "bookText": bookmark.bookText,
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func markdown(_ bookmarks: [Bookmark]) -> String {
        var text = "# \(L10n.Reader.bookmarkMarkdownTitle)\n\n"
        for bookmark in bookmarks {
            text += "## \(bookmark.chapterName)\n\n"
            let quote = bookmark.bookText.isEmpty ? bookmark.content : bookmark.bookText
            if !quote.isEmpty { text += "> \(quote)\n\n" }
        }
        return text
    }

    static func fileURL(text: String, fileName: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("legado-reader-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(fileName)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

extension BookmarkListViewController {
    func presentLoadError(_ error: Error) {
        showTransientMessage("\(L10n.Reader.bookmarkLoadFailed): \(error.userFacingMessage)")
    }

    func presentDeleteError(_ error: Error) {
        showTransientMessage("\(L10n.Reader.bookmarkDeleteFailed): \(error.userFacingMessage)")
    }

    func presentSaveError(_ error: Error) {
        showTransientMessage("\(L10n.Reader.bookmarkSaveFailed): \(error.userFacingMessage)")
    }
}

final class StandaloneReaderBookmarkListAdapter: ReaderBookmarkListProviding {
    private let bookURL: String

    init(bookURL: String) {
        self.bookURL = bookURL
    }

    func loadBookmarks() async throws -> [Bookmark] {
        let facade = try readerFacade()
        return try await facade.getBookmarksAsync(bookUrl: bookURL)
    }

    func watchBookmarks(onUpdate: @escaping ([Bookmark]) -> Void) -> FlowSubscription? {
        guard let facade = try? readerFacade() else { return nil }
        return facade.watchBookmarks(bookUrl: bookURL, onUpdate: onUpdate)
    }

    func updateBookmark(_ bookmark: Bookmark) async throws {
        let facade = try bookmarkFacade()
        try await facade.updateBookmark(bookmark: bookmark)
    }

    func deleteBookmark(_ bookmark: Bookmark) async throws {
        let facade = try readerFacade()
        try await facade.deleteBookmarkAsync(bookmarkTime: bookmark.time)
    }

    private func readerFacade() throws -> ReaderFacade {
        switch SharedRuntime.readerFacade() {
        case .success(let facade):
            return facade
        case .failure(let error):
            throw error
        }
    }

    private func bookmarkFacade() throws -> BookmarkFacade {
        switch SharedRuntime.bookmarkFacade() {
        case .success(let facade):
            return facade
        case .failure(let error):
            throw error
        }
    }
}
