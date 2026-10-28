package io.legado.kmp.shared.facade

import io.legado.kmp.shared.bootstrap.SharedBootstrap
import io.legado.kmp.shared.domain.repository.BookChapterRepository
import io.legado.kmp.shared.domain.repository.BookRepository
import io.legado.kmp.shared.domain.repository.ChapterContentRepository
import io.legado.kmp.shared.domain.usecase.ApplyReplaceRulesUseCase
import io.legado.kmp.shared.domain.usecase.LoadEpubLocalChapterContentUseCase
import io.legado.kmp.shared.domain.usecase.LoadMobiLocalChapterContentUseCase
import io.legado.kmp.shared.domain.usecase.LoadTxtLocalChapterContentUseCase
import io.legado.kmp.shared.domain.usecase.LoadUmdLocalChapterContentUseCase
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import org.koin.mp.KoinPlatformTools

/** Read-only export of the stored directory; never refreshes or persists reading state. */
class BookExportFacade(
    bookRepository: BookRepository,
    chapterRepository: BookChapterRepository,
    contentRepository: ChapterContentRepository,
    images: BookImageFacade,
    loadTxtContent: LoadTxtLocalChapterContentUseCase,
    loadEpubContent: LoadEpubLocalChapterContentUseCase,
    loadUmdContent: LoadUmdLocalChapterContentUseCase,
    loadMobiContent: LoadMobiLocalChapterContentUseCase,
    applyReplaceRules: ApplyReplaceRulesUseCase? = null,
) {
    private val engine = BookExportEngine(
        bookRepository,
        chapterRepository,
        contentRepository,
        images,
        BookExportLocalContent(loadTxtContent, loadEpubContent, loadUmdContent, loadMobiContent),
        applyReplaceRules?.let { BookExportContentTransform(it) },
    )

    companion object {
        @Throws(RecoverableSharedException::class)
        fun create(): BookExportFacade = try {
            SharedBootstrap.startOrThrow()
            KoinPlatformTools.defaultContext().get().get<BookExportFacade>()
        } catch (error: Exception) {
            findFacadeRequestCancellation(error)?.let { throw it }
            throw RecoverableSharedException("BookExportFacade.create", "书籍导出服务不可用，请重试")
        }
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun prepare(
        bookUrl: String,
        format: String,
        onProgress: (BookExportProgress) -> Unit,
    ): BookExportResult = try {
        withContext(Dispatchers.Default) { engine.prepare(bookUrl, format, onProgress) }
    } catch (error: Throwable) {
        currentCoroutineContext().ensureActive()
        findFacadeRequestCancellation(error)?.let { throw it }
        // Repository/parser errors may contain URLs, local paths or chapter bodies.
        throw RecoverableSharedException("BookExportFacade.prepare", bookExportErrorMessage(error))
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun prepareConfigured(
        bookUrl: String,
        format: String,
        options: BookExportOptions,
        onProgress: (BookExportProgress) -> Unit,
    ): BookExportBatchResult = try {
        withContext(Dispatchers.Default) { engine.prepareConfigured(bookUrl, format, options, onProgress) }
    } catch (error: Throwable) {
        currentCoroutineContext().ensureActive()
        findFacadeRequestCancellation(error)?.let { throw it }
        throw RecoverableSharedException("BookExportFacade.prepareConfigured", bookExportConfiguredErrorMessage(error))
    }

    /** The callback is delivered only after the Kotlin job, including local file access, has ended. */
    fun prepareRequest(
        bookUrl: String,
        format: String,
        onProgress: (BookExportProgress) -> Unit,
        onResult: (BookExportRequestResult) -> Unit,
    ): FlowSubscription = CancellableFacadeRequest.start(
        prepare = { BookExportRequestResult(export = prepare(bookUrl, format, onProgress)) },
        cancelledResult = BookExportRequestResult(isCancelled = true),
        failureResult = { BookExportRequestResult(errorMessage = bookExportErrorMessage(it)) },
        onResult = { result ->
            try {
                onResult(result)
            } catch (_: Throwable) {
                // Foreign callbacks must not send exported contents or paths to crash logs.
            }
        },
        facade = "BookExportFacade",
        callbackMethod = "prepareRequest.onResult",
        missingResultMessage = "Book export completed without a result",
    )

    /** No part is delivered until the entire batch and its Kotlin job have completed. */
    fun prepareConfiguredRequest(
        bookUrl: String,
        format: String,
        options: BookExportOptions,
        onProgress: (BookExportProgress) -> Unit,
        onResult: (BookExportBatchRequestResult) -> Unit,
    ): FlowSubscription = CancellableFacadeRequest.start(
        prepare = {
            BookExportBatchRequestResult(export = prepareConfigured(bookUrl, format, options, onProgress))
        },
        cancelledResult = BookExportBatchRequestResult(isCancelled = true),
        failureResult = { BookExportBatchRequestResult(errorMessage = bookExportConfiguredErrorMessage(it)) },
        onResult = { result ->
            try {
                onResult(result)
            } catch (_: Throwable) {
                // Foreign callbacks must not send exported contents or paths to crash logs.
            }
        },
        facade = "BookExportFacade",
        callbackMethod = "prepareConfiguredRequest.onResult",
        missingResultMessage = "Book export batch completed without a result",
    )
}

internal class BookExportFailure(message: String) : Exception(message)

internal fun requireBookExport(condition: Boolean, message: String) {
    if (!condition) throw BookExportFailure(message)
}

internal fun bookExportErrorMessage(error: Throwable): String = when {
    error is BookExportFailure -> error.message ?: "书籍导出失败"
    error is RecoverableSharedException && error.code == "BookExportFacade.prepare" -> error.message
    else -> "书籍导出失败，请检查本地文件或已有缓存后重试"
}

private fun bookExportConfiguredErrorMessage(error: Throwable): String =
    if (error is RecoverableSharedException && error.code == "BookExportFacade.prepareConfigured") {
        error.message
    } else bookExportErrorMessage(error)
