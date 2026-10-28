import shared

extension ReaderFacade {
    func saveChapterContentCheckedAsync(
        bookUrl: String, chapterIndex: Int32, expectedChapterUrl: String, content: String
    ) async throws -> ReaderChapterPayload {
        try await SharedAsync.value { completion in
            saveChapterContentChecked(
                bookUrl: bookUrl, chapterIndex: chapterIndex, expectedChapterUrl: expectedChapterUrl,
                content: content, completionHandler: completion)
        }
    }

    func renameChapterTitleAsync(
        bookUrl: String, chapterIndex: Int32, expectedChapterUrl: String, title: String
    ) async throws -> ReaderChapterPayload {
        try await SharedAsync.value { completion in
            renameChapterTitle(
                bookUrl: bookUrl, chapterIndex: chapterIndex, expectedChapterUrl: expectedChapterUrl,
                title: title, completionHandler: completion)
        }
    }

    func resetChapterContentCheckedAsync(
        bookUrl: String, chapterIndex: Int32, expectedChapterUrl: String
    ) async throws -> ReaderChapterPayload {
        try await SharedAsync.value { completion in
            resetChapterContentChecked(
                bookUrl: bookUrl, chapterIndex: chapterIndex, expectedChapterUrl: expectedChapterUrl,
                completionHandler: completion)
        }
    }
}
