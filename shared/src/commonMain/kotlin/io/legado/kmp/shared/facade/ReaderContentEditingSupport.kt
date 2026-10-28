package io.legado.kmp.shared.facade

import io.legado.kmp.shared.domain.repository.ChapterContentRepository
import io.legado.kmp.shared.domain.usecase.ApplyReplaceRulesUseCase
import io.legado.kmp.shared.domain.usecase.GetBookUseCase
import io.legado.kmp.shared.domain.usecase.ObserveBookChaptersUseCase
import io.legado.kmp.shared.domain.usecase.SaveChaptersUseCase
import io.legado.kmp.shared.domain.usecase.resolveDisplayChapterTitle
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.first

internal class ReaderContentEditingSupport(
    private val getBookUseCase: GetBookUseCase,
    private val observeChapters: ObserveBookChaptersUseCase,
    private val saveChapters: SaveChaptersUseCase,
    private val contentRepository: ChapterContentRepository,
    private val applyReplaceRules: ApplyReplaceRulesUseCase,
    private val loader: ReaderChapterLoader,
) {
    suspend fun save(bookUrl: String, index: Int, content: String, expectedUrl: String? = null) {
        val (book, chapter) = target(bookUrl, index, expectedUrl)
        coroutineContext.ensureActive()
        // Android ignores an empty edit; a nonempty failed write must never look successful.
        if (content.isNotEmpty()) {
            check(contentRepository.saveContent(book, chapter, content)) { "Failed to save edited chapter cache" }
        }
    }

    suspend fun saveChecked(bookUrl: String, index: Int, expectedUrl: String, content: String): ReaderChapterPayload {
        save(bookUrl, index, content, expectedUrl)
        return prepareChecked(bookUrl, index, expectedUrl, refresh = false)
    }

    suspend fun resetChecked(bookUrl: String, index: Int, expectedUrl: String): ReaderChapterPayload {
        return prepareChecked(bookUrl, index, expectedUrl, refresh = true)
    }

    suspend fun rename(bookUrl: String, index: Int, expectedUrl: String, title: String): ReaderChapterPayload {
        val (book, chapter) = target(bookUrl, index, expectedUrl)
        if (chapter.title != title) {
            val chapters = observeChapters(bookUrl).first()
            coroutineContext.ensureActive()
            require(chapters.any { it.index == index && it.url == expectedUrl && it.title == chapter.title }) {
                "Chapter changed; reopen the content editor"
            }
            // Legacy file names include the title. Publish URL addressing before metadata changes.
            contentRepository.prepareForChapterReorder(book, chapters)
            coroutineContext.ensureActive()
            target(bookUrl, index, expectedUrl)
            saveChapters.renameTitle(bookUrl, index, expectedUrl, title)
        }
        return prepareChecked(bookUrl, index, expectedUrl, refresh = false)
    }

    suspend fun processedCachedContent(bookUrl: String, index: Int): String {
        val (book, chapter) = target(bookUrl, index, expectedUrl = null)
        val content = contentRepository.getContent(book, chapter) ?: return ""
        val title = resolveDisplayChapterTitle(book, chapter, applyReplaceRules)
        val useReplace = book.config.useReplaceRule ?: loader.defaultUseReplaceRule(book)
        return loader.processContent(book, chapter, content, title, useReplace).content
    }

    private suspend fun prepareChecked(
        bookUrl: String, index: Int, expectedUrl: String, refresh: Boolean,
    ): ReaderChapterPayload {
        target(bookUrl, index, expectedUrl)
        val payload = loader.prepareChapter(bookUrl, index, refresh).payload
        require(payload.chapter.url == expectedUrl && payload.chapter.index == index) {
            "Chapter changed; reopen the content editor"
        }
        return payload
    }

    private suspend fun target(bookUrl: String, index: Int, expectedUrl: String?): Pair<Book, BookChapter> {
        coroutineContext.ensureActive()
        val book = if (expectedUrl == null) loader.requireBook(bookUrl)
            else requireNotNull(getBookUseCase.get(bookUrl)) { "Book no longer exists" }
        val chapters = observeChapters(bookUrl).first()
        coroutineContext.ensureActive()
        require(chapters.isNotEmpty()) { "No chapters found for $bookUrl" }
        val chapter = if (expectedUrl == null) chapters[index.coerceIn(0, chapters.lastIndex)]
            else chapters.singleOrNull { it.index == index && it.url == expectedUrl }
        requireNotNull(chapter) { "Chapter changed; reopen the content editor" }
        return book to chapter
    }
}
