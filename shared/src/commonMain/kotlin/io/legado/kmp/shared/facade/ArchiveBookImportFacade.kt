package io.legado.kmp.shared.facade

import io.legado.kmp.shared.bootstrap.SharedBootstrap
import io.legado.kmp.shared.domain.localbook.ArchiveBookListing
import io.legado.kmp.shared.domain.localbook.LocalBookFileNameResolver
import io.legado.kmp.shared.domain.localbook.RetainedArchiveBookStorage
import io.legado.kmp.shared.domain.usecase.GetBooksUseCase
import io.legado.kmp.shared.domain.usecase.ParseEpubLocalFileUseCase
import io.legado.kmp.shared.domain.usecase.ParseTxtLocalFileUseCase
import io.legado.kmp.shared.domain.usecase.ParsePdfLocalFileUseCase
import io.legado.kmp.shared.domain.usecase.ParseUmdLocalFileUseCase
import io.legado.kmp.shared.domain.usecase.ParseMobiLocalFileUseCase
import io.legado.kmp.shared.domain.usecase.SaveBookUseCase
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookType
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import org.koin.mp.KoinPlatformTools

data class ArchiveBookPreparationResult(
    val archive: ArchiveBookListing?,
    val errorMessage: String?,
    val isCancelled: Boolean,
)

/** Shared ZIP/RAR/7z import entry point. Platform callers first stage security-scoped external files. */
class ArchiveBookImportFacade(
    private val storage: RetainedArchiveBookStorage,
    private val books: GetBooksUseCase,
    private val saveBook: SaveBookUseCase,
    private val parseTxt: ParseTxtLocalFileUseCase,
    private val parseEpub: ParseEpubLocalFileUseCase,
    private val parsePdf: ParsePdfLocalFileUseCase,
    private val parseUmd: ParseUmdLocalFileUseCase,
    private val parseMobi: ParseMobiLocalFileUseCase,
    private val localBookFileNameResolver: LocalBookFileNameResolver = LocalBookFileNameResolver(),
) {
    companion object {
        /** Kept here so a new facade does not require changing platform bootstrap entry points. */
        @Throws(RecoverableSharedException::class)
        fun create(): ArchiveBookImportFacade = try {
            SharedBootstrap.startOrThrow()
            KoinPlatformTools.defaultContext().get().get<ArchiveBookImportFacade>()
        } catch (error: Exception) {
            throw error.asRecoverableSharedException("ArchiveBookImportFacade.create")
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun prepareArchive(path: String): ArchiveBookListing = runRecoverable("ArchiveBook.prepare") {
        storage.prepare(path)
    }

    /** Cancellation always produces a terminal callback, after all source-file access has ended. */
    fun prepareArchiveRequest(
        path: String,
        onResult: (ArchiveBookPreparationResult) -> Unit,
    ): FlowSubscription = CancellableFacadeRequest.start(
        prepare = { ArchiveBookPreparationResult(prepareArchive(path), null, false) },
        cancelledResult = ArchiveBookPreparationResult(null, null, true),
        failureResult = { ArchiveBookPreparationResult(null, it.message ?: "压缩包导入失败", false) },
        onResult = onResult,
        facade = "ArchiveBookImportFacade",
        callbackMethod = "prepareArchiveRequest.onResult",
        missingResultMessage = "Archive preparation completed without a result",
    )

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun importEntry(archiveId: String, entryPath: String, groupId: Long = 0): Book =
        runRecoverable("ArchiveBook.importEntry") {
            storage.withExtractedEntry(archiveId, entryPath) { extracted ->
                currentCoroutineContext().ensureActive()
                val path = extracted.path
                val allBooks = books.getAll()
                val key = checkNotNull(storage.storageKey(path)) { "压缩书籍生成路径无效" }
                allBooks.firstOrNull { it.isLocal && storage.storageKey(it.bookUrl) == key }?.let {
                    storage.requireIdentity(it, extracted.identity)
                    currentCoroutineContext().ensureActive()
                    return@withExtractedEntry it
                }
                val name = entryPath.substringAfterLast('/')
                val nameAuthor = localBookFileNameResolver.resolve(name)
                val extension = name.substringAfterLast('.').lowercase()
                val draft = Book(
                    bookUrl = path,
                    origin = extracted.origin,
                    originName = name,
                    name = nameAuthor.name,
                    author = nameAuthor.author,
                    type = when (extension) {
                        "epub" -> BookType.EPUB
                        "txt" -> BookType.TEXT
                        else -> BookType.LOCAL
                    },
                    group = groupId.coerceAtLeast(0),
                    order = ((allBooks.minOfOrNull { it.order } ?: 0).toLong() - 1)
                        .coerceAtLeast(Int.MIN_VALUE.toLong()).toInt(),
                )
                val (book, chapters) = withContext(Dispatchers.Default) {
                    when (extension) {
                        "txt" -> parseTxt(draft).let { it.book to it.chapters }
                        "epub" -> parseEpub(draft).let { it.book to it.chapters }
                        "pdf" -> parsePdf(draft).let { it.book to it.chapters }
                        "umd" -> parseUmd(draft).let { it.book to it.chapters }
                        "mobi", "azw", "azw3" -> parseMobi(draft).let { it.book to it.chapters }
                        else -> error("Unsupported archive book format: $extension")
                    }
                }
                currentCoroutineContext().ensureActive()
                // The origin is committed with the book and chapters, never in a second progress-resetting write.
                saveBook.insertLocalBookIfAbsent(
                    book.copy(origin = draft.origin, originName = name, group = draft.group, order = draft.order),
                    chapters,
                )
            }
        }

    /** Install cancellation before start(); a successful database commit wins over a late cancel. */
    fun prepareEntryImportRequest(
        archiveId: String,
        entryPath: String,
        groupId: Long = 0,
        onResult: (LocalBookImportRequestResult) -> Unit,
    ): LocalBookImportRequest = LocalBookImportRequest.create(
        performImport = { importEntry(archiveId, entryPath, groupId) },
        onResult = onResult,
    )

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun recoverBook(book: Book): Book? = runRecoverable("ArchiveBook.recover") { storage.recover(book) }
}
