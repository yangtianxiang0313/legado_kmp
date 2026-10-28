package io.legado.kmp.shared.domain.localbook

import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

data class ParsedUmdBook(
    val book: Book,
    val chapters: List<BookChapter>,
    val metadata: Map<String, String> = emptyMap(),
    val coverBytes: ByteArray? = null,
    val coverMediaType: String? = null,
)

interface UmdBookParser {
    suspend fun parse(book: Book, bytes: ByteArray): ParsedUmdBook

    suspend fun readContent(bytes: ByteArray, chapter: BookChapter): String
}

/** Text UMD reader ported from Android's UmdReader/UmdChapters, with bounded input. */
class BinaryUmdBookParser(
    defaultCharsetName: String = "UTF-16LE",
) : UmdBookParser {
    private val defaultCharset = canonicalUmdCharset(defaultCharsetName)
    private val cacheMutex = Mutex()
    private var cached: CachedDocument? = null

    override suspend fun parse(book: Book, bytes: ByteArray): ParsedUmdBook {
        val charset = book.charset?.takeIf { it.isNotBlank() }?.let(::canonicalUmdCharset) ?: defaultCharset
        val document = readDocument(bytes, charset)
        val context = currentCoroutineContext()
        val chapters = document.chapters.mapIndexed { index, chapter ->
            context.ensureActive()
            BookChapter(
                bookUrl = book.bookUrl,
                url = index.toString(),
                title = chapter.title.ifBlank { "无标题章节" },
                index = index,
                start = chapter.start.toLong(),
                end = chapter.end.toLong(),
                tag = CHARSET_TAG_PREFIX + charset,
            )
        }
        return ParsedUmdBook(
            book = book.copy(
                name = document.metadata["title"]?.takeIf { it.isNotBlank() } ?: book.name,
                author = document.metadata["author"]?.takeIf { it.isNotBlank() } ?: book.author,
                kind = document.metadata["kind"]?.takeIf { it.isNotBlank() } ?: book.kind,
                charset = charset,
                totalChapterNum = chapters.size,
                latestChapterTitle = chapters.last().title,
                durChapterTitle = chapters.getOrNull(book.durChapterIndex)?.title ?: chapters.first().title,
                canUpdate = false,
            ),
            chapters = chapters,
            metadata = document.metadata.toMap(),
            coverBytes = document.coverBytes?.copyOf(),
            coverMediaType = document.coverMediaType,
        )
    }

    override suspend fun readContent(bytes: ByteArray, chapter: BookChapter): String {
        val charset = chapter.tag?.takeIf { it.startsWith(CHARSET_TAG_PREFIX) }
            ?.removePrefix(CHARSET_TAG_PREFIX)?.let(::canonicalUmdCharset) ?: defaultCharset
        val document = readDocument(bytes, charset)
        val content = document.chapters.getOrNull(chapter.index)
            ?: throw IllegalArgumentException("UMD 章节序号越界：${chapter.index}")
        require(chapter.url == chapter.index.toString()) { "UMD 章节地址与序号不一致，请重新导入目录" }
        require((chapter.start == null || chapter.start == content.start.toLong()) &&
            (chapter.end == null || chapter.end == content.end.toLong())) {
            "UMD 章节偏移已失效，请重新导入目录"
        }
        return content.content
    }

    private suspend fun readDocument(bytes: ByteArray, charset: String): UmdDocument {
        val context = currentCoroutineContext()
        context.ensureActive()
        require(bytes.size in 4..UmdLimits.MAX_FILE_BYTES) { "UMD 为空、损坏或超过 64 MiB" }
        return cacheMutex.withLock {
            context.ensureActive()
            cached?.takeIf { entry ->
                entry.charset == charset && entry.matches(bytes) { context.ensureActive() }
            }?.let { return@withLock it.document }
            val document = UmdDocumentReader(bytes, charset) { context.ensureActive() }.read()
            context.ensureActive()
            cached = if (bytes.size <= MAX_CACHED_FILE_BYTES && document.textByteCount <= MAX_CACHED_TEXT_BYTES) {
                CachedDocument(bytes.copyOf(), charset, document)
            } else {
                null
            }
            document
        }
    }

    private class CachedDocument(
        val bytes: ByteArray,
        val charset: String,
        val document: UmdDocument,
    ) {
        fun matches(other: ByteArray, checkActive: () -> Unit): Boolean {
            if (bytes.size != other.size) return false
            for (index in bytes.indices) {
                if (index and 65535 == 0) checkActive()
                if (bytes[index] != other[index]) return false
            }
            checkActive()
            return true
        }
    }

    private companion object {
        const val CHARSET_TAG_PREFIX = "umd:charset:"
        const val MAX_CACHED_FILE_BYTES = 8 * 1024 * 1024
        const val MAX_CACHED_TEXT_BYTES = 16 * 1024 * 1024
    }
}

@Deprecated("Use BinaryUmdBookParser")
class UnsupportedUmdBookParser : UmdBookParser by BinaryUmdBookParser()
