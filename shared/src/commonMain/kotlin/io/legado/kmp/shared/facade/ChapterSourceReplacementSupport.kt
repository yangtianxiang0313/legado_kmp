package io.legado.kmp.shared.facade

import io.legado.kmp.shared.domain.repository.BookChapterRepository
import io.legado.kmp.shared.domain.repository.ChapterContentRepository
import io.legado.kmp.shared.domain.repository.WebBookChapterContent
import io.legado.kmp.shared.domain.usecase.GetBookSourcesUseCase
import io.legado.kmp.shared.domain.usecase.GetBookUseCase
import io.legado.kmp.shared.domain.usecase.LoadChapterContentUseCase
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.model.getCacheFolderName
import io.legado.kmp.shared.model.rule.BookInfoRule
import io.legado.kmp.shared.model.rule.ContentRule
import io.legado.kmp.shared.model.rule.ExploreRule
import io.legado.kmp.shared.model.rule.ReviewRule
import io.legado.kmp.shared.model.rule.SearchRule
import io.legado.kmp.shared.model.rule.TocRule
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

internal class ChapterSourceReplacementSupport(
    private val getBookUseCase: GetBookUseCase,
    private val bookChapterRepository: BookChapterRepository,
    private val getBookSourcesUseCase: GetBookSourcesUseCase,
    private val loadChapterContentUseCase: LoadChapterContentUseCase,
    private val contentRepository: ChapterContentRepository,
    private val fetchCandidate: suspend (Book, String, String) -> Pair<Book, List<BookChapter>>,
) {
    private val ownerToken = Any()
    private val consumeMutex = Mutex()

    /** No target body, bookshelf or progress writes; source network state keeps its existing side effects. */
    suspend fun prepare(
        bookUrl: String,
        currentChapterIndex: Int,
        candidateBookUrl: String,
        sourceUrl: String,
        candidateChapterIndex: Int,
    ): PreparedChapterSourceReplacement = runRecoverable("BookDetailFacade.prepareChapterSourceReplacement") {
        coroutineContext.ensureActive()
        if (currentChapterIndex < 0 || candidateChapterIndex < 0 ||
            bookUrl.isBlank() || candidateBookUrl.isBlank() || sourceUrl.isBlank()
        ) {
            replacementFailure("INVALID_REQUEST", "Chapter replacement requires valid URLs and chapter indices")
        }
        val book = getBookUseCase.get(bookUrl)
            ?: replacementFailure("BOOK_NOT_FOUND", "Chapter replacement book is no longer persisted")
        if (book.isLocal) {
            replacementFailure("LOCAL_BOOK", "Local books do not support chapter source replacement")
        }
        val chapter = bookChapterRepository.getChapter(bookUrl, currentChapterIndex)
            ?: replacementFailure("CHAPTER_NOT_FOUND", "Current chapter no longer exists")
        if (book.bookUrl != bookUrl || chapter.bookUrl != bookUrl || chapter.index != currentChapterIndex) {
            replacementFailure("CHAPTER_NOT_FOUND", "Current chapter does not match the requested target")
        }

        // A missing original source is valid: chapter replacement can recover an unreadable source.
        val originalSource = getBookSourcesUseCase.getByUrl(book.origin)
        val candidateSource = (if (sourceUrl == book.origin) originalSource else getBookSourcesUseCase.getByUrl(sourceUrl))
            ?: replacementFailure("SOURCE_NOT_FOUND", "Candidate book source no longer exists")
        if (candidateSource.bookSourceUrl != sourceUrl) {
            replacementFailure("SOURCE_NOT_FOUND", "Candidate book source does not match the request")
        }
        val target = ChapterSourceReplacementTargetSnapshot(book, chapter, originalSource, candidateSource)
        val expectedContent = contentRepository.getContent(book, chapter)
        coroutineContext.ensureActive()

        val (candidateBook, candidateChapters) = fetchCandidate(
            book.copy(readConfig = book.readConfig?.copy()), candidateBookUrl, sourceUrl,
        )
        coroutineContext.ensureActive()
        // Pre-update scripts may resolve a new book URL. Keep that real context, not the search URL.
        if (candidateBook.isLocal || candidateBook.bookUrl.isBlank() || candidateBook.origin != sourceUrl) {
            replacementFailure("CANDIDATE_MISMATCH", "Candidate book does not belong to the requested source")
        }
        val candidateChapter = candidateChapters.getOrNull(candidateChapterIndex)
            ?: replacementFailure("CANDIDATE_CHAPTER_NOT_FOUND", "Requested candidate chapter no longer exists")
        if (candidateChapter.index != candidateChapterIndex || candidateChapter.bookUrl != candidateBook.bookUrl) {
            replacementFailure("CANDIDATE_MISMATCH", "Candidate chapter does not match the requested index and book")
        }
        val loaded = loadChapterContentUseCase.loadWithChapter(candidateSource, candidateBook, candidateChapter).getOrThrow()
        coroutineContext.ensureActive()
        if (loaded.content.isBlank()) {
            replacementFailure("EMPTY_CONTENT", "Candidate chapter content is empty")
        }
        val (currentBook, currentChapter) = requireUnchanged(target)
        if (contentRepository.getContent(currentBook, currentChapter) != expectedContent) {
            replacementFailure("STALE_CONTENT", "Current chapter cache changed during preparation; prepare again")
        }
        coroutineContext.ensureActive()
        PreparedChapterSourceReplacement(
            snapshot = ChapterSourceReplacementCommitSnapshot(target, expectedContent, loaded),
            ownerToken = ownerToken,
        )
    }

    /** The facade must hold bookSaveMutex across this call. SQL and cache files are not one transaction. */
    suspend fun commit(prepared: PreparedChapterSourceReplacement): String =
        runRecoverable("BookDetailFacade.commitChapterSourceReplacement") {
            val snapshot = consumeMutex.withLock {
                coroutineContext.ensureActive()
                prepared.consume(ownerToken)
            }
            val (book, chapter) = requireUnchanged(snapshot.target)
            coroutineContext.ensureActive()
            // Only the short cache CAS is non-cancellable; never turn a completed write into cancellation.
            withContext(NonCancellable) {
                if (!contentRepository.replaceContentIfUnchanged(book, chapter, snapshot.expectedContent, snapshot.content)) {
                    replacementFailure("COMMIT_FAILED", "Chapter cache changed or replacement could not be saved; prepare again")
                }
                snapshot.content
            }
        }

    private suspend fun requireUnchanged(target: ChapterSourceReplacementTargetSnapshot): Pair<Book, BookChapter> {
        val book = getBookUseCase.get(target.bookUrl)
        if (!target.matchesBook(book)) {
            replacementFailure("STALE_BOOK", "Book was removed or its chapter replacement target changed; prepare again")
        }
        val chapter = bookChapterRepository.getChapter(target.bookUrl, target.chapterIndex)
        if (!target.matchesChapter(chapter)) {
            replacementFailure("STALE_CHAPTER", "Current chapter was removed or changed; prepare again")
        }
        val originalSource = getBookSourcesUseCase.getByUrl(target.originalSourceUrl)
        if (!target.matchesOriginalSource(originalSource)) {
            replacementFailure("STALE_ORIGINAL_SOURCE", "Original source rules changed or the source was added or removed; prepare again")
        }
        val candidateSource = if (target.candidateSourceUrl == target.originalSourceUrl) {
            originalSource
        } else {
            getBookSourcesUseCase.getByUrl(target.candidateSourceUrl)
        }
        if (!target.matchesCandidateSource(candidateSource)) {
            replacementFailure("STALE_CANDIDATE_SOURCE", "Candidate source rules changed or the source was removed; prepare again")
        }
        return checkNotNull(book) to checkNotNull(chapter)
    }
}

internal class ChapterSourceReplacementCommitSnapshot(
    val target: ChapterSourceReplacementTargetSnapshot,
    val expectedContent: String?,
    // Retain real candidate metadata privately, without writing its title/variables into the target row.
    private val candidateContent: WebBookChapterContent,
) {
    val content: String get() = candidateContent.content

    override fun toString(): String = "ChapterSourceReplacementCommitSnapshot(redacted)"
}

internal class ChapterSourceReplacementTargetSnapshot(
    book: Book,
    chapter: BookChapter,
    originalSource: BookSource?,
    candidateSource: BookSource,
) {
    val bookUrl: String = book.bookUrl
    val chapterIndex: Int = chapter.index
    val chapterUrl: String = chapter.url
    val originalSourceUrl: String = book.origin
    val candidateSourceUrl: String = candidateSource.bookSourceUrl

    private val bookSnapshot = ReplacementBookSnapshot(book)
    private val chapterSnapshot = ReplacementChapterSnapshot(chapter)
    private val originalSourceRules = originalSource?.let(::ReplacementSourceRules)
    private val candidateSourceRules = ReplacementSourceRules(candidateSource)

    fun matchesBook(book: Book?): Boolean =
        book != null && !book.isLocal && ReplacementBookSnapshot(book) == bookSnapshot

    fun matchesChapter(chapter: BookChapter?): Boolean =
        chapter != null && ReplacementChapterSnapshot(chapter) == chapterSnapshot

    fun matchesOriginalSource(source: BookSource?): Boolean =
        source?.let(::ReplacementSourceRules) == originalSourceRules

    fun matchesCandidateSource(source: BookSource?): Boolean =
        source != null && ReplacementSourceRules(source) == candidateSourceRules

    override fun toString(): String = "ChapterSourceReplacementTargetSnapshot(redacted)"
}

// Do not compare Book/BookChapter directly: their equals implementations only compare URLs.
private data class ReplacementBookSnapshot(
    val bookUrl: String,
    val origin: String,
    val tocUrl: String,
    val type: Int,
    val cacheFolder: String,
    val name: String,
    val author: String,
    val reverseToc: Boolean,
) {
    constructor(book: Book) : this(
        book.bookUrl, book.origin, book.tocUrl, book.type, book.getCacheFolderName(),
        book.name, book.author, book.config.reverseToc,
    )
}

private data class ReplacementChapterSnapshot(
    val bookUrl: String,
    val index: Int,
    val url: String,
    val title: String,
    val baseUrl: String,
    val resourceUrl: String?,
    val isVolume: Boolean,
    val isVip: Boolean,
    val isPay: Boolean,
    val tag: String?,
    val start: Long?,
    val end: Long?,
    val startFragmentId: String?,
    val endFragmentId: String?,
    val variable: String?,
) {
    constructor(chapter: BookChapter) : this(
        chapter.bookUrl, chapter.index, chapter.url, chapter.title, chapter.baseUrl, chapter.resourceUrl,
        chapter.isVolume, chapter.isVip, chapter.isPay, chapter.tag, chapter.start, chapter.end,
        chapter.startFragmentId, chapter.endFragmentId, chapter.variable,
    )
}

// Rules contain mutable properties: copy them at capture time, excluding only source bookkeeping/display state.
private data class ReplacementSourceRules(
    val url: String,
    val type: Int,
    val bookUrlPattern: String?,
    val jsLib: String?,
    val cookieJar: Boolean,
    val concurrentRate: String?,
    val header: String?,
    val loginUrl: String?,
    val loginUi: String?,
    val loginCheckJs: String?,
    val coverDecodeJs: String?,
    val exploreUrl: String?,
    val exploreScreen: String?,
    val explore: ExploreRule?,
    val searchUrl: String?,
    val search: SearchRule?,
    val bookInfo: BookInfoRule?,
    val toc: TocRule?,
    val content: ContentRule?,
    val review: ReviewRule?,
) {
    constructor(source: BookSource) : this(
        source.bookSourceUrl, source.bookSourceType, source.bookUrlPattern, source.jsLib,
        source.enabledCookieJar, source.concurrentRate, source.header, source.loginUrl, source.loginUi,
        source.loginCheckJs, source.coverDecodeJs, source.exploreUrl, source.exploreScreen,
        source.ruleExplore?.copy(), source.searchUrl, source.ruleSearch?.copy(), source.ruleBookInfo?.copy(),
        source.ruleToc?.copy(), source.ruleContent?.copy(), source.ruleReview?.copy(),
    )
}

private fun replacementFailure(code: String, message: String): Nothing =
    throw RecoverableSharedException("CHAPTER_SOURCE_REPLACEMENT_$code", message)
