import Foundation
import shared

struct MangaReaderCatalogSnapshot {
    let book: Book
    let items: [ReaderChapterListItem]
    let identity: UUID
    fileprivate let owner: UUID
    fileprivate let generation: UUID
    fileprivate let bookSignature: MangaReaderCatalogBookSignature
    fileprivate let directory: [BookChapter]
    fileprivate let directorySignature: String
    fileprivate let readableSignature: String

    fileprivate init(
        book: Book, items: [ReaderChapterListItem], owner: UUID, generation: UUID,
        directory: [BookChapter]
    ) {
        self.book = book
        self.items = items
        identity = UUID()
        self.owner = owner
        self.generation = generation
        bookSignature = MangaReaderCatalogBookSignature(book)
        self.directory = directory
        directorySignature = ReaderCatalogSnapshot.signature(directory)
        readableSignature = ReaderCatalogSnapshot.signature(items.map(\.chapter))
    }
}

// Freeze values separately: Kotlin's ReadConfig is mutable even when Book is retained by a snapshot.
fileprivate struct MangaReaderCatalogBookSignature: Equatable {
    let bookURL: String
    let origin: String
    let tocURL: String
    let name: String
    let author: String
    let type: Int32
    let charset: String?
    let readConfig: String

    init(_ book: Book) {
        bookURL = book.bookUrl
        origin = book.origin
        tocURL = book.tocUrl
        name = book.name
        author = book.author
        type = book.type
        charset = book.charset
        // Source JS may persist runtime variables while preparing a chapter; they are not book identity.
        readConfig = book.config.toJson()
    }
}

/// ReadMangaActivity / TocActivityResult at Legado 5f5d314: positions are image indices.
@MainActor
final class MangaReaderCatalogClient {
    struct Context {
        let generation: UUID
        let book: Book
    }

    struct Selection {
        fileprivate let snapshot: MangaReaderCatalogSnapshot
        fileprivate let index: Int
        fileprivate let position: Int
        fileprivate let generation = UUID()
    }

    private struct PersistedCatalog {
        let book: Book
        let signature: MangaReaderCatalogBookSignature
        let chapters: [BookChapter]
        let directorySignature: String
        let readableCount: Int

        func matches(_ snapshot: MangaReaderCatalogSnapshot) -> Bool {
            signature == snapshot.bookSignature && directorySignature == snapshot.directorySignature
                && readableCount == snapshot.items.count
        }
    }

    private let owner = UUID()
    private let bookURL: String
    private let reader: ReaderFacade
    private let books: BookDetailFacade
    private let queue: ReaderProgressQueue
    private let context: () throws -> Context
    private var activeSelection: Selection?
    private weak var preparedChapter: MangaReaderChapter?

    init(
        bookURL: String, reader: ReaderFacade, books: BookDetailFacade, queue: ReaderProgressQueue,
        context: @escaping () throws -> Context
    ) {
        self.bookURL = bookURL
        self.reader = reader
        self.books = books
        self.queue = queue
        self.context = context
    }

    func snapshot() async throws -> MangaReaderCatalogSnapshot {
        let generation = try context().generation
        // flushNow() is best-effort; a catalog must not publish an unsaved checkpoint.
        try await queue.flushForExit()
        try check(generation)
        let before = try await persistedCatalog(generation: generation)
        let items = try await reader.loadChapterListStateAsync(bookUrl: bookURL)
        try check(generation)
        let after = try await persistedCatalog(generation: generation)
        guard before.signature == after.signature, before.directorySignature == after.directorySignature,
            before.readableCount == after.readableCount,
            before.book.durChapterIndex == after.book.durChapterIndex,
            before.book.durChapterPos == after.book.durChapterPos,
            before.book.durChapterTime == after.book.durChapterTime,
            ReaderCatalogSnapshot.signature(items.map(\.chapter)) == after.directorySignature,
            items.allSatisfy({ $0.isCurrent == ($0.chapter.index == after.book.durChapterIndex) })
        else { throw failure("漫画进度或目录已变化，请重新打开目录") }
        return MangaReaderCatalogSnapshot(
            book: after.book, items: Array(items.prefix(after.readableCount)), owner: owner,
            generation: generation, directory: after.chapters)
    }

    func prepareSelection(index: Int, position: Int, snapshot: MangaReaderCatalogSnapshot) async throws -> Selection {
        try checkSnapshot(snapshot)
        guard snapshot.items.indices.contains(index), position >= 0,
            Int32(exactly: index) != nil, Int32(exactly: position) != nil,
            Int(snapshot.items[index].chapter.index) == index
        else { throw failure("漫画章节或图片页码超出范围") }
        let current = try await persistedCatalog(generation: snapshot.generation)
        try checkSnapshot(snapshot)
        guard current.matches(snapshot) else { throw failure("漫画书籍或目录已变化，请重新打开目录") }
        return Selection(snapshot: snapshot, index: index, position: position)
    }

    // Only the existing adapter.load may roll the recovery generation for an explicit selection.
    func begin(_ selection: Selection) throws -> UUID {
        try checkSnapshot(selection.snapshot)
        activeSelection = selection
        preparedChapter = nil
        return selection.generation
    }

    func isSelectionContextCurrent(snapshot: MangaReaderCatalogSnapshot) -> Bool {
        guard snapshot.owner == owner, !Task.isCancelled, let current = try? context() else { return false }
        guard current.book.bookUrl == bookURL, ReaderSyncClient.sameIdentity(current.book, snapshot.book) else {
            return false
        }
        if current.generation == snapshot.generation { return true }
        return activeSelection.map {
            $0.snapshot.identity == snapshot.identity && $0.generation == current.generation
        } == true
    }

    func isPreparedSelectionCurrent(_ prepared: MangaReaderChapter, snapshot: MangaReaderCatalogSnapshot) -> Bool {
        guard isSelectionContextCurrent(snapshot: snapshot), preparedChapter === prepared,
            let selected = activeSelection, selected.snapshot.identity == snapshot.identity,
            let current = try? context(), current.generation == selected.generation
        else { return false }
        return MangaReaderCatalogBookSignature(prepared.book) == snapshot.bookSignature
            && Int(prepared.chapterIndex) == selected.index && Int(prepared.chapterPosition) == selected.position
    }

    func validate(_ selection: Selection, allowingContentUpdates: Bool = false) async throws {
        try check(selection.generation)
        let current = try await persistedCatalog(generation: selection.generation)
        let snapshot = selection.snapshot
        let matches =
            allowingContentUpdates
            ? current.signature == snapshot.bookSignature && current.readableCount == snapshot.items.count
                && Self.matchesDirectory(current.chapters, expected: snapshot.directory, updatedIndex: selection.index)
            : current.matches(snapshot)
        guard snapshot.owner == owner, matches else {
            throw failure("漫画书籍或目录已变化，请重新打开目录")
        }
    }

    func validate(_ payload: ReaderChapterPayload, selection: Selection) throws {
        try check(selection.generation)
        let snapshot = selection.snapshot
        guard MangaReaderCatalogBookSignature(payload.book) == snapshot.bookSignature,
            Self.matchesDirectory(payload.chapters, expected: snapshot.directory, updatedIndex: selection.index),
            Int(payload.chapter.index) == selection.index,
            ReaderCatalogSnapshot.signature([payload.chapter])
                == ReaderCatalogSnapshot.signature([payload.chapters[selection.index]])
        else { throw failure("漫画加载结果与目录快照不一致") }
    }

    func validate(_ prepared: MangaReaderChapter, selection: Selection) async throws {
        try check(selection.generation)
        let snapshot = selection.snapshot
        guard MangaReaderCatalogBookSignature(prepared.book) == snapshot.bookSignature,
            Int(prepared.chapterIndex) == selection.index,
            Self.matchesDirectory(
                prepared.chapters, expected: snapshot.items.map(\.chapter), updatedIndex: selection.index),
            prepared.isVolume == snapshot.items[selection.index].chapter.isVolume
        else { throw failure("漫画加载结果与目录快照不一致") }
        // The shared parser clamps positions. Reject the original invalid value instead of accepting that clamp.
        let validPosition =
            prepared.pages.indices.contains(selection.position)
            || (prepared.isVolume && prepared.pages.isEmpty && selection.position == 0)
        guard validPosition, Int(prepared.chapterPosition) == selection.position else {
            throw failure("漫画图片页码已超出当前章节")
        }
        try await validate(selection, allowingContentUpdates: true)
        preparedChapter = prepared
    }

    private func persistedCatalog(generation: UUID) async throws -> PersistedCatalog {
        try check(generation)
        let before = try await persistedBook(generation: generation)
        let signature = MangaReaderCatalogBookSignature(before)
        let chapters = try await persistedChapters(generation: generation)
        let after = try await persistedBook(generation: generation)
        guard signature == MangaReaderCatalogBookSignature(after),
            let size = Int32(exactly: chapters.count),
            chapters.enumerated().allSatisfy({ $0.element.bookUrl == bookURL && Int($0.element.index) == $0.offset })
        else { throw failure("漫画书籍或目录身份已变化") }
        let readable = Int(reader.computeSimulatedChapterSize(readConfig: after.readConfig, realChapterSize: size))
        guard readable >= 0, readable <= chapters.count else { throw failure("漫画可读范围无效") }
        return PersistedCatalog(
            book: after, signature: signature, chapters: chapters,
            directorySignature: ReaderCatalogSnapshot.signature(chapters), readableCount: readable)
    }

    private func persistedBook(generation: UUID) async throws -> Book {
        // Never fall back to a search candidate or resolveBook: removed previews must stay removed.
        let book: Book? = try await SharedAsync.optionalValue {
            books.resolvePersistedBook(bookUrl: bookURL, completionHandler: $0)
        }
        try check(generation)
        guard let book, book.bookUrl == bookURL else { throw failure("书籍不存在或已被移除") }
        guard ReaderSyncClient.sameIdentity(try context().book, book) else {
            throw failure("漫画书籍或书源已变化")
        }
        return book
    }

    private func persistedChapters(generation: UUID) async throws -> [BookChapter] {
        var subscription: FlowSubscription?
        defer { subscription?.cancel() }
        let chapters: [BookChapter] = try await SharedCancellableAsync.value { completion in
            let watching = reader.watchChapters(bookUrl: bookURL) { completion($0, nil) }
            subscription = watching
            return watching
        }
        try check(generation)
        return chapters
    }

    private func checkSnapshot(_ snapshot: MangaReaderCatalogSnapshot) throws {
        try check(snapshot.generation)
        guard snapshot.owner == owner, snapshot.bookSignature == MangaReaderCatalogBookSignature(snapshot.book),
            snapshot.readableSignature == ReaderCatalogSnapshot.signature(snapshot.items.map(\.chapter))
        else { throw failure("漫画目录快照已失效") }
    }

    private static func matchesDirectory(_ chapters: [BookChapter], expected: [BookChapter], updatedIndex: Int) -> Bool
    {
        guard chapters.count == expected.count, chapters.indices.contains(updatedIndex) else { return false }
        let chapter = chapters[updatedIndex]
        let original = expected[updatedIndex]
        // Content rules may change only the selected row's title/variables, never its routing or ranges.
        guard chapter.bookUrl == original.bookUrl, chapter.index == original.index, chapter.url == original.url,
            chapter.baseUrl == original.baseUrl, chapter.resourceUrl == original.resourceUrl,
            chapter.isVolume == original.isVolume, chapter.isVip == original.isVip, chapter.isPay == original.isPay,
            chapter.start?.int64Value == original.start?.int64Value,
            chapter.end?.int64Value == original.end?.int64Value,
            chapter.startFragmentId == original.startFragmentId, chapter.endFragmentId == original.endFragmentId
        else { return false }
        var normalized = chapters
        normalized[updatedIndex] = original
        return ReaderCatalogSnapshot.signature(normalized) == ReaderCatalogSnapshot.signature(expected)
    }

    private func check(_ generation: UUID) throws {
        try Task.checkCancellation()
        let current = try context()
        guard current.generation == generation, current.book.bookUrl == bookURL else { throw CancellationError() }
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "io.legado.mangaCatalog", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
