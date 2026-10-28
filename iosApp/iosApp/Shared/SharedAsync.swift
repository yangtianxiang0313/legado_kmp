import Foundation
import shared

enum SharedAsync {
    static func value<T>(_ block: (@escaping @Sendable (T?, Error?) -> Void) -> Void) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            block { value, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let value {
                    continuation.resume(returning: value)
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "io.legado.kmp.ios",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: L10n.Shared.emptyValue]
                    ))
                }
            }
        }
    }

    static func optionalValue<T>(_ block: (@escaping @Sendable (T?, Error?) -> Void) -> Void) async throws -> T? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T?, Error>) in
            block { value, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: value)
                }
            }
        }
    }

    static func void(_ block: (@escaping @Sendable (Error?) -> Void) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            block { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

extension RemoteBookFacade {
    func listAsync(path: String?) async throws -> [RemoteBook] {
        try await SharedAsync.value { completion in
            list(path: path, completionHandler: completion)
        }
    }

    func downloadAsync(remoteBook: RemoteBook) async throws -> KotlinByteArray {
        try await SharedAsync.value { completion in
            download(remoteBook: remoteBook, completionHandler: completion)
        }
    }

    func downloadAndImportAsync(remoteBook: RemoteBook, groupId: Int64 = 0) async throws -> Book {
        try await SharedAsync.value { completion in
            downloadAndImport(remoteBook: remoteBook, groupId: groupId, completionHandler: completion)
        }
    }

    func uploadLocalBookAsync(path: String) async throws -> RemoteBook {
        try await SharedAsync.value { completion in
            uploadLocalBook(path: path, completionHandler: completion)
        }
    }

    func uploadShelfBookAsync(bookUrl: String) async throws -> RemoteBook {
        try await SharedAsync.value { completion in
            uploadShelfBook(bookUrl: bookUrl, completionHandler: completion)
        }
    }

    func deleteAsync(remoteBook: RemoteBook) async throws {
        try await SharedAsync.void { completion in
            delete(remoteBook: remoteBook, completionHandler: completion)
        }
    }
}

extension LogFacade {
    func loadEntriesAsync() async throws -> [AppLogEntry] {
        try await SharedAsync.value { completion in
            loadEntries(completionHandler: completion)
        }
    }

    func exportMarkdownAsync() async throws -> String {
        try await SharedAsync.value { completion in
            exportMarkdown(completionHandler: completion)
        }
    }

    func clearAsync() async throws {
        try await SharedAsync.void { completion in
            clear(completionHandler: completion)
        }
    }
}

extension SearchFacade {
    func searchAsync(sourceUrl: String, keyword: String) async throws -> [SearchBook] {
        try await SharedAsync.value { completion in
            self.search(sourceUrl: sourceUrl, keyword: keyword, completionHandler: completion)
        }
    }

    func loadCachedResultsAsync() async throws -> [SearchBook] {
        try await SharedAsync.value { completion in
            self.loadCachedResults(completionHandler: completion)
        }
    }

    func loadSearchHistoryAsync(keyword: String = "") async throws -> [SearchKeyword] {
        try await SharedAsync.value { completion in
            self.loadSearchHistory(keyword: keyword, completionHandler: completion)
        }
    }

    func startSearchAsync(searchScope: SearchScope, keyword: String, page: Int32 = 1) async throws {
        try await SharedAsync.void { completion in
            self.startSearch(
                searchScope: searchScope,
                keyword: keyword,
                page: page,
                completionHandler: completion
            )
        }
    }

    func loadNextPageAsync() async throws {
        try await SharedAsync.void { completion in
            self.loadNextPage(completionHandler: completion)
        }
    }

    func pauseSearchAsync() async throws {
        self.pauseSearch()
    }

    func resumeSearchAsync() async throws {
        self.resumeSearch()
    }

    func clearSearchHistoryAsync() async throws {
        try await SharedAsync.void { completion in
            self.clearSearchHistory(completionHandler: completion)
        }
    }

    func deleteSearchHistoryAsync(word: String) async throws {
        try await SharedAsync.void { completion in
            self.deleteSearchHistory(word: word, completionHandler: completion)
        }
    }
}

extension DiscoveryFacade {
    func loadExploreKindsAsync(sourceUrl: String, forceRefresh: Bool = false) async throws -> [ExploreKind] {
        try await SharedAsync.value { completion in
            self.loadExploreKinds(sourceUrl: sourceUrl, forceRefresh: forceRefresh, completionHandler: completion)
        }
    }

    func loadExploreBooksAsync(sourceUrl: String, exploreUrl: String, page: Int32 = 1) async throws -> [SearchBook] {
        try await SharedAsync.value { completion in
            self.loadExploreBooks(
                sourceUrl: sourceUrl,
                exploreUrl: exploreUrl,
                page: page,
                completionHandler: completion
            )
        }
    }
}

extension SourceManagementFacade {
    func getAllSourcesAsync() async throws -> [BookSource] {
        try await SharedAsync.value { completion in
            getAllSources(completionHandler: completion)
        }
    }

    func getSourceAsync(sourceUrl: String) async throws -> BookSource? {
        try await SharedAsync.optionalValue { completion in
            getSource(sourceUrl: sourceUrl, completionHandler: completion)
        }
    }

    func searchSourcesAsync(keyword: String) async throws -> [BookSource] {
        try await SharedAsync.value { completion in
            searchSources(keyword: keyword, completionHandler: completion)
        }
    }

    func searchSourcesAsync(keyword: String, group: String?) async throws -> [BookSource] {
        try await SharedAsync.value { completion in
            searchSources(keyword: keyword, group: group, completionHandler: completion)
        }
    }

    func importSourcesAsync(payload: String) async throws -> SourceImportResult {
        try await SharedAsync.value { completion in
            importSources(payload: payload, completionHandler: completion)
        }
    }

    func importSourcesIfEmptyAsync(payload: String) async throws -> SourceImportResult {
        try await SharedAsync.value { completion in
            importSourcesIfEmpty(payload: payload, completionHandler: completion)
        }
    }

    func importSourcesByUrlAsync(url: String) async throws -> SourceImportResult {
        try await SharedAsync.value { completion in
            importSourcesByUrl(url: url, completionHandler: completion)
        }
    }

    func saveSourceAsync(source: BookSource) async throws -> BookSource {
        try await SharedAsync.value { completion in
            saveSource(source: source, completionHandler: completion)
        }
    }

    func setEnabledAsync(sourceUrl: String, enabled: Bool) async throws {
        try await SharedAsync.void { completion in
            setEnabled(sourceUrl: sourceUrl, enabled: enabled, completionHandler: completion)
        }
    }

    func setEnabledExploreAsync(sourceUrl: String, enabled: Bool) async throws {
        try await SharedAsync.void { completion in
            setEnabledExplore(sourceUrl: sourceUrl, enabled: enabled, completionHandler: completion)
        }
    }

    func updateSourceOrderAsync(sourceUrl: String, order: Int32) async throws {
        try await SharedAsync.void { completion in
            updateSourceOrder(sourceUrl: sourceUrl, order: order, completionHandler: completion)
        }
    }

    func updateSourceOrdersAsync(sources: [BookSource]) async throws {
        try await SharedAsync.void { completion in
            updateSourceOrders(sources: sources, completionHandler: completion)
        }
    }

    func updateSourceGroupAsync(sourceUrl: String, group: String?) async throws {
        try await SharedAsync.void { completion in
            updateSourceGroup(sourceUrl: sourceUrl, group: group, completionHandler: completion)
        }
    }

    func addSourcesToGroupAsync(sourceUrls: [String], group: String) async throws -> [BookSource] {
        try await SharedAsync.value { completion in
            addSourcesToGroup(sourceUrls: sourceUrls, group: group, completionHandler: completion)
        }
    }

    func addGroupAsync(group: String) async throws -> [BookSource] {
        try await SharedAsync.value { completion in
            addGroup(group: group, completionHandler: completion)
        }
    }

    func renameGroupAsync(oldGroup: String, newGroup: String?) async throws -> [BookSource] {
        try await SharedAsync.value { completion in
            renameGroup(oldGroup: oldGroup, newGroup: newGroup, completionHandler: completion)
        }
    }

    func deleteGroupAsync(group: String) async throws -> [BookSource] {
        try await SharedAsync.value { completion in
            deleteGroup(group: group, completionHandler: completion)
        }
    }

    func removeSourcesFromGroupAsync(sourceUrls: [String], group: String) async throws -> [BookSource] {
        try await SharedAsync.value { completion in
            removeSourcesFromGroup(sourceUrls: sourceUrls, group: group, completionHandler: completion)
        }
    }

    func deleteSourceAsync(sourceUrl: String) async throws {
        try await SharedAsync.void { completion in
            deleteSource(sourceUrl: sourceUrl, completionHandler: completion)
        }
    }

    func deleteSourcesAsync(sourceUrls: [String]) async throws {
        try await SharedAsync.void { completion in
            deleteSources(sourceUrls: sourceUrls, completionHandler: completion)
        }
    }

    func exportSourcesAsync(sourceUrls: [String]) async throws -> String {
        try await SharedAsync.value { completion in
            exportSources(sourceUrls: sourceUrls, completionHandler: completion)
        }
    }

    func exportSourceAsync(sourceUrl: String) async throws -> String {
        try await SharedAsync.value { completion in
            exportSource(sourceUrl: sourceUrl, completionHandler: completion)
        }
    }

    func parseSourcePayloadAsync(payload: String) async throws -> [BookSource] {
        try await SharedAsync.value { completion in
            parseSourcePayload(payload: payload, completionHandler: completion)
        }
    }

    func executeLoginAsync(sourceUrl: String) async throws -> SourceLoginResult {
        try await SharedAsync.value { completion in
            executeLogin(sourceUrl: sourceUrl, completionHandler: completion)
        }
    }

    func clearSourceCookiesAsync(sourceUrl: String) async throws {
        try await SharedAsync.void { completion in
            clearSourceCookies(sourceUrl: sourceUrl, completionHandler: completion)
        }
    }
}

extension BookSourceDebugFacade {
    func debugSourceAsync(sourceUrl: String, keyword: String = "") async throws -> BookSourceDebugReport {
        try await SharedAsync.value { completion in
            debugSource(sourceUrl: sourceUrl, keyword: keyword, completionHandler: completion)
        }
    }

    func checkSourceAsync(sourceUrl: String, persist: Bool = false) async throws -> BookSourceCheckReport {
        try await SharedAsync.value { completion in
            checkSource(sourceUrl: sourceUrl, persist: persist, completionHandler: completion)
        }
    }
}

extension BookDetailFacade {
    func resolveBookAsync(bookUrl: String) async throws -> Book? {
        try await SharedAsync.optionalValue { completion in
            resolveBook(bookUrl: bookUrl, completionHandler: completion)
        }
    }

    func refreshInfoAsync(bookUrl: String) async throws -> Book {
        try await SharedAsync.value { completion in
            refreshInfo(bookUrl: bookUrl, completionHandler: completion)
        }
    }

    func refreshChaptersAsync(bookUrl: String) async throws -> BookDetailRefreshResult {
        try await SharedAsync.value { completion in
            refreshChapters(bookUrl: bookUrl, completionHandler: completion)
        }
    }

    func preloadChaptersAsync(bookUrl: String) async throws -> BookDetailRefreshResult {
        try await SharedAsync.value { completion in
            preloadChapters(bookUrl: bookUrl, completionHandler: completion)
        }
    }

    func addToBookshelfAsync(bookUrl: String) async throws -> Book {
        try await SharedAsync.value { completion in
            addToBookshelf(bookUrl: bookUrl, completionHandler: completion)
        }
    }

    func removeFromBookshelfAsync(bookUrl: String) async throws {
        try await SharedAsync.void { completion in
            removeFromBookshelf(bookUrl: bookUrl, completionHandler: completion)
        }
    }

    func updateGroupAsync(bookUrl: String, groupId: Int64) async throws -> Book {
        try await SharedAsync.value { completion in
            updateGroup(bookUrl: bookUrl, groupId: groupId, completionHandler: completion)
        }
    }

    func loadSourceChangeCandidatesAsync(bookUrl: String) async throws -> [BookSourceChangeCandidate] {
        try await SharedAsync.value { completion in
            loadSourceChangeCandidates(bookUrl: bookUrl, completionHandler: completion)
        }
    }

    func createSourceChangeSearchSessionAsync(
        bookUrl: String,
        fromReader: Bool = false,
        onCandidate: @escaping (BookSourceChangeCandidate) -> Void,
        onProgress: @escaping (SourceChangeSearchProgress) -> Void,
        onFinished: @escaping () -> Void
    ) async throws -> SourceChangeSearchSession {
        try await SharedAsync.value { completion in
            createSourceChangeSearchSession(
                bookUrl: bookUrl,
                onCandidate: onCandidate,
                onProgress: onProgress,
                onFinished: onFinished,
                fromReader: fromReader,
                completionHandler: completion
            )
        }
    }

    func changeSourceAsync(bookUrl: String, candidateBookUrl: String, sourceUrl: String) async throws -> BookDetailRefreshResult {
        try await SharedAsync.value { completion in
            changeSource(bookUrl: bookUrl, candidateBookUrl: candidateBookUrl, sourceUrl: sourceUrl, completionHandler: completion)
        }
    }

    func autoChangeSourceAsync(bookUrl: String, chapterIndex: Int32) async throws -> BookDetailRefreshResult? {
        try await SharedAsync.optionalValue { completion in
            autoChangeSource(bookUrl: bookUrl, chapterIndex: chapterIndex, completionHandler: completion)
        }
    }

    func loadChapterSourceTocAsync(
        bookUrl: String,
        candidateBookUrl: String,
        sourceUrl: String,
        currentChapterIndex: Int32
    ) async throws -> ChapterSourceChangeToc {
        try await SharedAsync.value { completion in
            loadChapterSourceToc(
                bookUrl: bookUrl,
                candidateBookUrl: candidateBookUrl,
                sourceUrl: sourceUrl,
                currentChapterIndex: currentChapterIndex,
                completionHandler: completion
            )
        }
    }

    func replaceChapterContentFromSourceAsync(
        bookUrl: String,
        currentChapterIndex: Int32,
        candidateBookUrl: String,
        sourceUrl: String,
        candidateChapterIndex: Int32
    ) async throws -> String {
        try await SharedAsync.value { completion in
            replaceChapterContentFromSource(
                bookUrl: bookUrl,
                currentChapterIndex: currentChapterIndex,
                candidateBookUrl: candidateBookUrl,
                sourceUrl: sourceUrl,
                candidateChapterIndex: candidateChapterIndex,
                completionHandler: completion
            )
        }
    }

    // F24 置顶书籍
    func pinToTopAsync(bookUrl: String) async throws -> Book {
        try await SharedAsync.value { completion in
            pinToTop(bookUrl: bookUrl, completionHandler: completion)
        }
    }

    // F29 切换允许更新
    func toggleCanUpdateAsync(bookUrl: String) async throws -> Book {
        try await SharedAsync.value { completion in
            toggleCanUpdate(bookUrl: bookUrl, completionHandler: completion)
        }
    }

    func setPageAnimationAsync(bookUrl: String, pageAnimation: Int32) async throws -> Book {
        try await SharedAsync.value { completion in
            setPageAnimation(bookUrl: bookUrl, pageAnimation: pageAnimation, completionHandler: completion)
        }
    }

    // F31 清除缓存
    func clearCacheAsync(bookUrl: String) async throws {
        try await SharedAsync.void { completion in
            clearCache(bookUrl: bookUrl, completionHandler: completion)
        }
    }

    // F20/F41-F49 编辑书籍信息
    func updateBookInfoAsync(bookUrl: String, name: String?, author: String?, coverUrl: String?, intro: String?) async throws -> Book {
        try await SharedAsync.value { completion in
            updateBookInfo(bookUrl: bookUrl, name: name, author: author, coverUrl: coverUrl, intro: intro, completionHandler: completion)
        }
    }

    func saveEditedBookInfoAsync(
        bookUrl: String, name: String, author: String, coverUrl: String, intro: String, bookType: Int32
    ) async throws -> Book {
        try await SharedAsync.value { completion in
            saveEditedBookInfo(
                bookUrl: bookUrl, name: name, author: author, coverUrl: coverUrl, intro: intro,
                bookType: bookType, completionHandler: completion)
        }
    }

    // F72-F75 封面搜索
    func createCoverSearchSessionAsync(
        bookUrl: String,
        onResult: @escaping (CoverSearchResult) -> Void,
        onProgress: @escaping (CoverSearchProgress) -> Void,
        onFinished: @escaping () -> Void
    ) async throws -> CoverSearchSession {
        try await SharedAsync.value { completion in
            createCoverSearchSession(
                bookUrl: bookUrl,
                onResult: onResult,
                onProgress: onProgress,
                onFinished: onFinished,
                completionHandler: completion
            )
        }
    }
}

extension BookImageFacade {
    func loadSearchCoverBase64Async(candidate: SearchBook) async throws -> String? {
        try await SharedAsync.optionalValue { completion in
            loadSearchCoverBase64(candidate: candidate, completionHandler: completion)
        }
    }

    func loadBookCoverBase64Async(bookUrl: String) async throws -> String? {
        try await SharedAsync.optionalValue { completion in
            loadBookCoverBase64(bookUrl: bookUrl, useDefaultCover: false, loadOnlyWifi: false, completionHandler: completion)
        }
    }

    func loadBookImageBase64Async(bookUrl: String, imageUrl: String, isCover: Bool) async throws -> String? {
        try await SharedAsync.optionalValue { completion in
            loadBookImageBase64(bookUrl: bookUrl, imageUrl: imageUrl, isCover: isCover, completionHandler: completion)
        }
    }

    func refreshBookImageBase64Async(bookUrl: String, imageUrl: String, isCover: Bool) async throws -> String? {
        try await SharedAsync.optionalValue { completion in
            refreshBookImageBase64(bookUrl: bookUrl, imageUrl: imageUrl, isCover: isCover, completionHandler: completion)
        }
    }
}

extension ReaderFacade {
    func loadChapterAsync(bookUrl: String, chapterIndex: Int32) async throws -> ReaderChapterPayload {
        try await SharedAsync.value { completion in
            loadChapter(bookUrl: bookUrl, chapterIndex: chapterIndex, completionHandler: completion)
        }
    }

    func peekChapterAsync(bookUrl: String, chapterIndex: Int32) async throws -> ReaderChapterPayload {
        try await SharedAsync.value { completion in
            peekChapter(bookUrl: bookUrl, chapterIndex: chapterIndex, completionHandler: completion)
        }
    }

    func loadChapterListStateAsync(bookUrl: String) async throws -> [ReaderChapterListItem] {
        try await SharedAsync.value { completion in
            loadChapterListState(bookUrl: bookUrl, completionHandler: completion)
        }
    }

    func preloadAdjacentChaptersAsync(bookUrl: String, chapterIndex: Int32) async throws {
        try await SharedAsync.void { completion in
            preloadAdjacentChapters(
                bookUrl: bookUrl,
                chapterIndex: chapterIndex,
                preDownloadNum: -1,
                completionHandler: completion
            )
        }
    }

    func onPageChangedAsync(bookUrl: String) async throws {
        try await SharedAsync.void { completion in
            onPageChanged(bookUrl: bookUrl, completionHandler: completion)
        }
    }

    func refreshChapterContentAsync(bookUrl: String, chapterIndex: Int32) async throws -> ReaderChapterPayload {
        try await SharedAsync.value { completion in
            refreshChapterContent(
                bookUrl: bookUrl,
                chapterIndex: chapterIndex,
                completionHandler: completion
            )
        }
    }

    func refreshChapterContentFromIndexAsync(bookUrl: String, fromIndex: Int32) async throws -> ReaderChapterPayload {
        try await SharedAsync.value { completion in
            refreshChapterContentFromIndex(
                bookUrl: bookUrl,
                fromIndex: fromIndex,
                completionHandler: completion
            )
        }
    }

    func refreshAllChapterContentAsync(bookUrl: String, currentIndex: Int32) async throws -> ReaderChapterPayload {
        try await SharedAsync.value { completion in
            refreshAllChapterContent(
                bookUrl: bookUrl,
                currentIndex: currentIndex,
                completionHandler: completion
            )
        }
    }

    func paginateChapterAsync(
        chapterIndex: Int32,
        chapterTitle: String,
        content: String,
        style: ReaderStylePreferences,
        runtime: ReaderRuntimeConfig,
        viewport: ReaderViewport,
        imageStyle: String?
    ) async throws -> ReaderChapterLayout {
        try await SharedAsync.value { completion in
            paginateChapter(
                chapterIndex: chapterIndex,
                chapterTitle: chapterTitle,
                content: content,
                style: style,
                runtime: runtime,
                viewport: viewport,
                imageStyle: imageStyle,
                completionHandler: completion
            )
        }
    }

    func updateReadingProgressAsync(bookUrl: String, chapterIndex: Int32, chapterTitle: String?, chapterPosition: Int32) async throws {
        try await SharedAsync.void { completion in
            updateReadingProgress(
                bookUrl: bookUrl,
                chapterIndex: chapterIndex,
                chapterTitle: chapterTitle,
                chapterPosition: chapterPosition,
                completionHandler: completion
            )
        }
    }

    func addBookmarkAsync(bookUrl: String, chapterIndex: Int32, chapterPosition: Int32, pageText: String) async throws {
        try await SharedAsync.void { completion in
            addBookmark(
                bookUrl: bookUrl,
                chapterIndex: chapterIndex,
                chapterPosition: chapterPosition,
                pageText: pageText,
                completionHandler: completion
            )
        }
    }

    func setCharsetAsync(bookUrl: String, charset: String) async throws -> Book {
        try await SharedAsync.value { completion in
            setCharset(bookUrl: bookUrl, charset: charset, completionHandler: completion)
        }
    }

    func toggleReplaceRuleAsync(bookUrl: String) async throws -> Book {
        try await SharedAsync.value { completion in
            toggleReplaceRule(bookUrl: bookUrl, completionHandler: completion)
        }
    }

    func toggleDelTagAsync(bookUrl: String, tag: Int64) async throws -> Book {
        try await SharedAsync.value { completion in
            toggleDelTag(bookUrl: bookUrl, tag: tag, completionHandler: completion)
        }
    }

    func setRemoveSameTitleAsync(bookUrl: String, chapterIndex: Int32, removeSameTitle: Bool) async throws {
        try await SharedAsync.void { completion in
            setRemoveSameTitle(
                bookUrl: bookUrl,
                chapterIndex: chapterIndex,
                removeSameTitle: removeSameTitle,
                completionHandler: completion
            )
        }
    }

    func setImageStyleAsync(bookUrl: String, imageStyle: String) async throws -> Book {
        try await SharedAsync.value { completion in
            setImageStyle(bookUrl: bookUrl, imageStyle: imageStyle, completionHandler: completion)
        }
    }

    func getBookmarksAsync(bookUrl: String) async throws -> [Bookmark] {
        try await SharedAsync.value { completion in
            getBookmarks(bookUrl: bookUrl, completionHandler: completion)
        }
    }

    func deleteBookmarkAsync(bookmarkTime: Int64) async throws {
        try await SharedAsync.void { completion in
            deleteBookmark(bookmarkTime: bookmarkTime, completionHandler: completion)
        }
    }

    func requestPayActionAsync(bookUrl: String, chapterIndex: Int32) async throws -> String {
        try await SharedAsync.value { completion in
            requestPayAction(bookUrl: bookUrl, chapterIndex: chapterIndex, completionHandler: completion)
        }
    }

    func reverseContentAsync(bookUrl: String, chapterIndex: Int32) async throws -> ReaderChapterPayload {
        try await SharedAsync.value { completion in
            reverseContent(bookUrl: bookUrl, chapterIndex: chapterIndex, completionHandler: completion)
        }
    }

    func getEffectiveReplaceRulesAsync(bookUrl: String) async throws -> [ReplaceRule] {
        try await SharedAsync.value { completion in
            getEffectiveReplaceRules(bookUrl: bookUrl, completionHandler: completion)
        }
    }

    func applyReplaceRulesAsync(bookUrl: String, text: String) async throws -> String {
        try await SharedAsync.value { completion in
            applyReplaceRules(bookUrl: bookUrl, text: text, completionHandler: completion)
        }
    }

    func saveChapterContentAsync(bookUrl: String, chapterIndex: Int32, content: String) async throws -> ReaderChapterPayload {
        try await SharedAsync.value { completion in
            saveChapterContent(bookUrl: bookUrl, chapterIndex: chapterIndex, content: content, completionHandler: completion)
        }
    }

    func toggleReSegmentAsync(bookUrl: String) async throws -> Book {
        try await SharedAsync.value { completion in
            toggleReSegment(bookUrl: bookUrl, completionHandler: completion)
        }
    }

    func getChapterRawContentAsync(bookUrl: String, chapterIndex: Int32) async throws -> String {
        try await SharedAsync.value { completion in
            getChapterRawContent(bookUrl: bookUrl, chapterIndex: chapterIndex, completionHandler: completion)
        }
    }

    func searchInBookAsync(
        bookUrl: String,
        keyword: String,
        onResult: @escaping (ContentSearchResult) -> Void
    ) async throws {
        try await SharedAsync.void { completion in
            searchInBook(
                bookUrl: bookUrl,
                keyword: keyword,
                onResult: onResult,
                onFinished: {},
                completionHandler: completion
            )
        }
    }

    func searchInBookAsync(
        bookUrl: String,
        keyword: String,
        replaceEnabled: Bool,
        onResult: @escaping (ContentSearchResult) -> Void
    ) async throws {
        let _: Bool = try await SharedCancellableAsync.value { completion in
            searchInBookWithOptionsRequest(
                bookUrl: bookUrl,
                keyword: keyword,
                replaceEnabled: replaceEnabled,
                onResult: onResult
            ) { result in
                if result.isCancelled {
                    completion(nil, CancellationError())
                } else if result.errorCode != nil || result.errorMessage != nil {
                    var userInfo: [String: Any] = [
                        NSLocalizedDescriptionKey: result.errorMessage ?? result.errorCode ?? L10n.Shared.emptyValue
                    ]
                    if let code = result.errorCode { userInfo["errorCode"] = code }
                    if let message = result.errorMessage { userInfo["errorMessage"] = message }
                    completion(
                        nil,
                        NSError(
                            domain: "io.legado.kmp.ios", code: -1, userInfo: userInfo))
                } else {
                    completion(true, nil)
                }
            }
        }
    }

    func syncProgressAsync(bookUrl: String) async throws -> SyncProgressResult {
        try await SharedAsync.value { completion in
            syncProgress(bookUrl: bookUrl, completionHandler: completion)
        }
    }

    func setProgressAsync(bookUrl: String, progress: BookProgress) async throws -> ReaderChapterPayload? {
        try await SharedAsync.optionalValue { completion in
            setProgress(bookUrl: bookUrl, progress: progress, completionHandler: completion)
        }
    }
}

extension RssFacade {
    func loadSortsAsync(source: RssSource, forceRefresh: Bool = false) async throws -> [KotlinPair<NSString, NSString>] {
        try await SharedAsync.value { completion in
            self.loadSorts(source: source, forceRefresh: forceRefresh, completionHandler: completion)
        }
    }

    func loadArticlesAsync(
        sortName: String,
        sortUrl: String,
        source: RssSource,
        page: Int32 = 1
    ) async throws -> RssArticlesPayload {
        try await SharedAsync.value { completion in
            self.loadArticles(sortName: sortName, sortUrl: sortUrl, source: source, page: page, completionHandler: completion)
        }
    }

    func loadContentAsync(article: RssArticle, source: RssSource) async throws -> String {
        try await SharedAsync.value { completion in
            self.loadContent(article: article, source: source, completionHandler: completion)
        }
    }

    func toggleFavoriteAsync(article: RssArticle) async throws -> Bool {
        let result: KotlinBoolean = try await SharedAsync.value { completion in
            self.toggleFavorite(article: article, completionHandler: completion)
        }
        return result.boolValue
    }

    func clearReadRecordsAsync() async throws {
        try await SharedAsync.void { completion in
            self.clearReadRecords(completionHandler: completion)
        }
    }

    func updateFavoriteAsync(star: RssStar) async throws {
        try await SharedAsync.void { completion in
            self.updateFavorite(star: star, completionHandler: completion)
        }
    }

    // MARK: - RSS Source CRUD

    func getAllSourcesAsync() async throws -> [RssSource] {
        try await SharedAsync.value { completion in
            self.getAllSources(completionHandler: completion)
        }
    }

    func getSourceAsync(sourceUrl: String) async throws -> RssSource? {
        try await SharedAsync.optionalValue { completion in
            self.getSource(sourceUrl: sourceUrl, completionHandler: completion)
        }
    }

    func searchSourcesAsync(keyword: String) async throws -> [RssSource] {
        try await SharedAsync.value { completion in
            self.searchSources(keyword: keyword, completionHandler: completion)
        }
    }

    func setRssSourceEnabledAsync(sourceUrl: String, enabled: Bool) async throws {
        try await SharedAsync.void { completion in
            self.setRssSourceEnabled(sourceUrl: sourceUrl, enabled: enabled, completionHandler: completion)
        }
    }

    func saveRssSourceAsync(source: RssSource) async throws -> RssSource {
        try await SharedAsync.value { completion in
            self.saveRssSource(source: source, completionHandler: completion)
        }
    }

    func deleteRssSourceAsync(sourceUrl: String) async throws {
        try await SharedAsync.void { completion in
            self.deleteRssSource(sourceUrl: sourceUrl, completionHandler: completion)
        }
    }

    func deleteRssSourcesAsync(sourceUrls: [String]) async throws {
        try await SharedAsync.void { completion in
            self.deleteRssSources(sourceUrls: sourceUrls, completionHandler: completion)
        }
    }

    func addRssSourcesToGroupAsync(sourceUrls: [String], group: String) async throws -> Int32 {
        let result: KotlinInt = try await SharedAsync.value { completion in
            self.addRssSourcesToGroup(sourceUrls: sourceUrls, group: group, completionHandler: completion)
        }
        return result.int32Value
    }

    func renameRssSourceGroupAsync(oldName: String, newName: String) async throws -> Int32 {
        let result: KotlinInt = try await SharedAsync.value { completion in
            self.renameRssSourceGroup(oldName: oldName, newName: newName, completionHandler: completion)
        }
        return result.int32Value
    }

    func deleteRssSourceGroupAsync(group: String) async throws -> Int32 {
        let result: KotlinInt = try await SharedAsync.value { completion in
            self.deleteRssSourceGroup(group: group, completionHandler: completion)
        }
        return result.int32Value
    }

    func importRssSourcesAsync(payload: String) async throws -> Int32 {
        let result: KotlinInt = try await SharedAsync.value { completion in
            self.importRssSources(payload: payload, completionHandler: completion)
        }
        return result.int32Value
    }

    func exportRssSourcesAsync(sourceUrls: [String]) async throws -> String {
        try await SharedAsync.value { completion in
            self.exportRssSources(sourceUrls: sourceUrls, completionHandler: completion)
        }
    }
}

extension RuntimeFacade {
    func startReadAloudAsync(request: ReadAloudRequest) async throws {
        try await SharedAsync.void { completion in
            startReadAloud(request: request, completionHandler: completion)
        }
    }

    func pauseReadAloudAsync() async throws {
        try await SharedAsync.void { completion in
            pauseReadAloud(completionHandler: completion)
        }
    }

    func resumeReadAloudAsync() async throws {
        try await SharedAsync.void { completion in
            resumeReadAloud(completionHandler: completion)
        }
    }

    func stopReadAloudAsync() async throws {
        try await SharedAsync.void { completion in
            stopReadAloud(completionHandler: completion)
        }
    }

    func skipReadAloudToPreviousBlockAsync() async throws {
        try await SharedAsync.void { completion in
            skipReadAloudToPreviousBlock(completionHandler: completion)
        }
    }

    func skipReadAloudToNextBlockAsync() async throws {
        try await SharedAsync.void { completion in
            skipReadAloudToNextBlock(completionHandler: completion)
        }
    }

    func updateReadAloudSpeechRateAsync(setting: ReadAloudSpeechRateSetting) async throws {
        try await SharedAsync.void { completion in
            updateReadAloudSpeechRate(setting: setting, completionHandler: completion)
        }
    }

    func setReadAloudTimerAsync(minutes: Int32) async throws {
        try await SharedAsync.void { completion in
            setReadAloudTimer(minutes: minutes, completionHandler: completion)
        }
    }

    func setReadAloudBackgroundPlaybackAsync(enabled: Bool) async throws {
        try await SharedAsync.void { completion in
            setReadAloudBackgroundPlayback(enabled: enabled, completionHandler: completion)
        }
    }

    func advanceReadAloudToNextBlockAsync() async throws {
        try await SharedAsync.void { completion in
            advanceReadAloudToNextBlock(completionHandler: completion)
        }
    }

    func updateReadAloudCurrentRangeAsync(start: Int32, end: Int32) async throws {
        try await SharedAsync.void { completion in
            updateReadAloudCurrentRange(start: start, end: end, completionHandler: completion)
        }
    }

    func updateReadAloudPlaybackStateAsync(isInBackground: Bool) async throws {
        try await SharedAsync.void { completion in
            updateReadAloudPlaybackState(isInBackground: isInBackground, completionHandler: completion)
        }
    }

    func failReadAloudAsync(message: String) async throws {
        try await SharedAsync.void { completion in
            failReadAloud(message: message, completionHandler: completion)
        }
    }

    func startSourceCheckAsync() async throws {
        try await SharedAsync.void { completion in
            startSourceCheck(completionHandler: completion)
        }
    }

    func pauseSourceCheckAsync() async throws {
        try await SharedAsync.void { completion in
            pauseSourceCheck(completionHandler: completion)
        }
    }

    func resumeSourceCheckAsync() async throws {
        try await SharedAsync.void { completion in
            resumeSourceCheck(completionHandler: completion)
        }
    }

    func cancelSourceCheckAsync() async throws {
        try await SharedAsync.void { completion in
            cancelSourceCheck(completionHandler: completion)
        }
    }

    func startBookCacheAsync() async throws {
        try await SharedAsync.void { completion in
            startBookCache(completionHandler: completion)
        }
    }

    func pauseBookCacheAsync() async throws {
        try await SharedAsync.void { completion in
            pauseBookCache(completionHandler: completion)
        }
    }

    func resumeBookCacheAsync() async throws {
        try await SharedAsync.void { completion in
            resumeBookCache(completionHandler: completion)
        }
    }

    func cancelBookCacheAsync() async throws {
        try await SharedAsync.void { completion in
            cancelBookCache(completionHandler: completion)
        }
    }
}

extension ReplaceRuleFacade {
    func saveRuleAsync(rule: ReplaceRule) async throws -> KotlinLong {
        try await SharedAsync.value { completion in
            saveRule(rule: rule, completionHandler: completion)
        }
    }

    func toggleEnabledAsync(id: Int64) async throws {
        try await SharedAsync.void { completion in
            toggleEnabled(id: id, completionHandler: completion)
        }
    }

    func deleteRuleAsync(id: Int64) async throws {
        try await SharedAsync.void { completion in
            deleteRule(id: id, completionHandler: completion)
        }
    }

    func updateOrderAsync(id: Int64, order: Int32) async throws {
        try await SharedAsync.void { completion in
            updateOrder(id: id, order: order, completionHandler: completion)
        }
    }

    func updateEnabledAsync(id: Int64, enabled: Bool) async throws {
        try await SharedAsync.void { completion in
            updateEnabled(id: id, enabled: enabled, completionHandler: completion)
        }
    }

    func deleteRulesAsync(rules: [ReplaceRule]) async throws {
        try await SharedAsync.void { completion in
            deleteRules(rules: rules, completionHandler: completion)
        }
    }

    func saveRulesAsync(rules: [ReplaceRule]) async throws {
        try await SharedAsync.void { completion in
            saveRules(rules: rules, completionHandler: completion)
        }
    }
}
