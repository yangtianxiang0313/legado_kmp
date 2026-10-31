package io.legado.kmp.shared.facade

import io.legado.kmp.shared.bootstrap.SharedBootstrap
import io.legado.kmp.shared.domain.localbook.EpubBookParser
import io.legado.kmp.shared.domain.localbook.LocalBookFileBinding
import io.legado.kmp.shared.domain.localbook.LocalBookFileStore
import io.legado.kmp.shared.domain.localbook.MobiBookParser
import io.legado.kmp.shared.domain.localbook.MobiChapterIdentity
import io.legado.kmp.shared.domain.localbook.PdfBookParser
import io.legado.kmp.shared.domain.localbook.TxtBookParser
import io.legado.kmp.shared.domain.localbook.UmdBookParser
import io.legado.kmp.shared.domain.localbook.hashBookArchiveSource
import io.legado.kmp.shared.domain.repository.BookChapterRepository
import io.legado.kmp.shared.domain.repository.BookRepository
import io.legado.kmp.shared.domain.usecase.GetTxtTocRulesUseCase
import io.legado.kmp.shared.domain.usecase.ApplyReplaceRulesUseCase
import io.legado.kmp.shared.domain.usecase.resolveDisplayChapterTitle
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.TxtTocRule
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import org.koin.mp.KoinPlatformTools

/** Explicitly reattach an immutable original; never infer a book match from its filename. */
class LocalBookRelinkFacade(
    private val books: BookRepository,
    private val chapters: BookChapterRepository,
    private val files: LocalBookFileStore,
    private val txt: TxtBookParser,
    private val tocRules: GetTxtTocRulesUseCase,
    private val epub: EpubBookParser,
    private val umd: UmdBookParser,
    private val mobi: MobiBookParser,
    private val pdf: PdfBookParser,
    private val replaceRules: ApplyReplaceRulesUseCase,
) {
    companion object {
        @Throws(RecoverableSharedException::class)
        fun create(): LocalBookRelinkFacade = try {
            SharedBootstrap.startOrThrow()
            KoinPlatformTools.defaultContext().get().get<LocalBookRelinkFacade>()
        } catch (error: Exception) {
            throw error.asRecoverableSharedException("LocalBookRelinkFacade.create")
        }
    }

    fun prepareRelinkRequest(
        bookUrl: String,
        path: String,
        onResult: (LocalBookImportRequestResult) -> Unit,
    ): LocalBookImportRequest = LocalBookImportRequest.create(
        performImport = { relinkLocalFile(bookUrl, path) },
        onResult = onResult,
    )

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun relinkLocalFile(bookUrl: String, path: String): Book = runRecoverable("LocalBook.relink") {
        val context = currentCoroutineContext()
        context.ensureActive()
        val original = requireNotNull(books.getBook(bookUrl)) { "原书已不在书架中" }
        require(original.isLocal) { "只能为本地书重新选择原文件" }
        val key = requireNotNull(LocalBookFileBinding.retainedKey(path)) { "请先安全留存所选原文件" }
        val format = LocalBookFileBinding.format(original)
        val selectedFormat = key.substringBefore('-')
        require(format.isNotEmpty() && compatibleFormat(format, selectedFormat)) { "所选文件格式与原书不一致" }
        LocalBookFileBinding.retainedKeyForBook(original)?.let { previousKey ->
            require(previousKey.substringBefore('/').substringAfter('-') == key.substringBefore('/').substringAfter('-')) {
                "所选文件与原留存文件的指纹不一致，请选择同一本原文件"
            }
        }
        val previous = chapters.getChaptersByBookUrl(bookUrl).sortedBy { it.index }
        context.ensureActive()
        val bound = LocalBookFileBinding.bind(original, path)
        // No database/cache writes during parsing. Cancellation cannot hide a later committed binding.
        val prepared = withContext(Dispatchers.Default) {
            val parseContext = currentCoroutineContext()
            val modified = requireNotNull(files.lastModified(path)) { "所选原文件已不可读取" }
            val catalog = parse(bound, selectedFormat).sortedBy { it.index }
            parseContext.ensureActive()
            val source = files.openRead(path)
            val digest = try {
                hashBookArchiveSource(source, Long.MAX_VALUE) { parseContext.ensureActive() }
            } finally {
                source.closeSource()
            }
            check(digest.size > 0L && digest.sha256 == key.substringBefore('/').substringAfter('-')) {
                "所选原文件校验失败，请重新选择"
            }
            check(files.lastModified(path) == modified) { "所选原文件在解析期间发生变化，请重新选择" }
            val retained = if (previous.isEmpty()) {
                if (original.config.reverseToc) catalog.asReversed().mapIndexed { index, chapter ->
                    chapter.copy(index = index)
                } else catalog
            } else {
                val identified = if (selectedFormat in setOf("mobi", "azw", "azw3")) {
                    MobiChapterIdentity.retain(previous, catalog) { parseContext.ensureActive() }
                } else catalog
                val candidates = identified.associateBy { it.url }
                require(catalog.size == previous.size && previous.all { old ->
                    candidates[old.url]?.let { sameReadingBoundary(old, it) } == true
                }) { "所选文件目录与原目录不一致；原书、书签和已编辑正文均未改动" }
                previous
            }
            validateProgress(original, retained)
            Prepared(bound, retained, modified)
        }
        context.ensureActive()
        books.relinkLocalFileIfUnchanged(
            original, previous, checkNotNull(prepared.book.variable), prepared.chapters, prepared.modified,
        ) ?: error("原书或阅读位置已变化，请重新选择原文件")
    }

    private suspend fun parse(book: Book, format: String): List<BookChapter> = when (format) {
        "txt" -> {
            val source = files.openRead(LocalBookFileBinding.path(book))
            try {
                val rules = if (book.tocUrl.isBlank()) tocRules.getEnabled()
                else listOf(TxtTocRule(name = "原书目录", rule = book.tocUrl))
                val context = currentCoroutineContext()
                txt.parseSource(book, source, rules) { context.ensureActive() }.chapters
            } finally {
                source.closeSource()
            }
        }
        "epub" -> epub.parse(book).chapters
        "umd" -> umd.parse(book, files.read(LocalBookFileBinding.path(book))).chapters
        "mobi", "azw", "azw3" -> mobi.parse(book).chapters
        "pdf" -> pdf.parse(book).chapters
        else -> error("不支持此原文件格式")
    }

    private suspend fun validateProgress(book: Book, catalog: List<BookChapter>) {
        require(catalog.isNotEmpty() && book.durChapterIndex in catalog.indices && book.durChapterPos >= 0) {
            "所选文件无法承接原阅读位置，请选择原文件"
        }
        val title = book.durChapterTitle?.filterNot(Char::isWhitespace).orEmpty()
        if (title.isNotEmpty() && (book.durChapterIndex > 0 || book.durChapterPos > 0)) {
            val chapter = catalog[book.durChapterIndex]
            val rawTitle = chapter.getDisplayTitle().filterNot(Char::isWhitespace)
            val displayTitle = if (rawTitle == title) rawTitle else {
                resolveDisplayChapterTitle(book, chapter, replaceRules).filterNot(Char::isWhitespace)
            }
            require(rawTitle == title || displayTitle == title) {
                "所选文件的当前章节与原阅读记录不一致，请选择原文件"
            }
        }
    }

    private fun sameReadingBoundary(old: BookChapter, next: BookChapter): Boolean =
        old.title == next.title && old.isVolume == next.isVolume && old.start == next.start &&
            old.end == next.end && old.startFragmentId == next.startFragmentId &&
            old.endFragmentId == next.endFragmentId && old.resourceUrl == next.resourceUrl

    private fun compatibleFormat(original: String, selected: String): Boolean = original == selected ||
        original in setOf("mobi", "azw", "azw3") && selected in setOf("mobi", "azw", "azw3")

    private data class Prepared(val book: Book, val chapters: List<BookChapter>, val modified: Long)
}
