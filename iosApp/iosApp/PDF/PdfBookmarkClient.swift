import Foundation
import shared

@MainActor
final class PdfBookmarkClient {
    let pageCount: Int

    private struct BookIdentity: Equatable {
        let url: String
        let name: String
        let author: String
        let origin: String

        init(_ book: Book) {
            url = book.bookUrl
            name = book.name
            author = book.author
            origin = book.origin
        }
    }

    private struct Services {
        let books: BookDetailFacade
        let shelf: BookshelfFacade
        let reader: ReaderFacade
        let bookmarks: BookmarkFacade
    }

    private struct Context {
        let identity: BookIdentity
        let chapters: [BookChapter]
    }

    private struct DraftIdentity: Equatable {
        let book: BookIdentity
        let page: Int32
        let title: String
    }

    // Only the timestamp allocator is process-wide; no persisted book or bookmark is cached globally.
    private static var lastIssuedTime: Int64 = 0
    private static let textLimit = 16_384
    private static let draftLimit = 32
    private let bookURL: String
    private var boundIdentity: BookIdentity?
    private var drafts: [Int64: DraftIdentity] = [:]
    private var isWriting = false

    init(bookURL: String, pageCount: Int) {
        self.bookURL = bookURL
        self.pageCount = pageCount
    }

    func getBookmarks() async throws -> [Bookmark] {
        let services = try self.services()
        let context = try await self.context(using: services)
        let bookmarks = try await allBookmarks(using: services)
        _ = try await persistedBook(using: services)
        // Invalid locations remain visible. Only explicit operations validate an individual row.
        return bookmarks.filter {
            $0.bookName == context.identity.name && $0.bookAuthor == context.identity.author
        }.sorted {
            if $0.chapterIndex != $1.chapterIndex { return $0.chapterIndex < $1.chapterIndex }
            return $0.time < $1.time
        }
    }

    func makeDraft(pageIndex: Int, excerpt: String) async throws -> Bookmark {
        try validate(pageIndex: pageIndex)
        try validate(text: excerpt, field: "摘录")
        let services = try self.services()
        let context = try await self.context(using: services)
        let bookmarks = try await allBookmarks(using: services)
        _ = try await persistedBook(using: services)
        let title = context.chapters[pageIndex].title
        try validate(text: title, field: "页面标题")
        let time = try Self.nextTime()
        guard !bookmarks.contains(where: { $0.time == time }) else {
            throw failure("书签时间标识已存在，请重新添加")
        }
        let draft = Bookmark(
            time: time, bookName: context.identity.name, bookAuthor: context.identity.author,
            chapterIndex: Int32(pageIndex), chapterPos: 0, chapterName: title, bookText: excerpt, content: "")
        // Unsaved identities are bounded and local to this editor client. Cancelling never writes a row.
        if drafts.count >= Self.draftLimit, let oldest = drafts.keys.min() {
            drafts.removeValue(forKey: oldest)
        }
        drafts[time] = DraftIdentity(book: context.identity, page: draft.chapterIndex, title: title)
        return draft
    }

    func save(_ original: Bookmark, bookText: String, note: String, isNew: Bool) async throws -> Bookmark {
        try beginWrite()
        defer { isWriting = false }
        try validate(text: bookText, field: "摘录")
        try validate(text: note, field: "备注")
        let services = try self.services()
        let context = try await self.context(using: services)
        try validateOwner(original, in: context)
        if isNew {
            try validate(original, in: context)
            let identity = DraftIdentity(
                book: context.identity, page: original.chapterIndex, title: original.chapterName)
            guard drafts[original.time] == identity else {
                throw failure("书签草稿已失效或定位已变化，请重新添加")
            }
            guard original.chapterName == context.chapters[Int(original.chapterIndex)].title else {
                throw failure("PDF 页面标题已变化，请重新添加书签")
            }
        }

        // Recheck the group/catalog before fetching the latest row, not an earlier list snapshot.
        let currentContext = try await self.context(using: services)
        try validateOwner(original, in: currentContext)
        if isNew { try validate(original, in: currentContext) }
        if isNew, original.chapterName != currentContext.chapters[Int(original.chapterIndex)].title {
            throw failure("PDF 页面标题已变化，请重新添加书签")
        }
        let bookmarks = try await allBookmarks(using: services)
        let source: Bookmark
        if isNew {
            guard !bookmarks.contains(where: { $0.time == original.time }) else {
                throw failure("书签时间标识已被占用，未覆盖现有书签，请重新加载")
            }
            source = original
        } else {
            source = try latest(original, in: bookmarks, context: currentContext)
        }
        try Task.checkCancellation()
        let updated = Bookmark(
            time: source.time, bookName: source.bookName, bookAuthor: source.bookAuthor,
            chapterIndex: source.chapterIndex, chapterPos: source.chapterPos, chapterName: source.chapterName,
            bookText: bookText, content: note)

        // The shared API is upsert, not compare-and-swap. These checks cannot form a cross-Scene transaction.
        // Retire a draft before sending: an uncertain callback must not retry it as a new insert.
        if isNew { drafts.removeValue(forKey: original.time) }
        do {
            try await SharedAsync.void {
                services.bookmarks.updateBookmark(bookmark: updated, completionHandler: $0)
            }
        } catch {
            throw failure("书签保存未确认，请重新加载书签后再操作", underlying: error)
        }
        return updated
    }

    func delete(_ original: Bookmark) async throws {
        try beginWrite()
        defer { isWriting = false }
        let services = try self.services()
        let context = try await self.context(using: services)
        try validateOwner(original, in: context)
        let bookmarks = try await allBookmarks(using: services)
        let target = try latest(original, in: bookmarks, context: context)
        try Task.checkCancellation()
        do {
            try await SharedAsync.void {
                services.bookmarks.deleteBookmark(time: target.time, completionHandler: $0)
            }
        } catch {
            throw failure("书签删除未确认，请重新加载书签后再操作", underlying: error)
        }
    }

    func page(for bookmark: Bookmark) async throws -> Int {
        let services = try self.services()
        let context = try await self.context(using: services)
        try validate(bookmark, in: context)
        let bookmarks = try await allBookmarks(using: services)
        let target = try latest(bookmark, in: bookmarks, context: context)
        _ = try await persistedBook(using: services)
        return Int(target.chapterIndex)
    }

    private func services() throws -> Services {
        try Task.checkCancellation()
        do {
            return try Services(
                books: SharedRuntime.bookDetailFacade().get(), shelf: SharedRuntime.bookshelfFacade().get(),
                reader: SharedRuntime.readerFacade().get(), bookmarks: SharedRuntime.bookmarkFacade().get())
        } catch {
            throw failure("书签服务暂不可用，请稍后重试", underlying: error)
        }
    }

    private func persistedBook(using services: Services) async throws -> Book {
        try Task.checkCancellation()
        guard !bookURL.isEmpty, !bookURL.contains("\0"), pageCount > 0, pageCount <= Int(Int32.max) else {
            throw failure("PDF 书籍地址或页面数量无效")
        }
        let book: Book?
        do {
            book = try await SharedAsync.optionalValue {
                services.books.resolvePersistedBook(bookUrl: bookURL, completionHandler: $0)
            }
        } catch {
            try Task.checkCancellation()
            throw failure("无法读取当前 PDF 书籍，请稍后重试", underlying: error)
        }
        try Task.checkCancellation()
        guard let book, book.bookUrl == bookURL else { throw failure("书籍已移除，请返回书架重新打开") }
        guard book.isLocal, LocalBookFileBinding.shared.format(book: book) == "pdf",
            !book.isAudio, !book.isImage, !book.isEpub
        else { throw failure("当前书籍不是可用的本地 PDF") }
        guard Int(book.totalChapterNum) == pageCount else {
            throw failure("PDF 页面数量已变化，请重新打开书籍")
        }
        guard !book.config.reverseToc else {
            throw failure("PDF 目录已反转，不能按物理页定位，请恢复目录后重新打开书籍")
        }
        let identity = BookIdentity(book)
        if let boundIdentity, boundIdentity != identity {
            throw failure("PDF 书籍归属或书签分组已变化，请重新打开书籍")
        }
        boundIdentity = identity
        return book
    }

    private func context(using services: Services) async throws -> Context {
        let book = try await persistedBook(using: services)
        let identity = BookIdentity(book)
        let shelfBooks: [Book]
        let databaseBooks: [Book]
        do {
            shelfBooks = try await SharedAsync.value {
                services.shelf.loadBooks(groupId: -1, completionHandler: $0)
            }
            try Task.checkCancellation()
            databaseBooks = try await SharedAsync.value {
                services.shelf.searchBooks(query: identity.name, completionHandler: $0)
            }
        } catch {
            try Task.checkCancellation()
            throw failure("无法核实书签分组，请稍后重试", underlying: error)
        }
        try Task.checkCancellation()
        // Database search includes NOT_SHELF previews; exact grouping excludes fuzzy name/author matches.
        let matches = (shelfBooks + databaseBooks).filter { $0.name == identity.name && $0.author == identity.author }
        var owners = Set(matches.map(\.bookUrl))
        owners.insert(bookURL)
        guard owners.count == 1 else {
            throw failure("存在多本同名同作者书籍（含预览），无法确认书签归属，请先处理重复书籍")
        }
        let chapters = try await self.chapters(using: services)
        _ = try await persistedBook(using: services)
        guard chapters.count == pageCount else { throw failure("PDF 目录与页面数量不一致，请重新打开书籍") }
        for (index, chapter) in chapters.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            guard chapter.bookUrl == bookURL, Int(chapter.index) == index,
                chapter.url == "pdf-page-\(index + 1)", !chapter.isVolume,
                chapter.start == nil, chapter.end == nil,
                chapter.startFragmentId == nil, chapter.endFragmentId == nil
            else { throw failure("PDF 目录页身份已变化，请重新打开书籍") }
        }
        return Context(identity: identity, chapters: chapters)
    }

    private func chapters(using services: Services) async throws -> [BookChapter] {
        let request = PdfBookmarkChapterRead()
        defer { request.finish() }
        let timeout = failure("读取 PDF 目录超时，请稍后重试")
        do {
            let chapters: [BookChapter] = try await SharedCancellableAsync.value { completion in
                request.startDeadline { completion(nil, timeout) }
                // Read only persisted rows; loadChapterListState/getBookmarks can revive a removed preview.
                let subscription = services.reader.watchChapters(bookUrl: bookURL) { completion($0, nil) }
                request.install(subscription)
                return subscription
            }
            try Task.checkCancellation()
            return chapters
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw failure("无法读取 PDF 目录，请稍后重试", underlying: error)
        }
    }

    private func allBookmarks(using services: Services) async throws -> [Bookmark] {
        try Task.checkCancellation()
        do {
            let bookmarks: [Bookmark] = try await SharedAsync.value {
                services.bookmarks.getAllBookmarks(completionHandler: $0)
            }
            try Task.checkCancellation()
            return bookmarks
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw failure("无法读取最新书签，请稍后重试", underlying: error)
        }
    }

    private func latest(_ original: Bookmark, in bookmarks: [Bookmark], context: Context) throws -> Bookmark {
        let matches = bookmarks.filter { $0.time == original.time }
        guard matches.count == 1, let current = matches.first else {
            throw failure("书签已被删除或标识无效，请重新加载书签")
        }
        try validateOwner(current, in: context)
        guard current.bookName == original.bookName, current.bookAuthor == original.bookAuthor,
            current.chapterIndex == original.chapterIndex, current.chapterPos == original.chapterPos,
            current.chapterName == original.chapterName
        else { throw failure("书签归属或定位已变化，请重新加载书签") }
        guard current.bookText == original.bookText, current.content == original.content else {
            throw failure("书签摘录或备注已被修改，请重新加载后再操作")
        }
        return current
    }

    private func validate(_ bookmark: Bookmark, in context: Context) throws {
        try validateOwner(bookmark, in: context)
        try validate(pageIndex: Int(bookmark.chapterIndex))
        guard bookmark.chapterPos == 0 else { throw failure("书签不是有效的 PDF 页面起始位置") }
    }

    private func validateOwner(_ bookmark: Bookmark, in context: Context) throws {
        guard bookmark.bookName == context.identity.name, bookmark.bookAuthor == context.identity.author else {
            throw failure("书签不属于当前 PDF 的书名、作者分组")
        }
    }

    private func validate(pageIndex: Int) throws {
        guard pageIndex >= 0, pageIndex < pageCount, pageIndex <= Int(Int32.max) else {
            throw failure("PDF 书签页码超出可读范围")
        }
    }

    private func validate(text: String, field: String) throws {
        guard text.utf16.count <= Self.textLimit else {
            throw failure("\(field)过长，最多允许 \(Self.textLimit) 个 UTF-16 字符")
        }
    }

    private func beginWrite() throws {
        try Task.checkCancellation()
        guard !isWriting else { throw failure("书签操作尚未结束，请稍后重试") }
        isWriting = true
    }

    private static func nextTime() throws -> Int64 {
        let milliseconds = (Date().timeIntervalSince1970 * 1_000).rounded(.down)
        guard milliseconds.isFinite, let now = Int64(exactly: milliseconds), lastIssuedTime < Int64.max else {
            throw NSError(
                domain: "io.legado.kmp.ios.pdf.bookmark", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法生成有效的书签时间标识，请稍后重试"])
        }
        let time = max(now, lastIssuedTime + 1)
        lastIssuedTime = time
        return time
    }

    private func failure(_ message: String, underlying: Error? = nil) -> NSError {
        var info: [String: Any] = [NSLocalizedDescriptionKey: message]
        if let underlying { info[NSUnderlyingErrorKey] = underlying as NSError }
        return NSError(domain: "io.legado.kmp.ios.pdf.bookmark", code: 1, userInfo: info)
    }
}

private final class PdfBookmarkChapterRead: @unchecked Sendable {
    private let lock = NSLock()
    private var subscription: FlowSubscription?
    private var deadline: Task<Void, Never>?
    private var finished = false

    func startDeadline(_ completion: @escaping @Sendable () -> Void) {
        let deadline = Task {
            do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
            completion()
        }
        lock.lock()
        let finished = self.finished
        if !finished { self.deadline = deadline }
        lock.unlock()
        if finished { deadline.cancel() }
    }

    func install(_ subscription: FlowSubscription) {
        lock.lock()
        let finished = self.finished
        if !finished { self.subscription = subscription }
        lock.unlock()
        if finished { subscription.cancel() }
    }

    func finish() {
        lock.lock()
        finished = true
        let subscription = self.subscription
        let deadline = self.deadline
        self.subscription = nil
        self.deadline = nil
        lock.unlock()
        deadline?.cancel()
        subscription?.cancel()
    }
}
