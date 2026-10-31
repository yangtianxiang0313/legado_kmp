package io.legado.kmp.shared.facade

import io.legado.kmp.shared.domain.localbook.LocalBookFileNameResolver
import io.legado.kmp.shared.domain.localbook.LocalBookFileBinding
import io.legado.kmp.shared.domain.usecase.FetchChapterListContractUseCase
import io.legado.kmp.shared.domain.usecase.DeleteBookUseCase
import io.legado.kmp.shared.domain.usecase.DeleteBookGroupUseCase
import io.legado.kmp.shared.domain.usecase.GetBookUseCase
import io.legado.kmp.shared.domain.usecase.GetBookGroupsUseCase
import io.legado.kmp.shared.domain.usecase.GetBookSourcesUseCase
import io.legado.kmp.shared.domain.usecase.GetBooksUseCase
import io.legado.kmp.shared.domain.usecase.ParseEpubLocalFileUseCase
import io.legado.kmp.shared.domain.usecase.ParseMobiLocalFileUseCase
import io.legado.kmp.shared.domain.usecase.ParsePdfLocalFileUseCase
import io.legado.kmp.shared.domain.usecase.ParseTxtLocalFileUseCase
import io.legado.kmp.shared.domain.usecase.ParseUmdLocalFileUseCase
import io.legado.kmp.shared.domain.usecase.RefreshBookInfoUseCase
import io.legado.kmp.shared.domain.usecase.SaveBookUseCase
import io.legado.kmp.shared.domain.usecase.SaveBookGroupUseCase
import io.legado.kmp.shared.domain.usecase.SaveChaptersUseCase
import io.legado.kmp.shared.domain.usecase.SearchBooksUseCase
import io.legado.kmp.shared.domain.repository.BookChapterRepository
import io.legado.kmp.shared.domain.repository.ChapterContentRepository
import io.legado.kmp.shared.domain.usecase.SearchUseCase
import io.legado.kmp.shared.domain.usecase.SearchWebBooksUseCase
import io.legado.kmp.shared.content.BookHelp
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.BookGroup
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.model.BookType
import io.legado.kmp.shared.model.addType
import io.legado.kmp.shared.model.hasType
import io.legado.kmp.shared.network.AnalyzeUrl
import io.legado.kmp.shared.network.HttpUseCase
import io.legado.kmp.shared.platform.FileAccess
import io.legado.kmp.shared.util.cnCompare
import io.legado.kmp.shared.util.currentTimeMillis
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import kotlin.coroutines.coroutineContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

class BookshelfFacade(
    private val getBooksUseCase: GetBooksUseCase,
    private val getBookUseCase: GetBookUseCase,
    private val getBookGroupsUseCase: GetBookGroupsUseCase,
    private val searchBooksUseCase: SearchBooksUseCase,
    private val deleteBookUseCase: DeleteBookUseCase,
    private val saveBookUseCase: SaveBookUseCase,
    private val saveBookGroupUseCase: SaveBookGroupUseCase,
    private val deleteBookGroupUseCase: DeleteBookGroupUseCase,
    private val saveChaptersUseCase: SaveChaptersUseCase,
    private val getBookSourcesUseCase: GetBookSourcesUseCase,
    private val searchWebBooksUseCase: SearchWebBooksUseCase,
    private val refreshBookInfoUseCase: RefreshBookInfoUseCase,
    private val fetchChapterListUseCase: FetchChapterListContractUseCase,
    private val parseTxtLocalFileUseCase: ParseTxtLocalFileUseCase,
    private val parseEpubLocalFileUseCase: ParseEpubLocalFileUseCase,
    private val parsePdfLocalFileUseCase: ParsePdfLocalFileUseCase,
    private val parseUmdLocalFileUseCase: ParseUmdLocalFileUseCase,
    private val parseMobiLocalFileUseCase: ParseMobiLocalFileUseCase,
    private val searchUseCase: SearchUseCase,
    private val bookChapterRepository: BookChapterRepository,
    private val chapterContentRepository: ChapterContentRepository,
    private val fileAccess: FileAccess? = null,
    private val httpUseCase: HttpUseCase? = null,
    private val localBookFileNameResolver: LocalBookFileNameResolver = LocalBookFileNameResolver(),
) {
    companion object {
        private val json = Json {
            ignoreUnknownKeys = true
            encodeDefaults = true
        }

        fun isInBookshelf(keys: Set<String>, name: String, author: String, bookUrl: String): Boolean {
            val key = if (author.isNotBlank()) "$name-$author" else name
            return keys.contains(key) || keys.contains(bookUrl)
        }
    }

    fun defaultGroups(): List<BookGroup> {
        return getBookGroupsUseCase.createSystemGroups()
    }

    fun watchBooks(
        groupId: Long = BookGroup.ID_ALL,
        onUpdate: (List<Book>) -> Unit,
    ): FlowSubscription {
        val flow = combine(getBooksUseCase(), getBookGroupsUseCase()) { books, groups ->
            books.filterForGroup(groupId, groups.withSystemGroups())
        }
        return watchFlow(flow, onUpdate, label = "BookshelfFacade.books")
    }

    fun watchGroups(onUpdate: (List<BookGroup>) -> Unit): FlowSubscription {
        return watchFlow(
            combine(getBookGroupsUseCase(), getBooksUseCase()) { groups, books ->
                groups.withSystemGroups().visibleForBooks(books.shelfBooks())
            },
            onUpdate,
            label = "BookshelfFacade.groups",
        )
    }

    fun watchSelectableGroups(onUpdate: (List<BookGroup>) -> Unit): FlowSubscription {
        return watchFlow(
            getBookGroupsUseCase().map { groups ->
                groups.filter { it.groupId >= 0 }.sortedBy { it.order }
            },
            onUpdate,
            label = "BookshelfFacade.selectableGroups",
        )
    }

    fun watchManagedGroups(
        onUpdate: (List<BookGroup>) -> Unit,
        onError: (String) -> Unit,
    ): FlowSubscription = watchFlow(
        getBookGroupsUseCase().map { it.withSystemGroups() }.catch { error ->
            coroutineContext.ensureActive()
            findFacadeRequestCancellation(error)?.let { throw it }
            onError(error.message ?: "Unable to observe book groups")
        },
        onUpdate,
        label = "BookshelfFacade.managedGroups",
    )

    fun watchBookshelfKeys(onUpdate: (Set<String>) -> Unit): FlowSubscription {
        val flow = getBooksUseCase().map { books ->
            val keys = mutableSetOf<String>()
            for (book in books.shelfBooks()) {
                keys.add("${book.name}-${book.author}")
                keys.add(book.name)
                keys.add(book.bookUrl)
            }
            keys as Set<String>
        }
        return watchFlow(flow, onUpdate, label = "BookshelfFacade.bookshelfKeys")
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun loadGroups(): List<BookGroup> = runRecoverable("BookshelfFacade.loadGroups") {
        getBookGroupsUseCase.getAll().withSystemGroups()
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun loadBooks(groupId: Long = BookGroup.ID_ALL): List<Book> = runRecoverable("BookshelfFacade.loadBooks") {
        getBooksUseCase().first().filterForGroup(groupId, getBookGroupsUseCase.getAll().withSystemGroups())
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun searchBooks(query: String): List<Book> = runRecoverable("BookshelfFacade.searchBooks") {
        searchBooksUseCase(query.trim())
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun loadBooksForDisplay(groupId: Long = BookGroup.ID_ALL, sortMode: Int? = null): List<Book> =
        runRecoverable("BookshelfFacade.loadBooksForDisplay") {
            sortBooks(loadBooks(groupId), groupId, sortMode)
        }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun loadEnabledBookSources(): List<BookSource> = runRecoverable("BookshelfFacade.loadEnabledBookSources") {
        getBookSourcesUseCase.getEnabled()
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun updateBookGroup(bookUrls: List<String>, groupId: Long): BookshelfBatchUpdateResult =
        runRecoverable("BookshelfFacade.updateBookGroup") {
            var updated = 0
            var failed = 0
            bookUrls.distinct().forEach { bookUrl ->
                val book = getBookUseCase.get(bookUrl)
                if (book == null) {
                    failed += 1
                    return@forEach
                }
                runCatching {
                    saveBookUseCase.update(book.copy(group = groupId))
                }.onSuccess {
                    updated += 1
                }.onFailure {
                    failed += 1
                }
            }
            BookshelfBatchUpdateResult(updatedCount = updated, failedCount = failed)
        }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun addBooksToGroup(bookUrls: List<String>, groupId: Long): BookshelfBatchUpdateResult =
        runRecoverable("BookshelfFacade.addBooksToGroup") {
            var updated = 0
            var failed = 0
            bookUrls.distinct().forEach { bookUrl ->
                val book = getBookUseCase.get(bookUrl)
                if (book == null) {
                    failed += 1
                    return@forEach
                }
                runCatching {
                    saveBookUseCase.update(book.copy(group = book.group or groupId))
                }.onSuccess {
                    updated += 1
                }.onFailure {
                    failed += 1
                }
            }
            BookshelfBatchUpdateResult(updatedCount = updated, failedCount = failed)
        }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun removeBooks(bookUrls: List<String>): BookshelfBatchUpdateResult =
        runRecoverable("BookshelfFacade.removeBooks") {
            removeBooksInternal(bookUrls, deleteLocalFiles = false)
        }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun removeBooksAndLocalFiles(bookUrls: List<String>): BookshelfBatchUpdateResult =
        runRecoverable("BookshelfFacade.removeBooksAndLocalFiles") {
            removeBooksInternal(bookUrls, deleteLocalFiles = true)
        }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun clearCache(bookUrls: List<String>): BookshelfBatchUpdateResult =
        runRecoverable("BookshelfFacade.clearCache") {
            var cleared = 0
            var failed = 0
            bookUrls.distinct().forEach { bookUrl ->
                val book = getBookUseCase.get(bookUrl)
                if (book == null) {
                    failed += 1
                    return@forEach
                }
                runCatching {
                    val chapters = bookChapterRepository.getChaptersByBookUrl(book.bookUrl)
                    chapters.forEach { chapter ->
                        chapterContentRepository.deleteContent(book, chapter)
                    }
                }.onSuccess {
                    cleared += 1
                }.onFailure {
                    failed += 1
                }
            }
            BookshelfBatchUpdateResult(updatedCount = cleared, failedCount = failed)
        }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun changeSource(
        bookUrls: List<String>,
        sourceUrl: String,
        delayMillis: Long = 0,
        onProgress: (Int, Int) -> Unit = { _, _ -> },
    ): BookshelfBatchChangeSourceResult =
        runRecoverable("BookshelfFacade.changeSource") {
            coroutineContext.ensureActive()
            val distinctUrls = bookUrls.distinct()
            val source = requireNotNull(getBookSourcesUseCase.getByUrl(sourceUrl)) {
                "Book source not found: $sourceUrl"
            }
            var updated = 0
            var skipped = 0
            var failed = 0
            distinctUrls.forEachIndexed { index, bookUrl ->
                coroutineContext.ensureActive()
                onProgress(index + 1, distinctUrls.size)
                coroutineContext.ensureActive()
                val current = getBookUseCase.get(bookUrl)
                coroutineContext.ensureActive()
                if (current == null || current.isLocal || current.origin == source.bookSourceUrl) {
                    skipped += 1
                    return@forEachIndexed
                }
                runCatching {
                    val candidate = searchWebBooksUseCase.searchFromSource(source, current.name, page = 1)
                        .getOrThrow()
                        .firstOrNull { candidate ->
                            candidate.name.trim() == current.name.trim() &&
                                (current.author.isBlank() || candidate.author.trim() == current.author.trim())
                        } ?: error("Replacement source candidate not found")
                    val resolvedCandidate = if (candidate.tocUrl.isBlank()) {
                        searchUseCase.getByBookUrl(candidate.bookUrl)?.takeIf { it.origin == candidate.origin }
                            ?: candidate
                    } else {
                        candidate
                    }
                    val replacement = resolvedCandidate.toBook().copy(
                        group = current.group,
                        order = current.order,
                        durChapterTitle = current.durChapterTitle,
                        durChapterIndex = current.durChapterIndex,
                        durChapterPos = current.durChapterPos,
                        durChapterTime = current.durChapterTime,
                        canUpdate = current.canUpdate,
                    )
                    val result = fetchChapterListUseCase(source, replacement, runPreUpdateJs = true).getOrThrow()
                    val persisted = result.book.migrateShelfStateFrom(current, result.chapters)
                    coroutineContext.ensureActive()
                    // Cancellation may stop before a migration, not between its delete and replacement.
                    withContext(NonCancellable) {
                        deleteBookUseCase(current)
                        saveBookUseCase(persisted)
                        saveChaptersUseCase(persisted.bookUrl, result.chapters)
                    }
                }.onSuccess {
                    updated += 1
                }.onFailure { error ->
                    coroutineContext.ensureActive()
                    findFacadeRequestCancellation(error)?.let { throw it }
                    failed += 1
                }
                if (delayMillis > 0 && index < distinctUrls.lastIndex) {
                    delay(delayMillis)
                }
            }
            coroutineContext.ensureActive()
            BookshelfBatchChangeSourceResult(
                updatedCount = updated,
                skippedCount = skipped,
                failedCount = failed,
            )
        }

    fun changeSourceRequest(
        bookUrls: List<String>,
        sourceUrl: String,
        delayMillis: Long,
        onProgress: (Int, Int) -> Unit,
        onResult: (BookshelfBatchSourceChangeRequestResult) -> Unit,
    ): FlowSubscription = CancellableFacadeRequest.start(
        prepare = {
            BookshelfBatchSourceChangeRequestResult(
                result = changeSource(bookUrls, sourceUrl, delayMillis, onProgress),
            )
        },
        cancelledResult = BookshelfBatchSourceChangeRequestResult(isCancelled = true),
        failureResult = { error ->
            val failure = error.asRecoverableSharedException("BookshelfFacade.changeSource")
            BookshelfBatchSourceChangeRequestResult(errorMessage = failure.message)
        },
        onResult = onResult,
        facade = "BookshelfFacade",
        callbackMethod = "changeSourceRequest.onResult",
        missingResultMessage = "Bookshelf source change completed without a result",
    )

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun updateToc(groupId: Long = BookGroup.ID_ALL): BookshelfBatchUpdateResult =
        runRecoverable("BookshelfFacade.updateToc") {
            val books = loadBooks(groupId).filter { it.shouldUpdate() && !it.isLocal }
            var updated = 0
            var failed = 0
            books.forEach { snapshot ->
                val result = updateBookTocInternal(snapshot.bookUrl)
                updated += result.updatedCount
                failed += result.failedCount
            }
            coroutineContext.ensureActive()
            BookshelfBatchUpdateResult(updatedCount = updated, failedCount = failed)
        }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun updateBookToc(bookUrl: String): BookshelfBatchUpdateResult =
        runRecoverable("BookshelfFacade.updateBookToc") {
            val result = updateBookTocInternal(bookUrl)
            coroutineContext.ensureActive()
            result
        }

    private suspend fun updateBookTocInternal(bookUrl: String): BookshelfBatchUpdateResult {
        coroutineContext.ensureActive()
        val book = getBookUseCase.get(bookUrl) ?: return BookshelfBatchUpdateResult(0, 0)
        coroutineContext.ensureActive()
        if (!book.shouldUpdate() || book.isLocal || book.isNotShelf) return BookshelfBatchUpdateResult(0, 0)
        return try {
            val source = requireNotNull(getBookSourcesUseCase.getByUrl(book.origin)) {
                "Book source not found: ${book.origin}"
            }
            coroutineContext.ensureActive()
            val prepared = if (book.tocUrl.isBlank()) {
                val refreshed = refreshBookInfoUseCase(source, book).getOrThrow()
                coroutineContext.ensureActive()
                book.mergeTocMetadata(refreshed)
            } else {
                book
            }
            val chapters = fetchChapterListUseCase(source, prepared, runPreUpdateJs = true).getOrThrow()
            coroutineContext.ensureActive()
            if (saveRefreshedToc(book, chapters.book, chapters.chapters)) {
                BookshelfBatchUpdateResult(updatedCount = 1, failedCount = 0)
            } else {
                BookshelfBatchUpdateResult(updatedCount = 0, failedCount = 1)
            }
        } catch (error: Throwable) {
            coroutineContext.ensureActive()
            findFacadeRequestCancellation(error)?.let { throw it }
            markTocUpdateFailure(book)
            BookshelfBatchUpdateResult(updatedCount = 0, failedCount = 1)
        }
    }

    private fun Book.mergeTocMetadata(incoming: Book): Book {
        require(incoming.bookUrl == bookUrl) { "Refreshed book URL must match the shelf book" }
        require(incoming.origin == origin) { "Refreshed origin must match the shelf book" }
        val incomingVariables = incoming.variableMap
        // Keep chapter statistics and reader state as the baseline for TOC parsing.
        return copy(
            tocUrl = incoming.tocUrl.ifBlank { tocUrl },
            originName = incoming.originName.ifBlank { originName },
            name = incoming.name.ifBlank { name },
            author = incoming.author.ifBlank { author },
            kind = incoming.kind?.takeIf { it.isNotBlank() } ?: kind,
            coverUrl = incoming.coverUrl?.takeIf { it.isNotBlank() } ?: coverUrl,
            intro = incoming.intro?.takeIf { it.isNotBlank() } ?: intro,
            wordCount = incoming.wordCount?.takeIf { it.isNotBlank() } ?: wordCount,
            latestChapterTitle = incoming.latestChapterTitle?.takeIf { it.isNotBlank() } ?: latestChapterTitle,
            variable = if (incomingVariables.isEmpty()) variable else json.encodeToString(variableMap + incomingVariables),
            readConfig = readConfig?.copy(),
        ).also {
            it.infoHtml = incoming.infoHtml
            it.tocHtml = incoming.tocHtml
            it.downloadUrls = incoming.downloadUrls ?: downloadUrls
        }
    }

    private suspend fun saveRefreshedToc(expected: Book, refreshed: Book, chapters: List<BookChapter>): Boolean {
        coroutineContext.ensureActive()
        val current = getBookUseCase.get(expected.bookUrl) ?: return false
        coroutineContext.ensureActive()
        if (!current.shouldUpdate() || current.isLocal || current.isNotShelf ||
            current.origin != expected.origin || current.tocUrl != expected.tocUrl ||
            current.totalChapterNum != expected.totalChapterNum ||
            current.config.reverseToc != expected.config.reverseToc ||
            refreshed.config.reverseToc != expected.config.reverseToc
        ) {
            return false
        }
        val progressChanged = current.durChapterIndex != expected.durChapterIndex ||
            current.durChapterPos != expected.durChapterPos ||
            current.durChapterTime != expected.durChapterTime ||
            current.durChapterTitle != expected.durChapterTitle
        val merged = current.mergeTocMetadata(refreshed)
        val replacement = merged.copy(
            type = current.type and BookType.UPDATE_ERROR.inv(),
            totalChapterNum = refreshed.totalChapterNum,
            latestChapterTime = refreshed.latestChapterTime,
            lastCheckTime = refreshed.lastCheckTime,
            // Copying current progress must not hide its concurrent count reset from the repository.
            lastCheckCount = if (progressChanged) current.lastCheckCount else refreshed.lastCheckCount,
        ).also {
            it.infoHtml = merged.infoHtml
            it.tocHtml = merged.tocHtml
            it.downloadUrls = merged.downloadUrls
        }
        coroutineContext.ensureActive()
        saveBookUseCase.ifSourceUnchanged(expected, replacement, chapters, allowInsert = false)
        coroutineContext.ensureActive()
        return true
    }

    private suspend fun markTocUpdateFailure(expected: Book) {
        coroutineContext.ensureActive()
        val current = getBookUseCase.get(expected.bookUrl) ?: return
        coroutineContext.ensureActive()
        if (current.origin != expected.origin || current.isLocal || current.isNotShelf ||
            current.hasType(BookType.UPDATE_ERROR)
        ) {
            return
        }
        saveBookUseCase.ifSourceUnchanged(
            expected = current,
            book = current.addType(BookType.UPDATE_ERROR),
            allowInsert = false,
        )
        coroutineContext.ensureActive()
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun prepareBookLink(bookUrl: String): Book = runRecoverable("BookshelfFacade.prepareBookLink") {
        BookLinkResolver(getBookUseCase, getBookSourcesUseCase, refreshBookInfoUseCase, searchUseCase).prepare(bookUrl)
    }

    fun prepareBookLinkRequest(
        bookUrl: String,
        onResult: (BookLinkPreparationResult) -> Unit,
    ): FlowSubscription = CancellableFacadeRequest.start(
        prepare = { BookLinkPreparationResult(book = prepareBookLink(bookUrl)) },
        cancelledResult = BookLinkPreparationResult(isCancelled = true),
        failureResult = { error ->
            val failure = error.asRecoverableSharedException("BookshelfFacade.prepareBookLink")
            BookLinkPreparationResult(errorMessage = failure.message)
        },
        onResult = onResult,
        facade = "BookshelfFacade",
        callbackMethod = "prepareBookLinkRequest.onResult",
        missingResultMessage = "Book link preparation completed without a result",
    )

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun addBookByUrl(bookUrl: String, groupId: Long = 0): Book =
        runRecoverable("BookshelfFacade.addBookByUrl") {
            val normalizedUrl = bookUrl.trim()
            require(normalizedUrl.isNotEmpty()) { "Book URL is empty" }
            getBookUseCase.get(normalizedUrl)?.let { existing ->
                return@runRecoverable if (groupId > 0 && existing.group != groupId) {
                    val updated = existing.copy(group = groupId)
                    saveBookUseCase.update(updated)
                    updated
                } else {
                    existing
                }
            }

            val baseUrl = AnalyzeUrl.getBaseUrl(normalizedUrl).normalizeSourceUrlForMatch()
            val source = requireNotNull(getBookSourcesUseCase.getEnabled().firstOrNull {
                it.bookSourceUrl.normalizeSourceUrlForMatch() == baseUrl
            }
                ?: getBookSourcesUseCase.getEnabled().firstOrNull { candidate ->
                    candidate.hasBookUrlPattern && normalizedUrl.matches(Regex(candidate.bookUrlPattern ?: ""))
                }) {
                "No enabled source matched this URL"
            }
            val refreshed = refreshBookInfoUseCase(source, normalizedUrl).getOrThrow()
            val sameBook = getBooksUseCase.getAll().firstOrNull { existing ->
                existing.bookUrl != normalizedUrl && existing.sameBookIdentity(refreshed)
            }
            if (sameBook != null) {
                val result = fetchChapterListUseCase(source, refreshed, runPreUpdateJs = false).getOrThrow()
                val migrated = result.book.migrateShelfStateFrom(sameBook, result.chapters)
                deleteBookUseCase(sameBook)
                saveBookUseCase(migrated)
                saveChaptersUseCase(migrated.bookUrl, result.chapters)
                return@runRecoverable migrated
            }
            val chapterResult = runCatching {
                fetchChapterListUseCase(source, refreshed, runPreUpdateJs = false).getOrThrow()
            }.getOrNull()
            val groupedBook = (chapterResult?.book ?: refreshed).copy(
                group = if (groupId > 0) groupId else (chapterResult?.book?.group ?: refreshed.group),
                order = minOrder() - 1,
            )
            saveBookUseCase(groupedBook)
            if (chapterResult?.chapters?.isNotEmpty() == true) {
                saveChaptersUseCase(groupedBook.bookUrl, chapterResult.chapters)
            }
            groupedBook
        }

    private fun String.normalizeSourceUrlForMatch(): String {
        return trim().trimEnd('/')
    }

    private fun Book.sameBookIdentity(other: Book): Boolean {
        val leftName = name.trim()
        val rightName = other.name.trim()
        return leftName.isNotEmpty() &&
            leftName == rightName &&
            author.trim() == other.author.trim()
    }

    private fun Book.migrateShelfStateFrom(oldBook: Book, newChapters: List<BookChapter>): Book {
        val newIndex = BookHelp.getDurChapter(oldBook, newChapters).coerceInChapterList(newChapters)
        return copy(
            durChapterIndex = newIndex,
            durChapterTitle = newChapters.getOrNull(newIndex)?.title ?: oldBook.durChapterTitle,
            durChapterPos = oldBook.durChapterPos,
            durChapterTime = oldBook.durChapterTime,
            group = oldBook.group,
            order = oldBook.order,
            customCoverUrl = oldBook.customCoverUrl,
            customIntro = oldBook.customIntro,
            customTag = oldBook.customTag,
            canUpdate = oldBook.canUpdate,
            readConfig = oldBook.readConfig,
        )
    }

    private fun Int.coerceInChapterList(chapters: List<BookChapter>): Int {
        return if (chapters.isEmpty()) this.coerceAtLeast(0) else coerceIn(0, chapters.lastIndex)
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun importBookshelf(payload: String, groupId: Long = 0): BookshelfImportResult =
        runRecoverable("BookshelfFacade.importBookshelf") {
            val trimmed = payload.trim()
            require(trimmed.isNotEmpty()) { "Bookshelf payload is empty" }
            val books = json.decodeFromString<List<BookshelfExchangeBook>>(trimmed)
            var added = 0
            var skipped = 0
            var failed = 0
            val enabledSources = getBookSourcesUseCase.getEnabled()
            books.forEach { exchange ->
                val name = exchange.name.trim()
                val author = exchange.author.trim()
                if (name.isEmpty()) {
                    skipped += 1
                    return@forEach
                }
                val exists = getBooksUseCase.getAll().any { it.name == name && it.author == author }
                if (exists) {
                    skipped += 1
                    return@forEach
                }
                runCatching {
                    val candidates = searchWebBooksUseCase.searchAndAggregate(enabledSources, name, page = 1)
                    val matched = candidates.firstOrNull { candidate ->
                        candidate.name.trim() == name && (author.isBlank() || candidate.author.trim() == author)
                    } ?: candidates.firstOrNull { candidate ->
                        author.isBlank() || candidate.author.trim() == author
                    } ?: error("No matched search result for $name")
                    val imported = matched.toBook().copy(
                        group = if (groupId > 0) groupId else 0,
                        order = minOrder() - 1,
                        lastCheckTime = currentTimeMillis(),
                    )
                    saveBookUseCase(imported)
                }.onSuccess {
                    added += 1
                }.onFailure {
                    failed += 1
                }
            }
            BookshelfImportResult(addedCount = added, skippedCount = skipped, failedCount = failed)
        }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun importBookshelfFromUrl(url: String, groupId: Long = 0): BookshelfImportResult =
        runRecoverable("BookshelfFacade.importBookshelfFromUrl") {
            val normalizedUrl = url.trim()
            require(normalizedUrl.isNotEmpty()) { "Bookshelf import URL is empty" }
            val http = requireNotNull(httpUseCase) { "HTTP service is unavailable" }
            val payload = http.getAsString(normalizedUrl).getOrElse { throw it }
            require(payload.isNotBlank()) { "Bookshelf payload is empty" }
            importBookshelf(payload, groupId)
        }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun importBookshelfFile(path: String, groupId: Long = 0): BookshelfImportResult =
        runRecoverable("BookshelfFacade.importBookshelfFile") {
            val normalizedPath = path.trim()
            require(normalizedPath.isNotEmpty()) { "Bookshelf import file path is empty" }
            val access = requireNotNull(fileAccess) { "File access is unavailable" }
            val payload = access.read(normalizedPath).decodeToString()
            require(payload.isNotBlank()) { "Bookshelf payload is empty" }
            importBookshelf(payload, groupId)
        }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun exportBookshelf(groupId: Long = BookGroup.ID_ALL): String =
        runRecoverable("BookshelfFacade.exportBookshelf") {
            exportBookList(loadBooks(groupId))
        }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun exportBookList(books: List<Book>): String =
        runRecoverable("BookshelfFacade.exportBookList") {
            val exchange = books.map { book ->
                BookshelfExchangeBook(
                    name = book.name,
                    author = book.author,
                    intro = book.displayIntro,
                )
            }
            json.encodeToString(ListSerializer(BookshelfExchangeBook.serializer()), exchange)
        }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun importLocalBook(path: String, groupId: Long = 0): Book =
        runRecoverable("BookshelfFacade.importLocalBook") {
            coroutineContext.ensureActive()
            val normalizedPath = path.trim()
            require(normalizedPath.isNotEmpty()) { "Local path is empty" }
            getBookUseCase.get(normalizedPath)?.let { return@runRecoverable it }
            coroutineContext.ensureActive()
            val fileName = normalizedPath.substringAfterLast('/').substringAfterLast('\\')
            val nameAuthor = localBookFileNameResolver.resolve(fileName)
            val extension = fileName.substringAfterLast('.', "").lowercase()
            val bookType = when (extension) {
                "epub" -> BookType.EPUB
                "txt" -> BookType.TEXT
                "pdf", "umd", "mobi", "azw", "azw3" -> BookType.LOCAL
                else -> BookType.TEXT
            }
            val draft = Book(
                bookUrl = normalizedPath,
                origin = BookType.LOCAL_TAG,
                originName = fileName,
                name = nameAuthor.name,
                author = nameAuthor.author,
                type = bookType,
                group = if (groupId > 0) groupId else 0,
                order = minOrder() - 1,
            )
            val parsed = when (bookType) {
                BookType.EPUB -> parseEpubLocalFileUseCase(draft).let { ParsedLocalBook(it.book, it.chapters) }
                BookType.TEXT -> parseTxtLocalFileUseCase(draft).let { ParsedLocalBook(it.book, it.chapters) }
                BookType.LOCAL -> when (extension) {
                    "pdf" -> parsePdfLocalFileUseCase(draft).let { ParsedLocalBook(it.book, it.chapters) }
                    "umd" -> parseUmdLocalFileUseCase(draft).let { ParsedLocalBook(it.book, it.chapters) }
                    "mobi", "azw", "azw3" -> parseMobiLocalFileUseCase(draft).let { ParsedLocalBook(it.book, it.chapters) }
                    else -> error("Unsupported local book extension: .$extension")
                }
                else -> error("Unsupported local book type: $bookType")
            }
            val persisted = parsed.book.copy(
                group = draft.group,
                order = draft.order,
            )
            coroutineContext.ensureActive()
            // The synchronous transaction checks cancellation until commit; never discard its successful result afterward.
            saveBookUseCase.insertLocalBookIfAbsent(persisted, parsed.chapters)
        }

    /** Creates an idle request; install its cancellation handle before calling start(). */
    fun prepareLocalBookImportRequest(
        path: String,
        groupId: Long = 0,
        onResult: (LocalBookImportRequestResult) -> Unit,
    ): LocalBookImportRequest = LocalBookImportRequest.create(
        performImport = { importLocalBook(path, groupId) },
        onResult = onResult,
    )

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun saveGroup(
        groupId: Long,
        name: String,
        show: Boolean,
        order: Int? = null,
        enableRefresh: Boolean = true,
        bookSort: Int = 0,
    ): BookGroup = runRecoverable("BookshelfFacade.saveGroup") {
        val normalizedName = name.trim()
        require(normalizedName.isNotEmpty()) { "Group name is empty" }
        val existing = getBookGroupsUseCase.getById(groupId)
        val resolved = if (existing != null) {
            existing.copy(
                groupName = normalizedName,
                show = show,
                order = order ?: existing.order,
                enableRefresh = enableRefresh,
                bookSort = bookSort,
            )
        } else {
            val resolvedId = if (groupId > 0) groupId else getBookGroupsUseCase.getUnusedGroupId()
            BookGroup(
                groupId = resolvedId,
                groupName = normalizedName,
                show = show,
                order = order ?: ((getBookGroupsUseCase.getAll().maxOfOrNull { it.order } ?: 0) + 1),
                enableRefresh = enableRefresh,
                bookSort = bookSort,
            )
        }
        saveBookGroupUseCase(resolved)
        resolved
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun saveGroupDetails(
        groupId: Long,
        name: String,
        cover: String?,
        enableRefresh: Boolean,
        bookSort: Int,
    ): BookGroup = runRecoverable("BookshelfFacade.saveGroupDetails") {
        require(groupId >= 0) { "Only custom groups can be edited" }
        val normalizedName = name.trim()
        require(normalizedName.isNotEmpty()) { "Group name is empty" }
        // Android book_sort has seven entries; the default entry maps to -1.
        require(bookSort in -1..5) { "Invalid group book sort: $bookSort" }
        val existing = getBookGroupsUseCase.getById(groupId)
        require(groupId == 0L || existing != null) { "Book group not found: $groupId" }
        val resolved = if (existing != null) {
            existing.copy(
                groupName = normalizedName,
                cover = cover,
                enableRefresh = enableRefresh,
                bookSort = bookSort,
            )
        } else {
            val resolvedId = getBookGroupsUseCase.getUnusedGroupId()
            BookGroup(
                groupId = resolvedId,
                groupName = normalizedName,
                cover = cover,
                order = (getBookGroupsUseCase.getCustom().maxOfOrNull { it.order } ?: 0) + 1,
                enableRefresh = enableRefresh,
                show = true,
                bookSort = bookSort,
            )
        }
        saveBookGroupUseCase(resolved)
        resolved
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun saveManagedGroupDetails(
        groupId: Long,
        name: String,
        cover: String?,
        enableRefresh: Boolean,
        bookSort: Int,
    ): BookGroup = runRecoverable("BookshelfFacade.saveManagedGroupDetails") {
        val normalizedName = name.trim()
        require(normalizedName.isNotEmpty()) { "Group name is empty" }
        require(bookSort in -1..5) { "Invalid group book sort: $bookSort" }
        val latest = requireManagedGroup(groupId)
        val updated = latest.copy(
            groupName = normalizedName,
            cover = cover,
            enableRefresh = enableRefresh,
            bookSort = bookSort,
        )
        saveBookGroupUseCase(updated)
        updated
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setManagedGroupVisible(groupId: Long, visible: Boolean): BookGroup =
        runRecoverable("BookshelfFacade.setManagedGroupVisible") {
            val updated = requireManagedGroup(groupId).copy(show = visible)
            saveBookGroupUseCase(updated)
            updated
        }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun reorderManagedGroups(groupIds: List<Long>): Unit = runRecoverable("BookshelfFacade.reorderManagedGroups") {
        require(groupIds.toSet().size == groupIds.size) { "Duplicate group IDs" }
        // Validate the entire request before any write. Each subsequent write rereads only its own row;
        // this is deliberately not a transaction, and callers must reread after a partial failure.
        groupIds.forEach { requireManagedGroup(it) }
        groupIds.forEachIndexed { index, groupId ->
            coroutineContext.ensureActive()
            val latest = requireManagedGroup(groupId)
            saveBookGroupUseCase(latest.copy(order = index + 1))
        }
    }

    private suspend fun requireManagedGroup(groupId: Long): BookGroup {
        val system = getBookGroupsUseCase.createSystemGroups().firstOrNull { it.groupId == groupId }
        require(groupId > 0 || system != null) { "Not a managed book group: $groupId" }
        return getBookGroupsUseCase.getById(groupId) ?: system
            ?: error("Book group not found: $groupId")
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun reorderGroups(groupIds: List<Long>): Unit = runRecoverable("BookshelfFacade.reorderGroups") {
        require(groupIds.toSet().size == groupIds.size) { "Duplicate group IDs" }
        require(groupIds.all { it >= 0 }) { "Only custom groups can be reordered" }
        // Preflight all IDs before writing; the use case has no batch transaction API.
        groupIds.forEach { groupId ->
            requireNotNull(getBookGroupsUseCase.getById(groupId)) { "Book group not found: $groupId" }
        }
        groupIds.forEachIndexed { index, groupId ->
            val latest = requireNotNull(getBookGroupsUseCase.getById(groupId)) {
                "Book group not found: $groupId"
            }
            saveBookGroupUseCase(latest.copy(order = index + 1))
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun deleteGroup(groupId: Long) = runRecoverable("BookshelfFacade.deleteGroup") {
        require(groupId > 0) { "Only custom groups can be deleted" }
        val affectedBooks = getBooksUseCase.getAll().filter { book -> book.group and groupId != 0L }
        affectedBooks.forEach { book ->
            saveBookUseCase.update(book.copy(group = book.group and groupId.inv()))
        }
        deleteBookGroupUseCase(groupId)
    }

    private suspend fun minOrder(): Int {
        return getBooksUseCase.getAll().minOfOrNull { it.order } ?: 0
    }

    private suspend fun removeBooksInternal(
        bookUrls: List<String>,
        deleteLocalFiles: Boolean,
    ): BookshelfBatchUpdateResult {
        var removed = 0
        var failed = 0
        bookUrls.distinct().forEach { bookUrl ->
            runCatching {
                val existing = getBookUseCase.get(bookUrl) ?: error("Book not found: $bookUrl")
                if (deleteLocalFiles && existing.isLocal) {
                    val access = requireNotNull(fileAccess) { "File access is unavailable" }
                    val path = LocalBookFileBinding.path(existing)
                    val key = LocalBookFileBinding.retainedKey(path)
                    val sharedOriginal = key != null && getBooksUseCase.getAll().any {
                        it.bookUrl != existing.bookUrl && it.isLocal && LocalBookFileBinding.retainedKeyForBook(it) == key
                    }
                    if (!sharedOriginal && access.exists(path)) {
                        require(access.delete(path)) { "Failed to delete local original" }
                    }
                }
                deleteBookUseCase(existing)
                removed += 1
            }.onFailure {
                failed += 1
            }
        }
        return BookshelfBatchUpdateResult(updatedCount = removed, failedCount = failed)
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun updateBooksCanUpdate(bookUrls: List<String>, canUpdate: Boolean): BookshelfBatchUpdateResult =
        runRecoverable("BookshelfFacade.updateBooksCanUpdate") {
            var updated = 0
            var failed = 0
            bookUrls.distinct().forEach { bookUrl ->
                val book = getBookUseCase.get(bookUrl)
                if (book == null) {
                    failed += 1
                    return@forEach
                }
                runCatching {
                    saveBookUseCase.update(book.copy(canUpdate = canUpdate))
                }.onSuccess {
                    updated += 1
                }.onFailure {
                    failed += 1
                }
            }
            BookshelfBatchUpdateResult(updatedCount = updated, failedCount = failed)
        }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun updateBookOrder(bookUrl: String, newOrder: Int) =
        runRecoverable("BookshelfFacade.updateBookOrder") {
            val book = requireNotNull(getBookUseCase.get(bookUrl)) { "Book not found: $bookUrl" }
            saveBookUseCase.update(book.copy(order = newOrder))
        }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun seedTestBooks(count: Int): Int =
        runRecoverable("BookshelfFacade.seedTestBooks") {
            require(count in 1..100) { "count must be 1..100" }
            var inserted = 0
            for (i in 1..count) {
                val bookUrl = "test://seed-book-$i"
                if (getBookUseCase.get(bookUrl) != null) continue
                saveBookUseCase(
                    Book(
                        bookUrl = bookUrl,
                        name = "测试书籍 $i",
                        author = "测试作者 ${(i - 1) / 3 + 1}",
                        origin = BookType.LOCAL_TAG,
                        order = -i,
                    )
                )
                inserted++
            }
            inserted
        }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun exportUsedSources(groupId: Long = BookGroup.ID_ALL): String =
        runRecoverable("BookshelfFacade.exportUsedSources") {
            val books = loadBooks(groupId)
            val sourceUrls = books.mapNotNull { it.origin.takeIf { url -> url.isNotBlank() && !BookType.isLocalOrigin(url) } }.distinct()
            val sources = sourceUrls.mapNotNull { url -> getBookSourcesUseCase.getByUrl(url) }
            json.encodeToString(ListSerializer(io.legado.kmp.shared.model.BookSource.serializer()), sources)
    }

    private suspend fun sortBooks(books: List<Book>, groupId: Long, sortModeOverride: Int?): List<Book> {
        val defaultSort = sortModeOverride ?: 0
        val groupSort = if (groupId == BookGroup.ID_ALL) {
            sortModeOverride ?: 0
        } else {
            sortModeOverride ?: getBookGroupsUseCase.getById(groupId)?.getRealBookSort(defaultSort) ?: defaultSort
        }
        return when (groupSort) {
            1 -> books.sortedByDescending { it.latestChapterTime }
            2 -> books.sortedWith { left, right -> left.name.cnCompare(right.name) }
            3 -> books.sortedBy { it.order }
            4 -> books.sortedByDescending { maxOf(it.latestChapterTime, it.durChapterTime) }
            5 -> books.sortedWith { left, right -> left.author.cnCompare(right.author) }
            else -> books.sortedByDescending { it.durChapterTime }
        }
    }

    private fun List<Book>.filterForGroup(groupId: Long, groups: List<BookGroup>): List<Book> {
        val books = shelfBooks()
        val customGroupMask = groups
            .asSequence()
            .filter { it.groupId > 0 }
            .fold(0L) { mask, group -> mask or group.groupId }
        return when (groupId) {
            BookGroup.ID_ROOT -> {
                val netNoGroupShown = groups.firstOrNull { it.groupId == BookGroup.ID_NET_NONE }?.show ?: true
                if (netNoGroupShown) {
                    emptyList()
                } else {
                    books.filter { book ->
                        book.hasType(BookType.TEXT) &&
                                !book.isAudio &&
                                !book.isLocal &&
                                (book.group and customGroupMask) == 0L
                    }
                }
            }
            BookGroup.ID_ALL -> books
            BookGroup.ID_LOCAL -> books.filter { it.isLocal }
            BookGroup.ID_AUDIO -> books.filter { it.isAudio }
            BookGroup.ID_NET_NONE -> books.filter { !it.isAudio && !it.isLocal && (it.group and customGroupMask) == 0L }
            BookGroup.ID_LOCAL_NONE -> books.filter { it.isLocal && (it.group and customGroupMask) == 0L }
            BookGroup.ID_ERROR -> books.filter { it.hasType(BookType.UPDATE_ERROR) }
            else -> {
                if (groupId > 0) {
                    books.filter { it.group and groupId != 0L }
                } else {
                    emptyList()
                }
            }
        }
    }

    private fun List<Book>.shelfBooks(): List<Book> {
        return filterNot { it.isNotShelf }
    }

    private fun List<BookGroup>.withSystemGroups(): List<BookGroup> {
        val persistedById = associateBy { it.groupId }
        val merged = getBookGroupsUseCase.createSystemGroups().map { system ->
            persistedById[system.groupId] ?: system
        } + filter { it.groupId > 0 }
        return merged.distinctBy { it.groupId }.sortedBy { it.order }
    }

    private fun List<BookGroup>.visibleForBooks(books: List<Book>): List<BookGroup> {
        val customGroupMask = asSequence()
            .filter { it.groupId > 0 }
            .fold(0L) { mask, group -> mask or group.groupId }
        return filter { group ->
            group.show && when (group.groupId) {
                BookGroup.ID_ALL -> true
                BookGroup.ID_LOCAL -> books.any { it.isLocal }
                BookGroup.ID_AUDIO -> books.any { it.isAudio }
                BookGroup.ID_NET_NONE -> books.any { !it.isAudio && !it.isLocal && (it.group and customGroupMask) == 0L }
                BookGroup.ID_LOCAL_NONE -> books.any { it.isLocal && (it.group and customGroupMask) == 0L }
                BookGroup.ID_ERROR -> books.any { it.hasType(BookType.UPDATE_ERROR) }
                else -> group.groupId > 0 && books.any { it.group and group.groupId != 0L }
            }
        }.sortedBy { it.order }
    }
}

data class BookshelfBatchUpdateResult(
    val updatedCount: Int,
    val failedCount: Int,
)

data class BookshelfImportResult(
    val addedCount: Int,
    val skippedCount: Int,
    val failedCount: Int,
)

data class BookshelfBatchChangeSourceResult(
    val updatedCount: Int,
    val skippedCount: Int,
    val failedCount: Int,
)

data class BookshelfBatchSourceChangeRequestResult(
    val result: BookshelfBatchChangeSourceResult? = null,
    val errorMessage: String? = null,
    val isCancelled: Boolean = false,
)

private data class ParsedLocalBook(
    val book: Book,
    val chapters: List<BookChapter>,
)

@Serializable
data class BookshelfExchangeBook(
    val name: String,
    val author: String = "",
    val intro: String? = null,
)
