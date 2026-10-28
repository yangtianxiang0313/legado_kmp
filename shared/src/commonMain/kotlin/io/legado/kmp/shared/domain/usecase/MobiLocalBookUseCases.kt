package io.legado.kmp.shared.domain.usecase

import io.legado.kmp.shared.domain.localbook.LocalBookFileResolver
import io.legado.kmp.shared.domain.localbook.MobiBookParser
import io.legado.kmp.shared.domain.localbook.ParsedMobiBook
import io.legado.kmp.shared.domain.localbook.MobiChapterIdentity
import io.legado.kmp.shared.domain.localbook.MobiReadingSpan
import io.legado.kmp.shared.domain.repository.BookChapterRepository
import io.legado.kmp.shared.domain.repository.ChapterContentRepository
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.getCacheFolderName
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

class ParseMobiLocalFileUseCase(
    private val localBookFileResolver: LocalBookFileResolver,
    private val mobiBookParser: MobiBookParser,
    private val chapters: BookChapterRepository? = null,
    private val content: ChapterContentRepository? = null,
) {
    suspend operator fun invoke(book: Book): ParsedMobiBook {
        val context = currentCoroutineContext()
        context.ensureActive()
        val parsed = mobiBookParser.parse(localBookFileResolver.resolve(book))
        val previous = chapters?.getChaptersByBookUrl(book.bookUrl).orEmpty()
        if (previous.isEmpty()) return parsed
        val previousByUrl = previous.associateBy { it.url }
        val retained = MobiChapterIdentity.retain(previous, parsed.chapters) { context.ensureActive() }
        val byUrl = retained.associateBy { it.url }
        val cache = content
        if (cache != null) {
            for (old in previous) {
                context.ensureActive()
                val next = byUrl[old.url]
                if (cache.hasContent(book, old) || !cache.removeSameTitle(book, old)) {
                    check(next != null && MobiReadingSpan.of(next) == MobiReadingSpan.of(old)) {
                        "MOBI 章节边界已变化，无法安全保留已编辑正文或标题标记；原目录未改动"
                    }
                    check(book.getCacheFolderName() == parsed.book.getCacheFolderName()) {
                        "MOBI 书名变化会改变已有正文缓存位置，原目录未改动"
                    }
                }
            }
            if (retained.any { next ->
                    val old = previousByUrl[next.url]
                    old != null && (old.index != next.index || old.title != next.title)
                }) {
                // Publish stable URL addressing before either the old or new index can name another body's cache.
                cache.prepareForChapterReorder(book, previous)
            }
        }
        context.ensureActive()
        return parsed.copy(chapters = retained)
    }
}

class LoadMobiLocalChapterContentUseCase(
    private val localBookFileResolver: LocalBookFileResolver,
    private val mobiBookParser: MobiBookParser
) {
    suspend operator fun invoke(book: Book, chapter: BookChapter): String {
        return mobiBookParser.readContent(localBookFileResolver.resolve(book), chapter)
    }
}
