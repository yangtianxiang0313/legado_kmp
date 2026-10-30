package io.legado.kmp.shared.domain.localbook

import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.BookType
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

data class ParsedEpubBook(
    val book: Book,
    val chapters: List<BookChapter>
)

interface EpubBookParser {
    suspend fun parse(book: Book): ParsedEpubBook

    suspend fun readContent(book: Book, chapter: BookChapter): String

    /** Reads an archive-relative or parser-generated image URL, never a filesystem path.
     * SVG images remain self-contained vector bytes for the platform image consumer to rasterize.
     */
    suspend fun readImage(book: Book, imageUrl: String): ByteArray?
}

class ZipEpubBookParser(
    private val fileStore: LocalBookFileStore
) : EpubBookParser {
    override suspend fun parse(book: Book): ParsedEpubBook = withArchive(book) { archive, checkActive ->
        val publication = EpubPackage(archive)
        val chapters = EpubChapterCatalog(archive, publication, checkActive).chapters(book)
        val cover = publication.coverPath()?.let(EpubResourcePaths::toUrl)
        ParsedEpubBook(
            book = book.copy(
                type = BookType.EPUB,
                name = publication.metadata("title") ?: book.name,
                author = publication.metadata("creator") ?: book.author,
                intro = publication.metadata("description") ?: book.intro,
                kind = publication.subjects().takeIf { it.isNotEmpty() }?.joinToString(" / ") ?: book.kind,
                coverUrl = book.coverUrl?.takeIf { it.isNotBlank() } ?: cover,
                totalChapterNum = chapters.size,
            ),
            chapters = chapters,
        )
    }

    override suspend fun readContent(book: Book, chapter: BookChapter): String =
        withArchive(book) { archive, checkActive ->
            EpubChapterContentLoading.read(archive, book, chapter, checkActive)
        }

    internal suspend fun prepareCatalogReflow(
        current: Book,
        replacement: Book,
        previous: List<BookChapter>,
        chapters: List<BookChapter>,
        process: suspend (Book, BookChapter, String, Boolean) -> EpubReflowText,
    ): EpubCatalogReflowPlan? {
        val context = currentCoroutineContext()
        context.ensureActive()
        if (!needsEpubCatalogReflow(previous, chapters)) return null
        // process can suspend and reenter this parser; each invocation owns its reader, never a shared mutex.
        return withArchive(current) { archive, checkActive ->
            EpubCatalogReflowBuilder(archive, checkActive).build(current, replacement, previous, chapters, process)
        }
    }

    override suspend fun readImage(book: Book, imageUrl: String): ByteArray? {
        val context = currentCoroutineContext()
        context.ensureActive()
        // Data images can be much longer than the archive path resolver's 8K URI limit.
        if (imageUrl.startsWith("data:", true)) {
            return EpubEmbeddedImage.prepareDataImage(imageUrl) { context.ensureActive() }
        }
        return withArchive(book) { archive, checkActive ->
            if (EpubChapterContent.isInlineImage(imageUrl)) {
                return@withArchive EpubChapterContent.readInlineImage(archive, imageUrl, checkActive)
            }
            val path = imageUrl.takeIf(archive::contains)
                ?: (if (imageUrl == "cover.jpeg") EpubPackage(archive).coverPath() else null)
                ?: EpubResourcePaths.resolve("", imageUrl)
                ?: return@withArchive null
            EpubEmbeddedImage.read(archive, path, checkActive = checkActive)
        }
    }

    private suspend fun <T> withArchive(
        book: Book,
        action: suspend (EpubArchive, () -> Unit) -> T,
    ): T {
        val context = currentCoroutineContext()
        val checkActive = { context.ensureActive() }
        checkActive()
        val modified = fileStore.lastModified(book.bookUrl)
        checkActive()
        val source = fileStore.openRead(book.bookUrl)
        var reader: EpubArchiveReader? = null
        var failure: Throwable? = null
        try {
            checkActive()
            val size = source.size
            require(size in 22L..EpubArchiveReadLimits.ARCHIVE_BYTES) {
                "EPUB 为空、损坏或超过归档读取限额"
            }
            validateSourceSnapshot(book.bookUrl, source, size, modified, checkActive)
            val opened = NativeEpubArchiveReader(BoundedEpubReadSource(source, size, checkActive), checkActive)
            reader = opened
            val result = action(EpubArchive(opened, checkActive), checkActive)
            checkActive()
            validateSourceSnapshot(book.bookUrl, source, size, modified, checkActive)
            checkActive()
            return result
        } catch (error: Throwable) {
            failure = error
            throw error
        } finally {
            closeEpubResources(reader, source, failure)
        }
    }

    private suspend fun validateSourceSnapshot(
        path: String,
        source: LocalBookByteSource,
        size: Long,
        modified: Long?,
        checkActive: () -> Unit,
    ) {
        checkActive()
        check(fileStore.lastModified(path) == modified) { "EPUB 文件在读取期间发生变化" }
        checkActive()
        // size is an open-time snapshot, so reopen only for metadata; never read from the probe handle.
        val probe = fileStore.openRead(path)
        var failure: Throwable? = null
        try {
            checkActive()
            check(source.size == size && probe.size == size) { "EPUB 文件在读取期间长度发生变化" }
        } catch (error: Throwable) {
            failure = error
            throw error
        } finally {
            closeEpubResources(null, probe, failure)
        }
        checkActive()
        check(fileStore.lastModified(path) == modified) { "EPUB 文件在读取期间发生变化" }
        checkActive()
    }
}

private class BoundedEpubReadSource(
    private val source: LocalBookByteSource,
    override val size: Long,
    private val checkActive: () -> Unit,
) : LocalBookByteSource {
    override fun read(offset: Long, length: Int): ByteArray {
        checkActive()
        require(offset >= 0L && length in 0..EpubArchiveReadLimits.READ_BYTES) { "EPUB 源读取范围无效或超过 64 KiB" }
        check(source.size == size) { "EPUB 文件在读取期间长度发生变化" }
        val count = if (offset >= size) 0 else minOf(length.toLong(), size - offset).toInt()
        val bytes = source.read(offset, count)
        checkActive()
        // A positive short read is progress, not EOF; the native callback advances by the returned size.
        check(source.size == size && bytes.size <= count && (count == 0 || bytes.isNotEmpty())) {
            "EPUB 文件在读取期间被截断或长度异常"
        }
        return bytes
    }

    override fun closeSource() = source.closeSource()
}

private fun closeEpubResources(reader: EpubArchiveReader?, source: LocalBookByteSource, original: Throwable?) {
    var failure = original
    fun close(action: () -> Unit) {
        try {
            action()
        } catch (error: Throwable) {
            val previous = failure
            if (previous == null) failure = error else if (previous !== error) previous.addSuppressed(error)
        }
    }
    if (reader != null) close { reader.closeReader() }
    close { source.closeSource() }
    if (original == null) failure?.let { throw it }
}
