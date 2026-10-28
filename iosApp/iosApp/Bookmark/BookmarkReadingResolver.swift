import Foundation
import PDFKit
import shared

@MainActor
enum BookmarkReadingResolver {
    static func resolve(_ bookmark: Bookmark) async throws -> Book {
        try Task.checkCancellation()
        let marks = try SharedRuntime.bookmarkFacade().get()
        let currentMarks = try await marks.getAllBookmarks()
        try Task.checkCancellation()
        guard let current = currentMarks.first(where: { $0.time == bookmark.time }), sameLocation(current, bookmark),
            current.chapterIndex >= 0, current.chapterPos >= 0
        else { throw failure("书签已变化或被删除，请刷新后重试") }

        let books = try await SharedRuntime.bookshelfFacade().get().searchBooks(query: current.bookName)
        try Task.checkCancellation()
        let matches = books.filter { $0.name == current.bookName && $0.author == current.bookAuthor }
        guard matches.count == 1, let book = matches.first else {
            throw failure(matches.isEmpty ? "原书籍已移除，请先从书架重新导入" : "存在同名同作者书籍，请从对应书架打开")
        }
        let chapters = try await SharedRuntime.readerFacade().get().loadChapterListState(bookUrl: book.bookUrl)
        try Task.checkCancellation()
        guard chapters.contains(where: { $0.chapter.index == current.chapterIndex && !$0.chapter.isVolume }) else {
            throw failure("书签对应的章节已不存在")
        }
        if book.isLocal, book.bookUrl.lowercased().hasSuffix(".pdf") {
            guard current.chapterPos == 0, !book.config.reverseToc else {
                throw failure("PDF 书签定位格式与当前目录不一致，请从原书重新定位")
            }
            guard
                chapters.contains(where: {
                    $0.chapter.index == current.chapterIndex && $0.chapter.url == "pdf-page-\(Int(current.chapterIndex) + 1)"
                })
            else { throw failure("PDF 页码与已保存目录不一致，请先重新打开原书") }
            let facade = try PdfReaderDocumentFacade.companion.create()
            let resolved: PdfReaderDocument = try await SharedAsync.value {
                facade.resolve(bookUrl: book.bookUrl, completionHandler: $0)
            }
            let fileURL = URL(fileURLWithPath: resolved.filePath)
            let count = await Task.detached(priority: .userInitiated) {
                guard let document = PDFDocument(url: fileURL), !document.isLocked else { return 0 }
                return document.pageCount
            }.value
            try Task.checkCancellation()
            guard (0..<count).contains(Int(current.chapterIndex)) else { throw failure("书签对应的 PDF 页面已不存在") }
        }
        let details = try SharedRuntime.bookDetailFacade().get()
        let persisted: Book? = try await SharedAsync.optionalValue {
            details.resolvePersistedBook(bookUrl: book.bookUrl, completionHandler: $0)
        }
        let latest = try await marks.getAllBookmarks().first { $0.time == current.time }
        try Task.checkCancellation()
        guard let persisted, persisted.bookUrl == book.bookUrl, persisted.origin == book.origin,
            persisted.name == current.bookName, persisted.author == current.bookAuthor,
            let latest, sameLocation(latest, current)
        else { throw failure("书籍或书签已变化，请刷新后重试") }
        return persisted
    }

    private static func sameLocation(_ left: Bookmark, _ right: Bookmark) -> Bool {
        left.time == right.time && left.bookName == right.bookName && left.bookAuthor == right.bookAuthor
            && left.chapterIndex == right.chapterIndex && left.chapterPos == right.chapterPos
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "io.legado.bookmark.reading", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
