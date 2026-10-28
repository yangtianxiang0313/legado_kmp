package io.legado.kmp.shared.facade

import io.legado.kmp.shared.model.BookChapter
import kotlinx.coroutines.sync.Mutex

/** Mutable chapter bookkeeping avoids copying the entire success/error table on every completion. */
internal class CacheDownloadLedger {
    private class BookState {
        val success = mutableSetOf<String>()
        val errors = mutableMapOf<String, Int>()
        var lastError: String? = null
    }

    private val lock = Mutex()
    private val books = mutableMapOf<String, BookState>()

    fun success(chapter: BookChapter) = lock.withCacheState {
        val book = books.getOrPut(chapter.bookUrl) { BookState() }
        book.success.add(chapter.url)
        book.errors.remove(chapter.url)
        Unit
    }

    fun failure(chapter: BookChapter, error: Throwable): Int = lock.withCacheState {
        val book = books.getOrPut(chapter.bookUrl) { BookState() }
        book.success.remove(chapter.url)
        val attempts = (book.errors[chapter.url] ?: 0) + 1
        book.errors[chapter.url] = attempts
        book.lastError = error.message ?: error.toString()
        attempts
    }

    fun attempts(chapter: BookChapter): Int = lock.withCacheState {
        books[chapter.bookUrl]?.errors?.get(chapter.url) ?: 0
    }

    fun resetFailures(bookUrl: String) = lock.withCacheState {
        books[bookUrl]?.errors?.clear()
        books[bookUrl]?.lastError = null
    }

    fun lastError(bookUrl: String): String? = lock.withCacheState { books[bookUrl]?.lastError }

    fun failedUrls(bookUrl: String): Set<String> = lock.withCacheState {
        books[bookUrl]?.errors?.keys?.toSet() ?: emptySet()
    }

    fun errorCount(bookUrl: String? = null): Int = lock.withCacheState {
        if (bookUrl == null) books.values.sumOf { it.errors.size } else books[bookUrl]?.errors?.size ?: 0
    }

    fun successCount(): Int = lock.withCacheState { books.values.sumOf { it.success.size } }

    fun clear() = lock.withCacheState { books.clear() }
}

/** Selected chapters only become complete after both their body and every image are confirmed. */
internal class CacheBatchProgress(
    chapters: List<BookChapter>,
    files: Set<String>,
    start: Int,
    end: Int,
) {
    private val lock = Mutex()
    private val cached = mutableSetOf<String>()

    init {
        chapters.forEachIndexed { index, chapter ->
            if (chapter.isVolume || (index !in start..end && chapter.getFileName() in files)) {
                cached.add(chapter.url)
            }
        }
    }

    fun success(chapter: BookChapter) = lock.withCacheState { cached.add(chapter.url) }
    fun count(): Int = lock.withCacheState { cached.size }
}
