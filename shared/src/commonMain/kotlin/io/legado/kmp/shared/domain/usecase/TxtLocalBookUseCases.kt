package io.legado.kmp.shared.domain.usecase

import io.legado.kmp.shared.domain.localbook.LocalBookByteSource
import io.legado.kmp.shared.domain.localbook.LocalBookFileResolver
import io.legado.kmp.shared.domain.localbook.ParsedTxtBook
import io.legado.kmp.shared.domain.localbook.TxtBookParser
import io.legado.kmp.shared.domain.localbook.TxtChapterIdentity
import io.legado.kmp.shared.domain.repository.BookChapterRepository
import io.legado.kmp.shared.domain.repository.ChapterContentRepository
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.getCacheFolderName
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

class ParseTxtBookUseCase(
    private val parser: TxtBookParser,
    private val getTxtTocRules: GetTxtTocRulesUseCase
) {
    suspend operator fun invoke(book: Book, bytes: ByteArray): ParsedTxtBook {
        val rules = if (book.tocUrl.isBlank()) getTxtTocRules.getEnabled() else emptyList()
        return withContext(Dispatchers.Default) {
            val context = currentCoroutineContext()
            parser.parse(book, bytes, rules) { context.ensureActive() }
        }
    }

    suspend fun parseSource(book: Book, source: LocalBookByteSource): ParsedTxtBook =
        parseSourceWithRule(book, source, book.tocUrl)

    /** Read-only override: null/blank means auto; a nonblank rule is forced even if disabled. */
    suspend fun parseSourceWithRule(
        book: Book,
        source: LocalBookByteSource,
        selectedRegex: String?
    ): ParsedTxtBook {
        val rules = if (selectedRegex.isNullOrBlank()) getTxtTocRules.getEnabled() else emptyList()
        return withContext(Dispatchers.Default) {
            val context = currentCoroutineContext()
            parser.parseSourceWithRule(book, source, rules, selectedRegex) { context.ensureActive() }
        }
    }
}

class LoadTxtChapterContentUseCase(
    private val parser: TxtBookParser
) {
    operator fun invoke(bytes: ByteArray, chapter: BookChapter, charsetName: String): String {
        return parser.readContent(bytes, chapter, charsetName)
    }
}

class ParseTxtLocalFileUseCase(
    private val localBookFileResolver: LocalBookFileResolver,
    private val parseTxtBook: ParseTxtBookUseCase,
    private val chapters: BookChapterRepository? = null,
    private val content: ChapterContentRepository? = null
) {
    suspend operator fun invoke(book: Book): ParsedTxtBook = withContext(Dispatchers.Default) {
        val context = currentCoroutineContext()
        context.ensureActive()
        val resolved = localBookFileResolver.openRead(book)
        val parsed = try {
            val modified = localBookFileResolver.lastModified(resolved.book)?.let {
                it > book.latestChapterTime
            } == true
            // Only a real file update may discard a stored rule; a cold directory rebuild must retain it.
            if (modified) {
                parseTxtBook.parseSourceWithRule(resolved.book, resolved.source, null)
            } else {
                parseTxtBook.parseSource(resolved.book, resolved.source)
            }
        } finally {
            resolved.source.closeSource()
        }
        context.ensureActive()
        val previous = chapters?.getChaptersByBookUrl(book.bookUrl).orEmpty()
        val retained = TxtChapterIdentity.retain(previous, parsed.chapters) { context.ensureActive() }
        val result = parsed.copy(chapters = retained)
        val cache = content
        if (cache == null || previous.isEmpty()) return@withContext result
        // Facades apply reverseToc after parsing; inspect their final indices without changing natural-order output.
        val nextDirectory = if (book.config.reverseToc) {
            retained.asReversed().mapIndexed { index, chapter ->
                context.ensureActive()
                chapter.copy(index = index)
            }
        } else {
            retained
        }
        if (sameDirectory(previous, nextDirectory) { context.ensureActive() }) return@withContext result

        val byUrl = nextDirectory.associateBy { it.url }
        for (old in previous) {
            context.ensureActive()
            // Local TXT hasContent is always true, even without an edited body on disk.
            val editedBody = cache.getContent(book, old) != null
            context.ensureActive()
            val titleMarker = !cache.removeSameTitle(book, old)
            context.ensureActive()
            if (editedBody || titleMarker) {
                val next = byUrl[old.url]
                check(next != null && TxtChapterIdentity.sameReadingSpan(old, next) && old.title == next.title) {
                    "TXT 章节边界或标题已变化，无法安全保留已编辑正文或标题标记；原目录未改动"
                }
                check(book.getCacheFolderName() == parsed.book.getCacheFolderName()) {
                    "TXT 书名变化会改变已有正文缓存位置，原目录未改动"
                }
            }
        }
        context.ensureActive()
        // Prepare every changed directory, even without cached edits: another scene may still save an old chapter.
        cache.prepareForChapterReorder(book, previous)
        context.ensureActive()
        result
    }

    private fun sameDirectory(
        previous: List<BookChapter>,
        next: List<BookChapter>,
        checkActive: () -> Unit
    ): Boolean {
        if (previous.size != next.size) return false
        return previous.indices.all { index ->
            checkActive()
            val old = previous[index]
            val chapter = next[index]
            old.url == chapter.url && old.bookUrl == chapter.bookUrl && old.index == chapter.index &&
                old.title == chapter.title && TxtChapterIdentity.sameReadingSpan(old, chapter)
        }
    }
}

class LoadTxtLocalChapterContentUseCase(
    private val localBookFileResolver: LocalBookFileResolver,
    private val parser: TxtBookParser
) {
    suspend operator fun invoke(book: Book, chapter: BookChapter): String = withContext(Dispatchers.Default) {
        val context = currentCoroutineContext()
        context.ensureActive()
        val resolved = localBookFileResolver.openRead(book)
        try {
            parser.readSourceContent(resolved.source, chapter, resolved.book.charset) { context.ensureActive() }
        } finally {
            resolved.source.closeSource()
        }
    }
}

class IsLocalBookModifiedUseCase(
    private val localBookFileResolver: LocalBookFileResolver
) {
    suspend operator fun invoke(book: Book): Boolean {
        if (!book.isLocal) return false
        val lastModified = localBookFileResolver.lastModified(book) ?: return false
        return lastModified > book.latestChapterTime
    }
}
