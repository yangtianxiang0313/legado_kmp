import Dispatch
import Foundation
import shared

final class ReaderScreenAdapter: ReaderScreenAdapterSearchable, ReaderBookmarkListProviding, BookSourceEditingProviding {
    private let bindings = ScreenBindingController(owner: "ReaderScreen")
    private let progressQueue: ReaderProgressQueue
    private let chapterRequestGate: ReaderChapterRequestGate
    @MainActor private(set) lazy var catalogRefresh = ReaderCatalogRefreshClient(
        binding: { [weak self] in (self?.bookURL ?? "", self?.bookBindingID ?? UUID()) },
        reader: { [weak self] in self?.facade }, books: { [weak self] in self?.bookDetailFacade },
        queue: progressQueue,
        publish: { [weak self] snapshot in
            self?.handleBook(snapshot.book)
            self?.handleChapters(snapshot.chapters)
        })
    private var bookURL: String
    private var bookBindingID = UUID()
    private lazy var sourceChangeClient = ReaderSourceChangeClient(
        binding: { [weak self] in
            guard let self else { return (bookURL: "", generation: UUID()) }
            return (bookURL: self.bookURL, generation: self.bookBindingID)
        },
        facade: { [weak self] in self?.bookDetailFacade },
        sourceExists: { [weak self] sourceURL in
            guard let facade = self?.sourceManagementFacade else {
                throw NSError(
                    domain: "io.legado.kmp.ios", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: L10n.Reader.unavailable])
            }
            return try await facade.getSourceAsync(sourceUrl: sourceURL) != nil
        },
        flushProgress: { [weak self] in await self?.flushReadingProgressNow() }
    )
    private var facade: ReaderFacade?
    private lazy var chapterOrderClient = ReaderChapterOrderClient(
        binding: { [weak self] in (self?.bookURL ?? "", self?.bookBindingID ?? UUID()) },
        facade: { [weak self] in self?.facade },
        flushProgress: { [weak self] in await self?.flushReadingProgressNow() }
    )
    private var settingsFacade: SettingsFacade?
    @MainActor private lazy var syncClient = ReaderSyncClient(
        binding: { [weak self] in (self?.bookURL ?? "", self?.bookBindingID ?? UUID()) },
        reader: { [weak self] in self?.facade }, settings: { [weak self] in self?.settingsFacade },
        books: { [weak self] in self?.bookDetailFacade }, queue: progressQueue)
    private var runtimeFacade: RuntimeFacade?
    private lazy var readAloudClient = ReaderReadAloudClient(runtimeFacade: { [weak self] in self?.runtimeFacade })
    private var bookDetailFacade: BookDetailFacade?
    @MainActor private lazy var exitClient = ReaderExitClient(
        binding: { [weak self] in (self?.bookURL ?? "", self?.bookBindingID ?? UUID()) },
        facade: { [weak self] in self?.bookDetailFacade },
        flushProgress: { [weak self] in try await self?.progressQueue.flushForExit() })
    private var sourceManagementFacade: SourceManagementFacade?
    private var lastBookSignature: String?
    private var lastChaptersSignature: String?
    private var lastPreferencesKey: ReaderPreferencesPresentationKey?
    private var lastRuntimeSignature: String?
    private var lastReadAloudSignature: String?
    private var latestReadAloudState: ReadAloudState?
    private(set) var latestPreferences: AppUiPreferences?

    var onBookChange: ((Book?) -> Void)?
    var onChaptersChange: (([BookChapter]) -> Void)?
    var onPreferencesChange: ((AppUiPreferences) -> Void)?
    var onRuntimeConfigChange: ((AppRuntimeConfig) -> Void)?
    var onReadAloudStateChange: ((ReadAloudState) -> Void)?
    var onChapterLoadingActivityChange: ((Bool) -> Void)?

    init(bookURL: String) {
        self.bookURL = bookURL
        progressQueue = ReaderProgressQueue(bookURL: bookURL)
        chapterRequestGate = ReaderChapterRequestGate(bookURL: bookURL)
    }

    func bootstrap() -> Result<Void, SharedRuntimeError> {
        let bindingID = UUID()
        bookBindingID = bindingID
        chapterRequestGate.bind(bookURL: bookURL, facade: nil)
        bindings.cancelAll()
        progressQueue.bind(bookURL: bookURL, facade: nil)
        lastBookSignature = nil
        lastChaptersSignature = nil
        lastPreferencesKey = nil
        lastRuntimeSignature = nil
        lastReadAloudSignature = nil
        latestReadAloudState = nil

        switch (
            SharedRuntime.readerFacade(),
            SharedRuntime.settingsFacade(),
            SharedRuntime.runtimeFacade(),
            SharedRuntime.bookDetailFacade()
        ) {
        case (.success(let facade), .success(let settingsFacade), .success(let runtimeFacade), .success(let bookDetailFacade)):
            self.facade = facade
            progressQueue.bind(bookURL: bookURL, facade: facade)
            chapterRequestGate.bind(bookURL: bookURL, facade: facade)
            self.settingsFacade = settingsFacade
            self.runtimeFacade = runtimeFacade
            self.bookDetailFacade = bookDetailFacade
            if case .success(let sourceManagementFacade) = SharedRuntime.sourceManagementFacade() {
                self.sourceManagementFacade = sourceManagementFacade
            }
            bindings.replaceBinding(
                key: "book",
                with: facade.watchBook(bookUrl: bookURL) { [weak self] book in
                    DispatchQueue.main.async {
                        guard let self, self.bookBindingID == bindingID else { return }
                        self.handleBook(book)
                    }
                })
            bindings.replaceBinding(
                key: "chapters",
                with: facade.watchChapters(bookUrl: bookURL) { [weak self] chapters in
                    DispatchQueue.main.async {
                        guard let self, self.bookBindingID == bindingID else { return }
                        self.handleChapters(chapters)
                    }
                })
            bindings.replaceBinding(
                key: "preferences",
                with: settingsFacade.watchPreferences { [weak self] preferences in
                    DispatchQueue.main.async {
                        self?.handlePreferences(preferences)
                    }
                })
            bindings.replaceBinding(
                key: "runtimeConfig",
                with: settingsFacade.watchRuntimeConfig { [weak self] runtimeConfig in
                    DispatchQueue.main.async {
                        self?.handleRuntimeConfig(runtimeConfig)
                    }
                })
            bindings.replaceBinding(
                key: "readAloudState",
                with: runtimeFacade.watchDetailedReadAloudState { [weak self] state in
                    DispatchQueue.main.async {
                        self?.handleReadAloudState(state)
                    }
                })
            return .success(())
        case (.failure(let error), _, _, _),
            (_, .failure(let error), _, _),
            (_, _, .failure(let error), _),
            (_, _, _, .failure(let error)):
            return .failure(error)
        }
    }

    @MainActor
    func rebindBookURL(_ newBookURL: String, book: Book?, chapters: [BookChapter]) {
        let normalized = newBookURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else { return }
        onChapterLoadingActivityChange?(true)
        let bindingID = UUID()
        bookBindingID = bindingID
        chapterRequestGate.bind(bookURL: normalized, facade: facade)
        progressQueue.bind(bookURL: normalized, facade: facade)
        lastBookSignature = nil
        lastChaptersSignature = nil
        bookURL = normalized
        if let latestReadAloudState {
            handleReadAloudState(latestReadAloudState)
        }
        if let facade {
            bindings.replaceBinding(
                key: "book",
                with: facade.watchBook(bookUrl: normalized) { [weak self] book in
                    DispatchQueue.main.async {
                        guard let self, self.bookBindingID == bindingID else { return }
                        self.handleBook(book)
                    }
                })
            bindings.replaceBinding(
                key: "chapters",
                with: facade.watchChapters(bookUrl: normalized) { [weak self] chapters in
                    DispatchQueue.main.async {
                        guard let self, self.bookBindingID == bindingID else { return }
                        self.handleChapters(chapters)
                    }
                })
        }
        handleBook(book)
        handleChapters(chapters)
    }

    func loadChapter(index: Int) async throws -> ReaderChapterPayload {
        try await prepareChapter(index: index, refreshContent: false)
    }

    @MainActor
    func completePreviewReadingExit(bookURL: String, expectedOrigin: String, addToShelf: Bool) async throws -> Book? {
        try await exitClient.complete(bookURL: bookURL, expectedOrigin: expectedOrigin, addToShelf: addToShelf)
    }

    @MainActor
    func resolveBookForExit() async throws -> Book? { try await exitClient.resolve() }

    @MainActor
    func resolveCurrentBook() async throws -> Book {
        let generation = bookBindingID
        let url = bookURL
        guard let bookDetailFacade else {
            throw NSError(
                domain: "io.legado.kmp.ios", code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Reader.unavailable])
        }
        let current = try await bookDetailFacade.resolveBookAsync(bookUrl: url)
        try Task.checkCancellation()
        guard generation == bookBindingID, url == bookURL else { throw CancellationError() }
        guard let current else {
            throw NSError(
                domain: "io.legado.kmp.ios", code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Reader.syncProgressBookMissing])
        }
        return current
    }

    func resumeChapterLoading() {
        chapterRequestGate.resume()
        onChapterLoadingActivityChange?(false)
    }

    func suspendChapterLoading() {
        onChapterLoadingActivityChange?(true)
        chapterRequestGate.suspend()
    }

    func cancelChapterLoading() {
        onChapterLoadingActivityChange?(true)
        chapterRequestGate.cancel()
    }

    private func prepareChapter(index: Int, refreshContent: Bool) async throws -> ReaderChapterPayload {
        let ticket = try chapterRequestGate.begin()
        do {
            try chapterRequestGate.check(ticket)
            await catalogRefresh.waitUntilSettled()
            try chapterRequestGate.check(ticket)
            await flushReadingProgressNow()
            try chapterRequestGate.check(ticket)
            let requestGate = chapterRequestGate
            let payload: ReaderChapterPayload = try await SharedCancellableAsync.value { completion in
                let subscription = ticket.facade.prepareChapterRequest(
                    bookUrl: ticket.bookURL,
                    chapterIndex: Int32(index),
                    refreshContent: refreshContent
                ) { result in
                    requestGate.finish(ticket)
                    if result.isCancelled {
                        #if DEBUG
                            SharedRuntime.log("Kotlin chapter request cancelled index=\(index)")
                        #endif
                        completion(nil, CancellationError())
                    } else if result.errorCode != nil || result.errorMessage != nil {
                        var userInfo: [String: Any] = [
                            NSLocalizedDescriptionKey: result.errorMessage ?? result.errorCode ?? L10n.Shared.emptyValue
                        ]
                        if let errorCode = result.errorCode {
                            userInfo["errorCode"] = errorCode
                        }
                        if let errorMessage = result.errorMessage {
                            userInfo["errorMessage"] = errorMessage
                        }
                        completion(
                            nil,
                            NSError(
                                domain: "io.legado.kmp.ios",
                                code: result.errorCode.flatMap { Int($0) } ?? -1,
                                userInfo: userInfo
                            ))
                    } else {
                        completion(result.payload, nil)
                    }
                }
                requestGate.register(subscription, for: ticket)
                return subscription
            }
            try chapterRequestGate.check(ticket)
            return payload
        } catch {
            try chapterRequestGate.check(ticket)
            throw error
        }
    }

    func peekChapter(index: Int) async throws -> ReaderChapterPayload {
        guard let facade else {
            throw NSError(
                domain: "io.legado.kmp.ios",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Reader.unavailable]
            )
        }
        return try await facade.peekChapterAsync(bookUrl: bookURL, chapterIndex: Int32(index))
    }

    func paginateChapter(
        chapterIndex: Int,
        chapterTitle: String,
        content: String,
        style: ReaderStylePreferences,
        runtime: ReaderRuntimeConfig,
        viewport: ReaderViewport,
        imageStyle: String?
    ) async throws -> ReaderChapterLayout {
        guard let facade else {
            throw NSError(
                domain: "io.legado.kmp.ios",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Reader.unavailable]
            )
        }
        return try await facade.paginateChapterAsync(
            chapterIndex: Int32(chapterIndex),
            chapterTitle: chapterTitle,
            content: content,
            style: style,
            runtime: runtime,
            viewport: viewport,
            imageStyle: imageStyle
        )
    }

    @MainActor
    func preloadDisplayedChapter(index: Int) async throws -> Bool {
        guard let facade else { return false }
        return try await ReaderChapterPrefetchRequest.run(facade: facade, bookURL: bookURL, index: index)
    }

    func onPageChanged() async throws {
        guard let facade else { return }
        // The visible reader owns prefetch cancellation; this callback only records reading time.
        try await facade.updateReadTime(bookUrl: bookURL)
    }

    func moveToPreviousChapter(toLastPage: Bool) async throws -> ChapterNavigationResult {
        guard let facade else {
            throw NSError(
                domain: "io.legado.kmp.ios",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Reader.unavailable]
            )
        }
        return try await SharedAsync.value { completion in
            facade.moveToPrevChapter(bookUrl: bookURL, toLast: toLastPage, completionHandler: completion)
        }
    }

    func moveToNextChapter() async throws -> ChapterNavigationResult {
        guard let facade else {
            throw NSError(
                domain: "io.legado.kmp.ios",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Reader.unavailable]
            )
        }
        return try await SharedAsync.value { completion in
            facade.moveToNextChapter(bookUrl: bookURL, completionHandler: completion)
        }
    }

    func computeSimulatedChapterSize(readConfig: ReadConfig?, realChapterSize: Int32) -> Int32 {
        guard let facade, let readConfig else { return realChapterSize }
        return facade.computeSimulatedChapterSize(readConfig: readConfig, realChapterSize: realChapterSize)
    }

    func refreshChapter(index: Int) async throws -> ReaderChapterPayload {
        try await prepareChapter(index: index, refreshContent: true)
    }

    func refreshChapterFromIndex(fromIndex: Int) async throws -> ReaderChapterPayload {
        guard let facade else {
            throw NSError(
                domain: "io.legado.kmp.ios",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Reader.unavailable]
            )
        }
        return try await facade.refreshChapterContentFromIndexAsync(bookUrl: bookURL, fromIndex: Int32(fromIndex))
    }

    func refreshAllChapterContent(currentIndex: Int) async throws -> ReaderChapterPayload {
        guard let facade else {
            throw NSError(
                domain: "io.legado.kmp.ios",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Reader.unavailable]
            )
        }
        return try await facade.refreshAllChapterContentAsync(bookUrl: bookURL, currentIndex: Int32(currentIndex))
    }

    func loadChapterListState() async throws -> [ReaderChapterListItem] {
        try await chapterOrderClient.loadState()
    }

    @MainActor
    func reverseChapterList() async throws -> BookDetailRefreshResult {
        await catalogRefresh.waitUntilSettled()
        return try await chapterOrderClient.reverse()
    }

    func addBookmark(
        chapterIndex: Int,
        chapterTitle: String?,
        chapterPosition: Int,
        pageText: String
    ) async throws {
        guard let facade else {
            throw NSError(
                domain: "io.legado.kmp.ios",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Reader.unavailable]
            )
        }
        let progressBindingID = progressQueue.currentBindingID
        try await facade.addBookmarkAsync(
            bookUrl: bookURL,
            chapterIndex: Int32(chapterIndex),
            chapterPosition: Int32(chapterPosition),
            pageText: pageText
        )
        progressQueue.stage(
            .init(
                chapterIndex: chapterIndex,
                chapterTitle: chapterTitle,
                chapterPosition: chapterPosition
            ),
            immediate: true,
            bindingID: progressBindingID
        )
    }

    func addSelectionBookmark(
        chapterIndex: Int,
        chapterPosition: Int,
        pageText: String
    ) async throws {
        guard let facade else {
            throw NSError(
                domain: "io.legado.kmp.ios",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Reader.unavailable]
            )
        }
        try await facade.addBookmarkAsync(
            bookUrl: bookURL,
            chapterIndex: Int32(chapterIndex),
            chapterPosition: Int32(chapterPosition),
            pageText: pageText
        )
    }

    func loadBookmarks() async throws -> [Bookmark] {
        guard let facade else {
            throw NSError(
                domain: "io.legado.kmp.ios",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Reader.unavailable]
            )
        }
        return try await facade.getBookmarksAsync(bookUrl: bookURL)
    }

    func updateBookmark(_ bookmark: Bookmark) async throws {
        switch SharedRuntime.bookmarkFacade() {
        case .success(let facade):
            try await facade.updateBookmark(bookmark: bookmark)
        case .failure(let error):
            throw error
        }
    }

    func deleteBookmark(_ bookmark: Bookmark) async throws {
        guard let facade else {
            throw NSError(
                domain: "io.legado.kmp.ios",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Reader.unavailable]
            )
        }
        try await facade.deleteBookmarkAsync(bookmarkTime: bookmark.time)
    }

    func requestPayAction(index: Int) async throws -> String {
        guard let facade else {
            throw NSError(
                domain: "io.legado.kmp.ios",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Reader.unavailable]
            )
        }
        return try await facade.requestPayActionAsync(bookUrl: bookURL, chapterIndex: Int32(index))
    }

    func toggleReplaceRule() async throws -> Book {
        guard let facade else {
            throw NSError(
                domain: "io.legado.kmp.ios",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Reader.unavailable]
            )
        }
        return try await facade.toggleReplaceRuleAsync(bookUrl: bookURL)
    }

    /// F41/F43/F44: 切换 delTag 位掩码
    func toggleDelTag(tag: Int64) async throws -> Book {
        guard let facade else {
            throw NSError(
                domain: "io.legado.kmp.ios",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Reader.unavailable]
            )
        }
        return try await facade.toggleDelTagAsync(bookUrl: bookURL, tag: tag)
    }

    func setRemoveSameTitle(chapterIndex: Int, removeSameTitle: Bool) async throws {
        guard let facade else {
            throw NSError(
                domain: "io.legado.kmp.ios",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Reader.unavailable]
            )
        }
        try await facade.setRemoveSameTitleAsync(
            bookUrl: bookURL,
            chapterIndex: Int32(chapterIndex),
            removeSameTitle: removeSameTitle
        )
    }

    /// F45: 设置图片样式
    @MainActor
    func setImageStyle(_ imageStyle: String) async throws -> Book {
        guard let facade else {
            throw NSError(
                domain: "io.legado.kmp.ios",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Reader.unavailable]
            )
        }
        let generation = bookBindingID
        let url = bookURL
        let result = try await facade.setImageStyleAsync(bookUrl: url, imageStyle: imageStyle)
        try Task.checkCancellation()
        guard generation == bookBindingID, url == bookURL else { throw CancellationError() }
        return result
    }

    /// F32: 设置编码
    @MainActor
    func setCharset(_ charset: String) async throws -> Book {
        guard let facade else {
            throw NSError(
                domain: "io.legado.kmp.ios",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Reader.unavailable]
            )
        }
        let generation = bookBindingID
        let url = bookURL
        let result = try await facade.setCharsetAsync(bookUrl: url, charset: charset)
        try Task.checkCancellation()
        guard generation == bookBindingID, url == bookURL else { throw CancellationError() }
        return result
    }

    /// F38: 反转当前章节内容
    func reverseContent(chapterIndex: Int) async throws -> ReaderChapterPayload {
        guard let facade else {
            throw NSError(
                domain: "io.legado.kmp.ios",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Reader.unavailable]
            )
        }
        return try await facade.reverseContentAsync(bookUrl: bookURL, chapterIndex: Int32(chapterIndex))
    }

    /// F34: 保存编辑后的章节内容
    func saveChapterContent(chapterIndex: Int, content: String) async throws -> ReaderChapterPayload {
        guard let facade else {
            throw NSError(
                domain: "io.legado.kmp.ios",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Reader.unavailable]
            )
        }
        return try await facade.saveChapterContentAsync(bookUrl: bookURL, chapterIndex: Int32(chapterIndex), content: content)
    }

    func saveEditedChapter(index: Int, expectedURL: String, content: String) async throws -> ReaderChapterPayload {
        try await contentEditingFacade().saveChapterContentCheckedAsync(
            bookUrl: bookURL, chapterIndex: Int32(index), expectedChapterUrl: expectedURL, content: content)
    }

    func renameEditedChapter(index: Int, expectedURL: String, title: String) async throws -> ReaderChapterPayload {
        try await contentEditingFacade().renameChapterTitleAsync(
            bookUrl: bookURL, chapterIndex: Int32(index), expectedChapterUrl: expectedURL, title: title)
    }

    func resetEditedChapter(index: Int, expectedURL: String) async throws -> ReaderChapterPayload {
        try await contentEditingFacade().resetChapterContentCheckedAsync(
            bookUrl: bookURL, chapterIndex: Int32(index), expectedChapterUrl: expectedURL)
    }

    private func contentEditingFacade() throws -> ReaderFacade {
        guard let facade else {
            throw NSError(
                domain: "io.legado.kmp.ios", code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Reader.unavailable])
        }
        return facade
    }

    /// F34: 获取章节原始内容（用于编辑）
    func getChapterRawContent(chapterIndex: Int) async throws -> String {
        guard let facade else {
            throw NSError(
                domain: "io.legado.kmp.ios",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Reader.unavailable]
            )
        }
        return try await facade.getChapterRawContentAsync(bookUrl: bookURL, chapterIndex: Int32(chapterIndex))
    }

    /// F42: 切换重新分段
    func toggleReSegment() async throws -> Book {
        guard let facade else {
            throw NSError(
                domain: "io.legado.kmp.ios",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Reader.unavailable]
            )
        }
        return try await facade.toggleReSegmentAsync(bookUrl: bookURL)
    }

    /// F47: 获取当前对此书生效的替换规则列表
    func getEffectiveReplaceRules() async throws -> [ReplaceRule] {
        guard let facade else {
            throw NSError(
                domain: "io.legado.kmp.ios",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Reader.unavailable]
            )
        }
        return try await facade.getEffectiveReplaceRulesAsync(bookUrl: bookURL)
    }

    /// F52: 对选中文本应用替换规则
    func applyReplaceRules(text: String) async throws -> String {
        guard let facade else {
            throw NSError(
                domain: "io.legado.kmp.ios",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Reader.unavailable]
            )
        }
        return try await facade.applyReplaceRulesAsync(bookUrl: bookURL, text: text)
    }

    /// F60: 全文搜索
    func searchInBook(keyword: String, onResult: @escaping (ContentSearchResult) -> Void) async throws {
        guard let facade else {
            throw NSError(
                domain: "io.legado.kmp.ios",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Reader.unavailable]
            )
        }
        try await facade.searchInBookAsync(bookUrl: bookURL, keyword: keyword, onResult: onResult)
    }

    func searchInBook(
        keyword: String,
        options: ReaderContentSearchOptions,
        onResult: @escaping (ContentSearchResult) -> Void
    ) async throws {
        guard let facade else {
            throw NSError(
                domain: "io.legado.kmp.ios", code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Reader.unavailable])
        }
        try await facade.searchInBookAsync(
            bookUrl: bookURL, keyword: keyword, replaceEnabled: options.replaceEnabled, onResult: onResult)
    }

    func syncProgress() async throws -> SyncProgressResult {
        try await syncClient.sync()
    }

    func setProgress(_ progress: BookProgress, expectedBook: Book? = nil) async throws -> ReaderChapterPayload? {
        let ticket = try chapterRequestGate.begin()
        defer { chapterRequestGate.finish(ticket) }
        // Drain the outgoing page before applying another reading position.
        try await progressQueue.flushForExit()
        try chapterRequestGate.check(ticket)
        let payload: ReaderChapterPayload?
        if let expectedBook {
            payload = try await syncClient.apply(progress, expected: expectedBook) { [chapterRequestGate] subscription in
                chapterRequestGate.register(subscription, for: ticket)
            }
        } else {
            payload = try await ticket.facade.setProgressAsync(bookUrl: ticket.bookURL, progress: progress)
        }
        try chapterRequestGate.check(ticket)
        return payload
    }

    func uploadCurrentProgress() async throws {
        try await syncClient.uploadCurrent()
    }

    func resolveBookForProgressSync() async throws -> Book { try await syncClient.snapshot() }

    @MainActor
    func makeProgressSyncPauseWork(expected: Book, enhanced: Bool) throws -> @MainActor () async throws -> Void {
        try syncClient.makePauseWork(expected: expected, enhanced: enhanced)
    }

    /// F46: 刷新章节目录（委托给 BookDetailFacade）
    @MainActor
    func refreshChapters() async throws -> BookDetailRefreshResult {
        try await catalogRefresh.refresh()
    }

    /// F159: 将书加入书架
    func addToBookshelf() async throws -> Book {
        guard let bookDetailFacade else {
            throw NSError(
                domain: "io.legado.kmp.ios",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Reader.unavailable]
            )
        }
        return try await bookDetailFacade.addToBookshelfAsync(bookUrl: bookURL)
    }

    /// F27: 创建换源搜索会话
    @MainActor
    func createSourceChangeSearchSession(
        onCandidate: @escaping (BookSourceChangeCandidate) -> Void,
        onProgress: @escaping (SourceChangeSearchProgress) -> Void,
        onFinished: @escaping () -> Void
    ) async throws -> SourceChangeSearchSession {
        try await sourceChangeClient.createSourceChangeSearchSession(
            onCandidate: onCandidate,
            onProgress: onProgress,
            onFinished: onFinished
        )
    }

    @MainActor
    func prepareSourceChange(candidateBookUrl: String, sourceUrl: String) async throws -> PreparedBookSourceChange {
        try await sourceChangeClient.prepareSourceChange(candidateBookUrl: candidateBookUrl, sourceUrl: sourceUrl)
    }

    @MainActor
    func commitSourceChange(_ prepared: PreparedBookSourceChange) async throws -> BookDetailRefreshResult {
        try await sourceChangeClient.commitSourceChange(prepared)
    }

    @MainActor
    func changeSource(candidateBookUrl: String, sourceUrl: String) async throws -> BookDetailRefreshResult {
        try await sourceChangeClient.changeSource(candidateBookUrl: candidateBookUrl, sourceUrl: sourceUrl)
    }

    @MainActor
    func loadChapterSourceToc(candidateBookUrl: String, sourceUrl: String, chapterIndex: Int) async throws
        -> ChapterSourceChangeToc
    {
        try await sourceChangeClient.loadChapterSourceToc(
            candidateBookUrl: candidateBookUrl,
            sourceUrl: sourceUrl,
            chapterIndex: chapterIndex
        )
    }

    @MainActor
    func replaceChapterContentFromSource(
        currentChapterIndex: Int,
        candidateBookUrl: String,
        sourceUrl: String,
        candidateChapterIndex: Int,
        willCommit: @MainActor () throws -> Void = {}
    ) async throws {
        try await sourceChangeClient.replaceChapterContentFromSource(
            currentChapterIndex: currentChapterIndex,
            candidateBookUrl: candidateBookUrl,
            sourceUrl: sourceUrl,
            candidateChapterIndex: candidateChapterIndex,
            willCommit: willCommit
        )
    }

    func executeSourceLogin(sourceUrl: String) async throws -> SourceLoginResult {
        try await executeLogin(sourceUrl: sourceUrl)
    }

    func completeEditorSourcePayload(payload: String, enabled: Bool) throws -> String {
        guard let sourceManagementFacade else {
            throw NSError(domain: "io.legado.kmp.ios", code: -1, userInfo: [NSLocalizedDescriptionKey: L10n.Reader.unavailable])
        }
        return try sourceManagementFacade.completeEditorSourcePayload(payload: payload, enabled: enabled)
    }

    func getSourceVariable(sourceUrl: String) async throws -> String? {
        guard let sourceManagementFacade else {
            throw NSError(domain: "io.legado.kmp.ios", code: -1, userInfo: [NSLocalizedDescriptionKey: L10n.Reader.unavailable])
        }
        return try await SharedAsync.optionalValue {
            sourceManagementFacade.getSourceVariable(sourceUrl: sourceUrl, completionHandler: $0)
        }
    }

    func setSourceVariable(sourceUrl: String, value: String) async throws {
        guard let sourceManagementFacade else {
            throw NSError(domain: "io.legado.kmp.ios", code: -1, userInfo: [NSLocalizedDescriptionKey: L10n.Reader.unavailable])
        }
        try await SharedAsync.void {
            sourceManagementFacade.setSourceVariable(sourceUrl: sourceUrl, value: value, completionHandler: $0)
        }
    }

    func executeLogin(sourceUrl: String) async throws -> SourceLoginResult {
        guard let sourceManagementFacade else {
            throw NSError(
                domain: "io.legado.kmp.ios",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Reader.unavailable]
            )
        }
        return try await sourceManagementFacade.executeLoginAsync(sourceUrl: sourceUrl)
    }

    func setSourceEnabled(sourceUrl: String, enabled: Bool) async throws {
        guard let sourceManagementFacade else {
            throw NSError(
                domain: "io.legado.kmp.ios",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Reader.unavailable]
            )
        }
        try await sourceManagementFacade.setEnabledAsync(sourceUrl: sourceUrl, enabled: enabled)
    }

    func exportSource(sourceUrl: String) async throws -> String {
        guard let sourceManagementFacade else {
            throw NSError(
                domain: "io.legado.kmp.ios",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Reader.unavailable]
            )
        }
        return try await sourceManagementFacade.exportSourceAsync(sourceUrl: sourceUrl)
    }

    func parseSourcePayload(payload: String) async throws -> [BookSource] {
        guard let sourceManagementFacade else {
            throw NSError(
                domain: "io.legado.kmp.ios",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Reader.unavailable]
            )
        }
        return try await sourceManagementFacade.parseSourcePayloadAsync(payload: payload)
    }

    func saveSource(source: BookSource) async throws -> BookSource {
        guard let sourceManagementFacade else {
            throw NSError(
                domain: "io.legado.kmp.ios",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Reader.unavailable]
            )
        }
        return try await sourceManagementFacade.saveSourceAsync(source: source)
    }

    func deleteSource(sourceUrl: String) async throws {
        guard let sourceManagementFacade else {
            throw NSError(
                domain: "io.legado.kmp.ios",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Reader.unavailable]
            )
        }
        try await sourceManagementFacade.deleteSourceAsync(sourceUrl: sourceUrl)
    }

    func clearSourceCookies(sourceUrl: String) async throws {
        guard let sourceManagementFacade else {
            throw NSError(
                domain: "io.legado.kmp.ios",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Reader.unavailable]
            )
        }
        try await sourceManagementFacade.clearSourceCookiesAsync(sourceUrl: sourceUrl)
    }

    @MainActor
    func isCurrentSourceMissing() async throws -> Bool {
        try await sourceChangeClient.isCurrentSourceMissing()
    }

    /// F125: 自动换源 — 搜索第一个可用候选源并切换
    /// 返回刷新结果表示换源成功，nil 表示未找到可用源
    @MainActor
    func autoChangeSource(chapterIndex: Int) async throws -> BookDetailRefreshResult? {
        try await sourceChangeClient.autoChangeSource(chapterIndex: chapterIndex)
    }

    /// F161: 设置漫画样式
    func setComicStyleIndex(_ index: Int) async throws {
        guard let settingsFacade else {
            throw NSError(domain: "io.legado.kmp.ios", code: -1, userInfo: [NSLocalizedDescriptionKey: L10n.Reader.unavailable])
        }
        try await settingsFacade.setComicStyleIndexAsync(index: Int32(index))
    }

    func setThemeMode(_ mode: ThemeMode) async throws {
        guard let settingsFacade else {
            throw NSError(domain: "io.legado.kmp.ios", code: -1, userInfo: [NSLocalizedDescriptionKey: L10n.Reader.unavailable])
        }
        try await settingsFacade.setThemeModeAsync(mode: mode)
    }

    func setReaderBrightness(value: Int, isNightTheme: Bool) async throws {
        guard let settingsFacade else {
            throw NSError(domain: "io.legado.kmp.ios", code: -1, userInfo: [NSLocalizedDescriptionKey: L10n.Reader.unavailable])
        }
        if isNightTheme {
            try await settingsFacade.setBrightnessNightAsync(value: Int32(value))
        } else {
            try await settingsFacade.setBrightnessDayAsync(value: Int32(value))
        }
    }

    func loadDictRules() async throws -> [DictRule] {
        guard let settingsFacade else {
            throw NSError(domain: "io.legado.kmp.ios", code: -1, userInfo: [NSLocalizedDescriptionKey: L10n.Reader.unavailable])
        }
        return try await settingsFacade.loadDictRulesAsync()
    }

    func isWebDavConfigured() async -> Bool {
        guard let settingsFacade else { return false }
        return await settingsFacade.isWebDavConfiguredAsync()
    }

    func getBookProgress(bookName: String, bookAuthor: String) async throws -> BookProgress? {
        let book = try await resolveCurrentBook()
        guard book.name == bookName, book.author == bookAuthor else { throw CancellationError() }
        return try await syncClient.read(book: book)
    }

    func uploadBookProgress(book: Book) async throws {
        try await syncClient.upload(book: book)
    }

    func markLoadedProgress(book: Book) {
        progressQueue.beginPresentation(bookURL: book.bookUrl)
    }

    func setAutoReadSpeed(value: Int32) async throws {
        guard let settingsFacade else {
            throw NSError(
                domain: "io.legado.kmp.ios",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Reader.unavailable]
            )
        }
        try await settingsFacade.setAutoReadSpeedAsync(value: value)
    }

    func setReaderRuntimeConfig(config: ReaderRuntimeConfig) async throws {
        guard let settingsFacade else {
            throw NSError(domain: "io.legado.kmp.ios", code: -1, userInfo: [NSLocalizedDescriptionKey: L10n.Reader.unavailable])
        }
        try await settingsFacade.setReaderRuntimeConfigAsync(config: config)
    }

    func startReadAloud(
        chapterIndex: Int,
        blocks: [ReaderContentBlock],
        startBlockIndex: Int,
        startTextOffset: Int,
        preferBackgroundPlayback: Bool,
        ttsEngine: String?,
        startPaused: Bool = false
    ) async throws {
        try await readAloudClient.startReadAloud(
            bookURL: bookURL, chapterIndex: chapterIndex, blocks: blocks, startBlockIndex: startBlockIndex,
            startTextOffset: startTextOffset, preferBackgroundPlayback: preferBackgroundPlayback,
            ttsEngine: ttsEngine, startPaused: startPaused)
    }

    func pauseReadAloud() async throws {
        try await readAloudClient.pauseReadAloud()
    }

    func resumeReadAloud() async throws {
        try await readAloudClient.resumeReadAloud()
    }

    func stopReadAloud() async throws {
        try await readAloudClient.stopReadAloud()
    }

    func skipReadAloudToPreviousBlock() async throws {
        try await readAloudClient.skipReadAloudToPreviousBlock()
    }

    func skipReadAloudToNextBlock() async throws {
        try await readAloudClient.skipReadAloudToNextBlock()
    }

    func updateReadAloudSpeechRate(followSystem: Bool, value: Float) async throws {
        try await readAloudClient.updateReadAloudSpeechRate(followSystem: followSystem, value: value)
    }

    func setReadAloudTimer(minutes: Int) async throws {
        try await readAloudClient.setReadAloudTimer(minutes: minutes)
    }

    func setReadAloudBackgroundPlayback(enabled: Bool) async throws {
        try await readAloudClient.setReadAloudBackgroundPlayback(enabled: enabled)
    }

    func advanceReadAloudToNextBlock() async throws {
        try await readAloudClient.advanceReadAloudToNextBlock()
    }

    func updateReadAloudCurrentRange(start: Int, end: Int) async throws {
        try await readAloudClient.updateReadAloudCurrentRange(start: start, end: end)
    }

    func updateReadAloudPlaybackState(isInBackground: Bool) async throws {
        try await readAloudClient.updateReadAloudPlaybackState(isInBackground: isInBackground)
    }

    func failReadAloud(message: String) async throws {
        try await readAloudClient.failReadAloud(message: message)
    }

    func stageReadingProgress(
        chapterIndex: Int,
        chapterTitle: String?,
        chapterPosition: Int,
        immediate: Bool
    ) {
        progressQueue.stage(
            .init(
                chapterIndex: chapterIndex,
                chapterTitle: chapterTitle,
                chapterPosition: chapterPosition
            ),
            immediate: immediate
        )
    }

    func flushReadingProgressNow() async {
        await progressQueue.flushNow()
    }

    func unbind() {
        bookBindingID = UUID()
        suspendChapterLoading()
        progressQueue.suspendPresentation()
        bindings.cancelAll()
    }

    @MainActor
    private func handleBook(_ book: Book?) {
        guard !catalogRefresh.isBlockingObservation else { return }
        let signature = book.map {
            [
                $0.bookUrl, $0.origin, String($0.durChapterIndex), String($0.durChapterPos), $0.durChapterTitle ?? "",
                $0.name, $0.author, $0.displayCoverUrl ?? "", $0.displayIntro ?? "", String($0.type),
                $0.tocUrl, String($0.config.reverseToc), String($0.durChapterTime),
            ].map { "\($0.utf8.count):\($0)" }.joined()
        }
        guard signature != lastBookSignature else { return }
        lastBookSignature = signature
        onBookChange?(book)
    }

    @MainActor
    private func handleChapters(_ chapters: [BookChapter]) {
        guard !catalogRefresh.isBlockingObservation else { return }
        let signature = ReaderCatalogSnapshot.signature(chapters)
        guard signature != lastChaptersSignature else { return }
        lastChaptersSignature = signature
        onChaptersChange?(chapters)
    }

    @MainActor
    private func handlePreferences(_ preferences: AppUiPreferences) {
        latestPreferences = preferences
        let key = ReaderPreferencesPresentationKey(preferences: preferences)
        guard key != lastPreferencesKey else { return }
        lastPreferencesKey = key
        onPreferencesChange?(preferences)
    }

    @MainActor
    private func handleRuntimeConfig(_ runtimeConfig: AppRuntimeConfig) {
        let signature = [
            "\(runtimeConfig.threadCount)",
            "\(runtimeConfig.preDownloadNum)",
            "\(runtimeConfig.syncBookProgress)", "\(runtimeConfig.syncBookProgressPlus)",
            runtimeConfig.webDavUrl ?? "", runtimeConfig.webDavAccount ?? "", runtimeConfig.webDavDir,
            runtimeConfig.webDavPassword ?? "",
            "\(runtimeConfig.precisionSearch)",
            "\(runtimeConfig.reader.brightnessDay)",
            "\(runtimeConfig.reader.brightnessNight)",
            "\(runtimeConfig.reader.pageAnimation)",
            "\(runtimeConfig.reader.autoReadSpeed)",
            "\(runtimeConfig.reader.ttsFollowSystemRate)",
            "\(runtimeConfig.reader.ttsSpeechRate)",
            "\(runtimeConfig.reader.ttsTimerMinutes)",
            runtimeConfig.reader.ttsVoiceIdentifier ?? "",
            "\(runtimeConfig.reader.shareLayout)",
            "\(runtimeConfig.reader.readStyleIndex)",
            "\(runtimeConfig.reader.comicStyleIndex)",
            "\(runtimeConfig.reader.textFullJustify)",
            "\(runtimeConfig.reader.textBottomJustify)",
            "\(runtimeConfig.reader.chineseMode)",
            "\(runtimeConfig.reader.useZhLayout)",
            "\(runtimeConfig.reader.readBodyToLh)",
            "\(runtimeConfig.reader.hideStatusBar)",
            "\(runtimeConfig.reader.hideNavigationBar)",
            "\(runtimeConfig.ignoreAudioFocus)",
            runtimeConfig.ttsEngine ?? "",
            "\(runtimeConfig.mediaButtonOnExit)",
            "\(runtimeConfig.readAloudByMediaButton)",
            "\(runtimeConfig.pauseReadAloudWhilePhoneCalls)",
            "\(runtimeConfig.streamReadAloudAudio)",
            "\(runtimeConfig.paddingDisplayCutouts)",
            "\(runtimeConfig.readBarStyleFollowPage)",
            "\(runtimeConfig.reader.tapZoneActions.topLeft)",
            "\(runtimeConfig.reader.tapZoneActions.topCenter)",
            "\(runtimeConfig.reader.tapZoneActions.topRight)",
            "\(runtimeConfig.reader.tapZoneActions.middleLeft)",
            "\(runtimeConfig.reader.tapZoneActions.middleCenter)",
            "\(runtimeConfig.reader.tapZoneActions.middleRight)",
            "\(runtimeConfig.reader.tapZoneActions.bottomLeft)",
            "\(runtimeConfig.reader.tapZoneActions.bottomCenter)",
            "\(runtimeConfig.reader.tapZoneActions.bottomRight)",
        ].joined(separator: "::")
        guard signature != lastRuntimeSignature else { return }
        lastRuntimeSignature = signature
        onRuntimeConfigChange?(runtimeConfig)
    }

    @MainActor
    private func handleReadAloudState(_ incomingState: ReadAloudState) {
        latestReadAloudState = incomingState
        let state = ReaderReadAloudStateSupport.state(incomingState, for: bookURL)
        let signature = [
            state.bookUrl ?? "",
            state.engine.name,
            state.status.name,
            "\(state.progress.chapterIndex)",
            "\(state.progress.blockIndex)",
            "\(state.progress.utteranceRangeStart)",
            "\(state.progress.utteranceRangeEnd)",
            "\(state.progress.isInBackground)",
            "\(state.progress.speechRate)",
            "\(state.progress.remainingTimerMinutes)",
            "\(state.isSupported)",
            "\(state.isBackgroundPlaybackEnabled)",
            state.message ?? "",
        ].joined(separator: "::")
        guard signature != lastReadAloudSignature else { return }
        lastReadAloudSignature = signature
        onReadAloudStateChange?(state)
    }
}
