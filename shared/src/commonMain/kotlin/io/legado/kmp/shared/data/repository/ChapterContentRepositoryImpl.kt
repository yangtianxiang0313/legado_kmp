package io.legado.kmp.shared.data.repository

import io.legado.kmp.shared.domain.repository.ChapterContentRepository
import io.legado.kmp.shared.domain.repository.SaveContentEvent
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.getCacheFolderName
import io.legado.kmp.shared.model.isTxtLocalBook
import io.legado.kmp.shared.platform.AppFilesDirectory
import io.legado.kmp.shared.platform.FileAccess
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow

class ChapterContentRepositoryImpl(
    private val fileAccess: FileAccess,
    private val appFilesDirectory: AppFilesDirectory,
    /**
     * Reference for word count updates after save and URL-cache file name mapping.
     * Aligned with legado BookHelp.saveText() which updates chapter wordCount
     * via bookChapterDao.upWordCount() when book.isOnLineTxt.
     * Set lazily to avoid circular dependency.
     * Required by getChapterFiles once a book uses URL-keyed caching.
     */
    var chapterRepository: io.legado.kmp.shared.domain.repository.BookChapterRepository? = null,
) : ChapterContentRepository {

    private val _saveContentEvents = MutableSharedFlow<SaveContentEvent>(extraBufferCapacity = 64)
    override val saveContentEvents: SharedFlow<SaveContentEvent> = _saveContentEvents.asSharedFlow()
    private val cache = ChapterContentCache(fileAccess)

    override suspend fun hasContent(book: Book, chapter: BookChapter): Boolean {
        if (book.shouldTreatChapterContentAsAlwaysAvailable(chapter)) return true
        val root = rootDirectory(book)
        return ChapterCacheLocks.withLock(root) {
            fileAccess.getSize(cache.chapterPath(root, chapter)) > 0L
        }
    }

    override suspend fun getContent(book: Book, chapter: BookChapter): String? {
        val root = rootDirectory(book)
        return ChapterCacheLocks.withLock(root) {
            val path = cache.chapterPath(root, chapter)
            if (!fileAccess.exists(path)) return@withLock null
            val bytes = fileAccess.read(path)
            bytes.decodeToString().takeIf { it.isNotEmpty() }
        }
    }

    override suspend fun saveContent(book: Book, chapter: BookChapter, content: String): Boolean {
        if (content.isEmpty()) return false
        val root = rootDirectory(book)
        val success = ChapterCacheLocks.withLock(root) {
            currentCoroutineContext().ensureActive()
            if (!fileAccess.createDirectory(root)) return@withLock false
            val path = cache.chapterPath(root, chapter)
            val bytes = content.encodeToByteArray()
            currentCoroutineContext().ensureActive()
            val saved = fileAccess.write(path, bytes)
            currentCoroutineContext().ensureActive()
            saved && fileAccess.getSize(path) == bytes.size.toLong()
        }
        if (success) {
            // Aligned with legado BookHelp.saveText():
            // Update word count for online text books
            if (book.isOnLineTxt) {
                val wordCount = wordCountFormat(content.length)
                chapterRepository?.updateWordCount(chapter.bookUrl, chapter.url, wordCount)
            }
            // Equivalent to legado's postEvent(EventBus.SAVE_CONTENT, Pair(book, bookChapter))
            _saveContentEvents.tryEmit(SaveContentEvent(book, chapter))
        }
        return success
    }

    override suspend fun deleteContent(book: Book, chapter: BookChapter): Boolean {
        val root = rootDirectory(book)
        return ChapterCacheLocks.withLock(root) {
            val path = cache.chapterPath(root, chapter)
            !fileAccess.exists(path) || fileAccess.delete(path)
        }
    }

    override suspend fun prepareForChapterReorder(book: Book, chapters: List<BookChapter>) {
        val root = rootDirectory(book)
        ChapterCacheLocks.withLock(root) {
            if (cache.usesUrls(root)) return@withLock
            require(chapters.all { it.bookUrl == book.bookUrl }) {
                "Chapter cache migration contains another book"
            }
            require(chapters.map { it.url }.toSet().size == chapters.size) {
                "Chapter cache migration contains duplicate URLs"
            }
            require(chapters.map { it.getFileName() }.toSet().size == chapters.size) {
                "Chapter cache migration contains ambiguous legacy file names"
            }
            cache.prepare(root, chapters)
        }
    }

    override suspend fun clearCache(): Boolean {
        val cacheDir = cacheRootDirectory()
        val entries = fileAccess.listFiles(cacheDir)
        var success = true
        for (entry in entries) {
            val entryPath = "$cacheDir/$entry"
            val deleted = ChapterCacheLocks.withLock(entryPath) { cache.deleteDirectory(entryPath) }
            if (!deleted) success = false
        }
        return success
    }

    override suspend fun clearCache(book: Book): Boolean {
        val bookDir = rootDirectory(book)
        return ChapterCacheLocks.withLock(bookDir) {
            cache.deleteDirectory(bookDir)
        }
    }

    override suspend fun getChapterFiles(book: Book): Set<String> {
        if (book.isTxtLocalBook) return emptySet()
        val bookDir = rootDirectory(book)
        val (usesUrls, files) = ChapterCacheLocks.withLock(bookDir) {
            val names = buildSet {
                for (name in fileAccess.listFiles(bookDir)) {
                    currentCoroutineContext().ensureActive()
                    if (!name.endsWith(".nb") || fileAccess.getSize("$bookDir/$name") > 0L) add(name)
                }
            }
            cache.usesUrls(bookDir) to names
        }
        if (!usesUrls) return files.filterNot { cache.isPrivateFile(it) }.toSet()

        // Query outside the file lock to avoid lock inversion with a SQL reorder transaction.
        val chapters = checkNotNull(chapterRepository) {
            "Chapter repository is required to map URL-keyed chapter cache files"
        }.getChaptersByBookUrl(book.bookUrl)
        return buildSet {
            for (chapter in chapters) {
                if (cache.urlFileName(chapter) in files) add(chapter.getFileName())
                if (cache.urlFileName(chapter, "nr") in files) add(chapter.getFileName("nr"))
            }
        }
    }

    override suspend fun setRemoveSameTitle(
        book: Book,
        chapter: BookChapter,
        removeSameTitle: Boolean,
    ) {
        val root = rootDirectory(book)
        ChapterCacheLocks.withLock(root) {
            val markerPath = cache.chapterPath(root, chapter, "nr")
            if (removeSameTitle) {
                if (fileAccess.exists(markerPath)) {
                    check(fileAccess.delete(markerPath)) { "Failed to remove chapter title marker: $markerPath" }
                }
            } else {
                check(fileAccess.createDirectory(root)) { "Failed to create chapter cache: $root" }
                check(fileAccess.write(markerPath, ByteArray(0))) { "Failed to write chapter title marker: $markerPath" }
            }
        }
    }

    override suspend fun removeSameTitle(book: Book, chapter: BookChapter): Boolean {
        val root = rootDirectory(book)
        return ChapterCacheLocks.withLock(root) {
            !fileAccess.exists(cache.chapterPath(root, chapter, "nr"))
        }
    }

    override suspend fun moveCacheFolder(oldFolderName: String, newFolderName: String): Boolean {
        if (oldFolderName == newFolderName) return true
        val cacheRoot = cacheRootDirectory()
        val oldPath = "$cacheRoot/$oldFolderName"
        val newPath = "$cacheRoot/$newFolderName"
        return ChapterCacheLocks.withLocks(oldPath, newPath) {
            cache.moveDirectory(oldPath, newPath)
        }
    }

    override suspend fun listCacheFolders(): List<String> {
        return fileAccess.listFiles(cacheRootDirectory())
    }

    override suspend fun deleteCacheFolder(folderName: String): Boolean {
        val folderPath = cacheRootDirectory() + "/" + folderName
        return ChapterCacheLocks.withLock(folderPath) {
            cache.deleteDirectory(folderPath)
        }
    }

    private fun rootDirectory(book: Book): String {
        return cacheRootDirectory() + "/" + book.getCacheFolderName()
    }

    private fun cacheRootDirectory(): String {
        return appFilesDirectory.path().trimEnd('/') + "/book_cache"
    }
}

private fun Book.shouldTreatChapterContentAsAlwaysAvailable(chapter: BookChapter): Boolean {
    return isTxtLocalBook || (chapter.isVolume && chapter.url.startsWith(chapter.title))
}

/**
 * Format word count aligned with legado StringUtils.wordCountFormat(Int).
 * >10000 → "X.X万字", otherwise → "N字"
 */
private fun wordCountFormat(words: Int): String {
    return when {
        words <= 0 -> ""
        words > 10000 -> "${((words / 100.0).toInt() / 100.0)}万字"
        else -> "${words}字"
    }
}
