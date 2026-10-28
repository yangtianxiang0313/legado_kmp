import Foundation
import shared

struct AudioChapterListSnapshot {
    let book: Book
    let items: [ReaderChapterListItem]
    let identity: UUID
}

final class AudioPlayScreenAdapter {
    private var facade: AudioPlayFacade?

    func bootstrap() -> Result<Void, SharedRuntimeError> {
        switch SharedRuntime.audioPlayFacade() {
        case .success(let facade):
            self.facade = facade
            return .success(())
        case .failure(let error):
            return .failure(error)
        }
    }

    func loadBook(bookUrl: String) async throws -> Book {
        guard let facade else { throw unavailableError() }
        return try await facade.loadBook(bookUrl: bookUrl)
    }

    func getChapters(bookUrl: String) async throws -> [BookChapter] {
        guard let facade else { throw unavailableError() }
        return try await facade.getChapters(bookUrl: bookUrl)
    }

    func loadCatalogSnapshot(bookURL: String, origin: String, identity: UUID) async throws -> AudioChapterListSnapshot {
        _ = try await loadCatalogBook(bookURL: bookURL, origin: origin)
        let items = try await SharedRuntime.readerFacade().get().loadChapterListStateAsync(bookUrl: bookURL)
        try Task.checkCancellation()
        let chapters = try await getChapters(bookUrl: bookURL)
        try Task.checkCancellation()
        let book = try await loadCatalogBook(bookURL: bookURL, origin: origin)
        guard items.allSatisfy({ $0.chapter.bookUrl == bookURL }),
            sameCatalogAddresses(items.map(\.chapter), chapters)
        else {
            throw catalogError("目录已变化，请重新打开")
        }
        return AudioChapterListSnapshot(book: book, items: items, identity: identity)
    }

    func loadPlaybackCatalog(bookURL: String, origin: String) async throws -> (book: Book, chapters: [BookChapter]) {
        _ = try await loadCatalogBook(bookURL: bookURL, origin: origin)
        let chapters = try await getChapters(bookUrl: bookURL)
        try Task.checkCancellation()
        let book = try await loadCatalogBook(bookURL: bookURL, origin: origin)
        guard chapters.allSatisfy({ $0.bookUrl == bookURL }) else {
            throw catalogError("目录已变化，请重新打开")
        }
        return (book, chapters)
    }

    private func loadCatalogBook(bookURL: String, origin: String) async throws -> Book {
        let facade = try SharedRuntime.bookDetailFacade().get()
        let book: Book? = try await SharedAsync.optionalValue { completion in
            facade.resolvePersistedBook(bookUrl: bookURL, completionHandler: completion)
        }
        try Task.checkCancellation()
        guard let book, book.bookUrl == bookURL, book.origin == origin else {
            throw catalogError("书籍或书源已变化，请重新打开目录")
        }
        return book
    }

    func catalogChapter(index: Int, book: Book, chapters: [BookChapter]) throws -> BookChapter {
        let count = Int(
            computeSimulatedChapterSize(readConfig: book.readConfig, realChapterSize: Int32(clamping: chapters.count)))
        guard index >= 0, index < count else { throw catalogError("章节不存在或尚未解锁") }
        var actualIndex = index
        while actualIndex < count {
            guard let chapter = chapters.first(where: { Int($0.index) == actualIndex }), chapter.bookUrl == book.bookUrl else {
                throw catalogError("章节不存在，请重新打开目录")
            }
            if !chapter.isVolume {
                guard !chapter.url.isEmpty else { throw catalogError("章节地址不存在") }
                return chapter
            }
            actualIndex += 1
        }
        throw catalogError("没有可播放的章节")
    }

    func catalogBook(_ book: Book, chapterCount: Int, chapterIndex: Int, title: String?, position: Int) -> Book {
        book.doCopy(
            bookUrl: book.bookUrl, tocUrl: book.tocUrl, origin: book.origin, originName: book.originName,
            name: book.name, author: book.author, kind: book.kind, customTag: book.customTag,
            coverUrl: book.coverUrl, customCoverUrl: book.customCoverUrl, intro: book.intro,
            customIntro: book.customIntro, charset: book.charset, type: book.type, group: book.group,
            latestChapterTitle: book.latestChapterTitle, latestChapterTime: book.latestChapterTime,
            lastCheckTime: book.lastCheckTime, lastCheckCount: book.lastCheckCount,
            totalChapterNum: Int32(clamping: chapterCount), durChapterTitle: title,
            durChapterIndex: Int32(clamping: chapterIndex), durChapterPos: Int32(clamping: position),
            durChapterTime: book.durChapterTime, wordCount: book.wordCount, canUpdate: book.canUpdate,
            order: book.order, originOrder: book.originOrder, variable: book.variable,
            readConfig: book.readConfig, syncTime: book.syncTime)
    }

    func getAudioUrl(bookUrl: String, chapterIndex: Int32, chapterSize: Int32) async throws -> AudioUrlResult {
        guard let facade else { throw unavailableError() }
        return try await facade.getAudioUrl(bookUrl: bookUrl, chapterIndex: chapterIndex, chapterSize: chapterSize)
    }

    func preparePlaybackRequest(bookUrl: String, chapterIndex: Int32, chapterSize: Int32) async throws -> AudioPlaybackRequest {
        guard let facade else { throw unavailableError() }
        return try await facade.preparePlaybackRequest(bookUrl: bookUrl, chapterIndex: chapterIndex, chapterSize: chapterSize)
    }

    func loadPlayMode() async throws -> Int { Int(try await requiredFacade().getPlayMode()) }

    func savePlayMode(_ mode: Int) async throws {
        try await requiredFacade().savePlayMode(modeValue: Int32(clamping: mode))
    }

    func saveDuration(bookUrl: String, chapterIndex: Int, milliseconds: Int64) async throws {
        _ = try await requiredFacade().saveDurChapter(
            bookUrl: bookUrl, chapterIndex: Int32(clamping: chapterIndex), audioSize: milliseconds)
    }

    func saveDuration(bookURL: String, origin: String, chapterURL: String, milliseconds: Int64) async throws {
        let catalog = try await loadPlaybackCatalog(bookURL: bookURL, origin: origin)
        guard let chapter = uniqueChapter(url: chapterURL, in: catalog.chapters) else { return }
        try await saveDuration(bookUrl: bookURL, chapterIndex: Int(chapter.index), milliseconds: milliseconds)
    }

    func saveProgress(bookUrl: String, chapterIndex: Int32, chapterPos: Int32, previousChapterIndex: Int32) async throws {
        guard let facade else { throw unavailableError() }
        try await facade.saveProgress(
            bookUrl: bookUrl, chapterIndex: chapterIndex, chapterPos: chapterPos, previousChapterIndex: previousChapterIndex)
    }

    func saveProgress(bookURL: String, origin: String, chapterURL: String, position: Int32) async throws {
        let catalog = try await loadPlaybackCatalog(bookURL: bookURL, origin: origin)
        guard let chapter = uniqueChapter(url: chapterURL, in: catalog.chapters), !chapter.isVolume else { return }
        // The URL, not a retired directory index, owns this millisecond position.
        try await requiredFacade().saveProgress(
            bookUrl: bookURL, chapterIndex: chapter.index, chapterPos: position, previousChapterIndex: -1)
    }

    func sameCatalogAddresses(_ lhs: [BookChapter], _ rhs: [BookChapter]) -> Bool {
        guard lhs.count == rhs.count,
            Set(lhs.map(\.index)).count == lhs.count, Set(rhs.map(\.index)).count == rhs.count
        else { return false }
        let left = lhs.sorted { $0.index < $1.index }, right = rhs.sorted { $0.index < $1.index }
        return zip(left, right).allSatisfy { pair in
            pair.0.index == pair.1.index && pair.0.url == pair.1.url && pair.0.bookUrl == pair.1.bookUrl
        }
    }

    func uniqueChapter(url: String, in chapters: [BookChapter]) -> BookChapter? {
        guard !url.isEmpty else { return nil }
        let matches = chapters.filter { !$0.isVolume && $0.url == url }
        return matches.count == 1 ? matches.first : nil
    }

    func computeSimulatedChapterSize(readConfig: ReadConfig?, realChapterSize: Int32) -> Int32 {
        guard let facade, let readConfig else { return realChapterSize }
        return facade.computeSimulatedChapterSize(readConfig: readConfig, realChapterSize: realChapterSize)
    }

    func computePrevChapterIndex(currentIndex: Int32) -> Int32 {
        facade?.computePrevChapterIndex(currentIndex: currentIndex) ?? max(currentIndex - 1, 0)
    }

    func computeNextChapterIndex(currentIndex: Int32, totalChapters: Int32, modeValue: Int32) -> KotlinInt? {
        facade?.computeNextChapterIndex(currentIndex: currentIndex, totalChapters: totalChapters, modeValue: modeValue)
    }

    func validateChapterIndex(index: Int32, chapterSize: Int32) -> KotlinInt? {
        facade?.validateChapterIndex(index: index, chapterSize: chapterSize)
    }

    func adjustSpeed(currentSpeed: Float, delta: Float) -> Float {
        facade?.adjustSpeed(currentSpeed: currentSpeed, delta: delta) ?? min(max(currentSpeed + delta, 0.5), 3.0)
    }

    private func unavailableError() -> NSError {
        NSError(domain: "io.legado.kmp.ios", code: -1, userInfo: [NSLocalizedDescriptionKey: L10n.AudioPlay.unavailable])
    }

    private func catalogError(_ message: String) -> NSError {
        NSError(domain: "AudioPlayback.Catalog", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func requiredFacade() throws -> AudioPlayFacade {
        guard let facade else { throw unavailableError() }
        return facade
    }
}
