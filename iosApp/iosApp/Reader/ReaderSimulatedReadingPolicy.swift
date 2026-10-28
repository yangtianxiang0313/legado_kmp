import shared

@MainActor
enum ReaderSimulatedReadingPolicy {
    static let unavailableMessage = "模拟追读：当前尚无已解锁章节，可在菜单中调整模拟追读设置。"

    static func count(book: Book?, realCount: Int) -> Int {
        guard let book, book.config.readSimulating,
            let facade = try? SharedRuntime.readerFacade().get()
        else { return max(0, realCount) }
        return Int(
            facade.computeSimulatedChapterSize(readConfig: book.readConfig, realChapterSize: Int32(clamping: realCount))
        )
    }

    static func count(in reader: ReaderContainerViewController) -> Int {
        count(book: reader.book, realCount: reader.chapters.count)
    }

    static func save(_ request: ReaderSimulatedReadingRequest, bookURL: String, origin: String) async throws -> Book {
        let facade = try SharedRuntime.bookDetailFacade().get()
        return try await facade.updateReadSimulation(
            bookUrl: bookURL, expectedOrigin: origin, enabled: request.enabled,
            startDateIso: request.startDateIso, startChapter: request.startChapter, dailyChapters: request.dailyChapters
        )
    }
}
