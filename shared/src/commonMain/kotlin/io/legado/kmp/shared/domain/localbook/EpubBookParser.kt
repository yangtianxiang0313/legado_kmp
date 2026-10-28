package io.legado.kmp.shared.domain.localbook

import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.BookType
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

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
    private val archiveMutex = Mutex()
    private var cached: CachedEpubBytes? = null

    override suspend fun parse(book: Book): ParsedEpubBook {
        val archive = openArchive(book)
        val publication = EpubPackage(archive)
        val context = currentCoroutineContext()
        val chapters = EpubChapterCatalog(archive, publication) { context.ensureActive() }.chapters(book)
        val cover = publication.coverPath()?.let(EpubResourcePaths::toUrl)
        return ParsedEpubBook(
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

    override suspend fun readContent(book: Book, chapter: BookChapter): String {
        val context = currentCoroutineContext()
        context.ensureActive()
        val archive = openArchive(book)
        return EpubChapterContentLoading.read(archive, book, chapter) { context.ensureActive() }
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
        val archive = openArchive(current)
        return EpubCatalogReflowBuilder(archive) { context.ensureActive() }
            .build(current, replacement, previous, chapters, process)
    }

    override suspend fun readImage(book: Book, imageUrl: String): ByteArray? {
        val context = currentCoroutineContext()
        context.ensureActive()
        // Data images can be much longer than the archive path resolver's 8K URI limit.
        if (imageUrl.startsWith("data:", true)) {
            return EpubEmbeddedImage.prepareDataImage(imageUrl) { context.ensureActive() }
        }
        val archive = openArchive(book)
        if (EpubChapterContent.isInlineImage(imageUrl)) {
            return EpubChapterContent.readInlineImage(archive, imageUrl) { context.ensureActive() }
        }
        val path = imageUrl.takeIf(archive::contains)
            ?: (if (imageUrl == "cover.jpeg") EpubPackage(archive).coverPath() else null)
            ?: EpubResourcePaths.resolve("", imageUrl)
            ?: return null
        return EpubEmbeddedImage.read(archive, path, checkActive = { context.ensureActive() })
    }

    private suspend fun openArchive(book: Book): EpubArchive = archiveMutex.withLock {
        val context = currentCoroutineContext()
        context.ensureActive()
        val modified = fileStore.lastModified(book.bookUrl)
        val source = fileStore.openRead(book.bookUrl)
        try {
            require(source.size in 22..BookArchiveZipReader.MAX_ARCHIVE_BYTES.toLong()) {
                "EPUB 为空、损坏或超过 128 MiB"
            }
            val previous = cached
            if (modified != null && previous?.path == book.bookUrl && previous.modified == modified &&
                previous.bytes.size.toLong() == source.size) {
                // Archive readers own the current request's cancellation check, not the cached request's job.
                return@withLock EpubArchive(previous.bytes) { context.ensureActive() }
            }
            cached = null
            val output = ByteArray(source.size.toInt())
            var offset = 0
            while (offset < output.size) {
                context.ensureActive()
                val count = minOf(64 * 1024, output.size - offset)
                val chunk = source.read(offset.toLong(), count)
                require(chunk.isNotEmpty() && chunk.size <= count) { "EPUB 文件读取不完整" }
                chunk.copyInto(output, offset)
                offset += chunk.size
            }
            val archive = EpubArchive(output) { context.ensureActive() }
            if (modified != null && output.size <= MAX_CACHED_ARCHIVE_BYTES &&
                fileStore.lastModified(book.bookUrl) == modified) {
                context.ensureActive()
                cached = CachedEpubBytes(book.bookUrl, modified, output)
            }
            archive
        } finally {
            source.closeSource()
        }
    }

    private companion object {
        const val MAX_CACHED_ARCHIVE_BYTES = 16 * 1024 * 1024
    }
}

private data class CachedEpubBytes(val path: String, val modified: Long, val bytes: ByteArray)
