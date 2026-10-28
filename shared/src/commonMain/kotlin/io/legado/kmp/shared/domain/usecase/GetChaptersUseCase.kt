package io.legado.kmp.shared.domain.usecase

import io.legado.kmp.shared.domain.repository.BookChapterRepository
import io.legado.kmp.shared.model.BookChapter
import kotlinx.coroutines.flow.Flow

class GetChaptersUseCase(
    private val repository: BookChapterRepository
) {
    operator fun invoke(bookUrl: String): Flow<List<BookChapter>> {
        return repository.observeChaptersByBookUrl(bookUrl)
    }

    suspend fun getOnce(bookUrl: String): List<BookChapter> {
        return repository.getChaptersByBookUrl(bookUrl)
    }

    suspend fun getChapter(bookUrl: String, index: Int): BookChapter? {
        return repository.getChapter(bookUrl, index)
    }

    suspend fun getChapter(bookUrl: String, title: String): BookChapter? {
        return repository.getChapter(bookUrl, title)
    }

    suspend fun search(
        bookUrl: String,
        keyword: String,
        start: Int? = null,
        end: Int? = null
    ): List<BookChapter> {
        return repository.search(bookUrl, keyword, start, end)
    }

    suspend fun getChapterCount(bookUrl: String): Int {
        return repository.getChapterCount(bookUrl)
    }
}

class SaveChaptersUseCase(
    private val repository: BookChapterRepository
) {
    suspend operator fun invoke(bookUrl: String, chapters: List<BookChapter>) {
        repository.replaceChapters(bookUrl, chapters)
    }

    suspend fun insert(chapter: BookChapter) {
        repository.insert(chapter)
    }

    suspend fun insertAll(chapters: List<BookChapter>) {
        repository.insertAll(chapters)
    }

    suspend fun updateWordCount(bookUrl: String, chapterUrl: String, wordCount: String) {
        repository.updateWordCount(bookUrl, chapterUrl, wordCount)
    }

    suspend fun renameTitle(bookUrl: String, index: Int, expectedUrl: String, title: String): BookChapter {
        return repository.renameTitle(bookUrl, index, expectedUrl, title)
    }
}

class DeleteChaptersUseCase(
    private val repository: BookChapterRepository
) {
    suspend operator fun invoke(bookUrl: String) {
        repository.deleteByBookUrl(bookUrl)
    }
}
