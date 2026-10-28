import Foundation
import shared

extension BookshelfFacade {
    func loadBooksAsync(groupId: Int64) async throws -> [Book] {
        try await SharedAsync.value { completion in
            loadBooks(groupId: groupId, completionHandler: completion)
        }
    }

    func loadBooksForDisplayAsync(groupId: Int64, sortMode: KotlinInt? = nil) async throws -> [Book] {
        try await SharedAsync.value { completion in
            loadBooksForDisplay(groupId: groupId, sortMode: sortMode, completionHandler: completion)
        }
    }

    func searchBooksAsync(query: String) async throws -> [Book] {
        try await SharedAsync.value { completion in
            searchBooks(query: query, completionHandler: completion)
        }
    }

    func updateTocAsync(groupId: Int64) async throws -> BookshelfBatchUpdateResult {
        try await SharedAsync.value { completion in
            updateToc(groupId: groupId, completionHandler: completion)
        }
    }

    func updateBookTocAsync(bookUrl: String) async throws -> BookshelfBatchUpdateResult {
        try await SharedAsync.value { completion in
            updateBookToc(bookUrl: bookUrl, completionHandler: completion)
        }
    }

    func addBookByUrlAsync(bookUrl: String, groupId: Int64 = 0) async throws -> Book {
        try await SharedAsync.value { completion in
            addBookByUrl(bookUrl: bookUrl, groupId: groupId, completionHandler: completion)
        }
    }

    func seedTestBooksAsync(count: Int32) async throws -> Int32 {
        let result: KotlinInt = try await SharedAsync.value { completion in
            seedTestBooks(count: count, completionHandler: completion)
        }
        return result.int32Value
    }

    func importBookshelfAsync(payload: String, groupId: Int64 = 0) async throws -> BookshelfImportResult {
        try await SharedAsync.value { completion in
            importBookshelf(payload: payload, groupId: groupId, completionHandler: completion)
        }
    }

    func importBookshelfFromUrlAsync(url: String, groupId: Int64 = 0) async throws -> BookshelfImportResult {
        try await SharedAsync.value { completion in
            importBookshelfFromUrl(url: url, groupId: groupId, completionHandler: completion)
        }
    }

    func importBookshelfFileAsync(path: String, groupId: Int64 = 0) async throws -> BookshelfImportResult {
        try await SharedAsync.value { completion in
            importBookshelfFile(path: path, groupId: groupId, completionHandler: completion)
        }
    }

    func exportBookshelfAsync(groupId: Int64 = -1) async throws -> String {
        try await SharedAsync.value { completion in
            exportBookshelf(groupId: groupId, completionHandler: completion)
        }
    }

    func exportBookListAsync(books: [Book]) async throws -> String {
        try await SharedAsync.value { completion in
            exportBookList(books: books, completionHandler: completion)
        }
    }

    func importLocalBookAsync(path: String, groupId: Int64 = 0) async throws -> Book {
        try await SharedLocalBookImportAsync.value { onResult in
            prepareLocalBookImportRequest(path: path, groupId: groupId, onResult: onResult)
        }
    }

    func updateBookGroupAsync(bookUrls: [String], groupId: Int64) async throws -> BookshelfBatchUpdateResult {
        try await SharedAsync.value { completion in
            updateBookGroup(bookUrls: bookUrls, groupId: groupId, completionHandler: completion)
        }
    }

    func addBooksToGroupAsync(bookUrls: [String], groupId: Int64) async throws -> BookshelfBatchUpdateResult {
        try await SharedAsync.value { completion in
            addBooksToGroup(bookUrls: bookUrls, groupId: groupId, completionHandler: completion)
        }
    }

    func removeBooksAsync(bookUrls: [String]) async throws -> BookshelfBatchUpdateResult {
        try await SharedAsync.value { completion in
            removeBooks(bookUrls: bookUrls, completionHandler: completion)
        }
    }

    func removeBooksAndLocalFilesAsync(bookUrls: [String]) async throws -> BookshelfBatchUpdateResult {
        try await SharedAsync.value { completion in
            removeBooksAndLocalFiles(bookUrls: bookUrls, completionHandler: completion)
        }
    }

    func clearCacheAsync(bookUrls: [String]) async throws -> BookshelfBatchUpdateResult {
        try await SharedAsync.value { completion in
            clearCache(bookUrls: bookUrls, completionHandler: completion)
        }
    }

    func loadEnabledBookSourcesAsync() async throws -> [BookSource] {
        try await SharedAsync.value { completion in
            loadEnabledBookSources(completionHandler: completion)
        }
    }

    func changeSourceAsync(
        bookUrls: [String],
        sourceUrl: String,
        delayMillis: Int64,
        onProgress: @escaping (KotlinInt, KotlinInt) -> Void
    ) async throws -> BookshelfBatchChangeSourceResult {
        try await SharedAsync.value { completion in
            changeSource(
                bookUrls: bookUrls,
                sourceUrl: sourceUrl,
                delayMillis: delayMillis,
                onProgress: onProgress,
                completionHandler: completion
            )
        }
    }

    func changeSourceCancellableAsync(
        bookUrls: [String],
        sourceUrl: String,
        delayMillis: Int64,
        onProgress: @escaping (KotlinInt, KotlinInt) -> Void
    ) async throws -> BookshelfBatchChangeSourceResult {
        try Task.checkCancellation()
        let result: BookshelfBatchChangeSourceResult = try await SharedCancellableAsync.value { completion in
            changeSourceRequest(
                bookUrls: bookUrls, sourceUrl: sourceUrl, delayMillis: delayMillis,
                onProgress: onProgress
            ) { response in
                if response.isCancelled {
                    completion(nil, CancellationError())
                } else if let message = response.errorMessage {
                    completion(
                        nil,
                        NSError(
                            domain: "io.legado.kmp.ios", code: -1,
                            userInfo: [NSLocalizedDescriptionKey: message]))
                } else {
                    completion(response.result, nil)
                }
            }
        }
        try Task.checkCancellation()
        return result
    }

    func loadGroupsAsync() async throws -> [BookGroup] {
        try await SharedAsync.value { completion in
            loadGroups(completionHandler: completion)
        }
    }

    func saveGroupAsync(
        groupId: Int64, name: String, show: Bool, order: KotlinInt? = nil, enableRefresh: Bool = true,
        bookSort: Int32 = 0
    ) async throws
        -> BookGroup
    {
        try await SharedAsync.value { completion in
            saveGroup(
                groupId: groupId, name: name, show: show, order: order, enableRefresh: enableRefresh,
                bookSort: bookSort, completionHandler: completion)
        }
    }

    func saveGroupDetailsAsync(
        groupId: Int64,
        name: String,
        cover: String?,
        enableRefresh: Bool,
        bookSort: Int32
    ) async throws -> BookGroup {
        try await SharedAsync.value { completion in
            saveGroupDetails(
                groupId: groupId,
                name: name,
                cover: cover,
                enableRefresh: enableRefresh,
                bookSort: bookSort,
                completionHandler: completion
            )
        }
    }

    func reorderGroupsAsync(groupIds: [KotlinLong]) async throws {
        try await SharedAsync.void { completion in
            reorderGroups(groupIds: groupIds, completionHandler: completion)
        }
    }

    func saveManagedGroupDetailsAsync(
        groupId: Int64,
        name: String,
        cover: String?,
        enableRefresh: Bool,
        bookSort: Int32
    ) async throws -> BookGroup {
        try await SharedAsync.value { completion in
            saveManagedGroupDetails(
                groupId: groupId, name: name, cover: cover,
                enableRefresh: enableRefresh, bookSort: bookSort,
                completionHandler: completion)
        }
    }

    func setManagedGroupVisibleAsync(groupId: Int64, visible: Bool) async throws -> BookGroup {
        try await SharedAsync.value { completion in
            setManagedGroupVisible(groupId: groupId, visible: visible, completionHandler: completion)
        }
    }

    func reorderManagedGroupsAsync(groupIds: [KotlinLong]) async throws {
        try await SharedAsync.void { completion in
            reorderManagedGroups(groupIds: groupIds, completionHandler: completion)
        }
    }

    func deleteGroupAsync(groupId: Int64) async throws {
        try await SharedAsync.void { completion in
            deleteGroup(groupId: groupId, completionHandler: completion)
        }
    }

    func updateBooksCanUpdateAsync(bookUrls: [String], canUpdate: Bool) async throws -> BookshelfBatchUpdateResult {
        try await SharedAsync.value { completion in
            updateBooksCanUpdate(bookUrls: bookUrls, canUpdate: canUpdate, completionHandler: completion)
        }
    }

    func updateBookOrderAsync(bookUrl: String, newOrder: Int32) async throws {
        try await SharedAsync.void { completion in
            updateBookOrder(bookUrl: bookUrl, newOrder: newOrder, completionHandler: completion)
        }
    }

    func exportUsedSourcesAsync(groupId: Int64 = -1) async throws -> String {
        try await SharedAsync.value { completion in
            exportUsedSources(groupId: groupId, completionHandler: completion)
        }
    }
}
