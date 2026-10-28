package io.legado.kmp.shared.facade

import io.legado.kmp.shared.domain.repository.BookmarkRepository
import io.legado.kmp.shared.model.Bookmark
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlin.coroutines.cancellation.CancellationException

class BookmarkFacade(
    private val bookmarkRepository: BookmarkRepository,
) {
    fun watchAllBookmarks(onUpdate: (List<Bookmark>) -> Unit): FlowSubscription {
        return watchFlow(bookmarkRepository.observeAllBookmarks(), onUpdate, label = "BookmarkFacade.all")
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun getAllBookmarks(): List<Bookmark> {
        return runRecoverable("BookmarkFacade.getAll") {
            bookmarkRepository.getAllBookmarks()
        }
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun searchBookmarks(bookName: String, bookAuthor: String, key: String): List<Bookmark> {
        return runRecoverable("BookmarkFacade.search") {
            bookmarkRepository.searchInBook(bookName, bookAuthor, key)
        }
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun updateBookmark(bookmark: Bookmark) {
        runRecoverable("BookmarkFacade.update") {
            bookmarkRepository.save(bookmark)
        }
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun deleteBookmark(time: Long) {
        runRecoverable("BookmarkFacade.delete") {
            bookmarkRepository.deleteByTime(time)
        }
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun exportBookmarksAsJson(): String {
        return runRecoverable("BookmarkFacade.exportJson") {
            val bookmarks = bookmarkRepository.getAllBookmarks()
            Json { prettyPrint = true }.encodeToString(bookmarks)
        }
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun exportBookmarksAsMarkdown(): String {
        return runRecoverable("BookmarkFacade.exportMd") {
            val bookmarks = bookmarkRepository.getAllBookmarks()
            buildString {
                var currentBook = ""
                var currentAuthor = ""
                for (bm in bookmarks) {
                    if (bm.bookName != currentBook || bm.bookAuthor != currentAuthor) {
                        currentBook = bm.bookName
                        currentAuthor = bm.bookAuthor
                        appendLine("## ${bm.bookName} ${bm.bookAuthor}")
                        appendLine()
                    }
                    appendLine("#### ${bm.chapterName}")
                    appendLine()
                    appendLine("###### 原文")
                    appendLine(" ${bm.bookText}")
                    appendLine()
                    appendLine("###### 摘要")
                    appendLine(" ${bm.content}")
                    appendLine()
                }
            }
        }
    }
}
