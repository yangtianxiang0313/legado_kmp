package io.legado.kmp.shared.facade

import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter

class PreparedBookSourceChange internal constructor(
    expectedBook: Book,
    book: Book,
    chapters: List<BookChapter>,
    private val ownerToken: Any,
) {
    private val expectedBook = expectedBook.sourceChangeSnapshot()
    private val preparedBook = book.sourceChangeSnapshot()
    private val preparedChapters = chapters.toList()
    private var consumed = false

    val originalBookUrl: String = expectedBook.bookUrl
    val book: Book get() = preparedBook.sourceChangeSnapshot()
    val chapters: List<BookChapter> get() = preparedChapters.toList()

    // The owning facade calls this only while holding bookSaveMutex.
    internal fun consume(ownerToken: Any): SourceChangeCommitSnapshot {
        require(this.ownerToken === ownerToken) { "Prepared source change belongs to another facade" }
        check(!consumed) { "Prepared source change has already been consumed" }
        val snapshot = SourceChangeCommitSnapshot(
            expectedBook = expectedBook.sourceChangeSnapshot(),
            book = preparedBook.sourceChangeSnapshot(),
            chapters = preparedChapters.toList(),
        )
        consumed = true
        return snapshot
    }
}

data class SourceChangePreparationResult(
    val prepared: PreparedBookSourceChange? = null,
    val errorCode: String? = null,
    val errorMessage: String? = null,
    val isCancelled: Boolean = false,
)

data class ChapterSourceChangeTocResult(
    val toc: ChapterSourceChangeToc? = null,
    val errorCode: String? = null,
    val errorMessage: String? = null,
    val isCancelled: Boolean = false,
)

internal data class SourceChangeCommitSnapshot(
    val expectedBook: Book,
    val book: Book,
    val chapters: List<BookChapter>,
)

internal object SourceChangePreparationRequest {
    fun start(
        prepare: suspend () -> PreparedBookSourceChange,
        onResult: (SourceChangePreparationResult) -> Unit,
    ): FlowSubscription = CancellableFacadeRequest.start(
        prepare = { SourceChangePreparationResult(prepared = prepare()) },
        cancelledResult = SourceChangePreparationResult(isCancelled = true),
        failureResult = ::failureResult,
        onResult = onResult,
        facade = "BookDetailFacade",
        callbackMethod = "prepareSourceChangeRequest.onResult",
        missingResultMessage = "Source change preparation completed without a result",
    )

    private fun failureResult(error: Throwable): SourceChangePreparationResult {
        val failure = error.asRecoverableSharedException("BookDetailFacade.prepareSourceChange")
        return SourceChangePreparationResult(errorCode = failure.code, errorMessage = failure.message)
    }
}

internal object ChapterSourceChangeTocRequest {
    fun start(
        load: suspend () -> ChapterSourceChangeToc,
        onResult: (ChapterSourceChangeTocResult) -> Unit,
    ): FlowSubscription = CancellableFacadeRequest.start(
        prepare = { ChapterSourceChangeTocResult(toc = load()) },
        cancelledResult = ChapterSourceChangeTocResult(isCancelled = true),
        failureResult = ::failureResult,
        onResult = onResult,
        facade = "BookDetailFacade",
        callbackMethod = "loadChapterSourceTocRequest.onResult",
        missingResultMessage = "Chapter source TOC request completed without a result",
    )

    private fun failureResult(error: Throwable): ChapterSourceChangeTocResult {
        val failure = error.asRecoverableSharedException("BookDetailFacade.loadChapterSourceToc")
        return ChapterSourceChangeTocResult(errorCode = failure.code, errorMessage = failure.message)
    }
}

internal fun Book.sourceChangeSnapshot(): Book {
    return copy(readConfig = readConfig?.copy()).withSourceChangeTransientFrom(this)
}

internal fun Book.withSourceChangeTransientFrom(other: Book): Book = also {
    it.infoHtml = other.infoHtml
    it.tocHtml = other.tocHtml
    it.downloadUrls = other.downloadUrls?.toList()
}
