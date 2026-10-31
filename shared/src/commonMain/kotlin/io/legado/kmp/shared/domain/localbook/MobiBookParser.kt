package io.legado.kmp.shared.domain.localbook

import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.BookType
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

data class ParsedMobiBook(
    val book: Book,
    val chapters: List<BookChapter>
)

interface MobiBookParser {
    suspend fun parse(book: Book): ParsedMobiBook

    suspend fun readContent(book: Book, chapter: BookChapter): String

    suspend fun readImage(book: Book, imageUrl: String): ByteArray?
}

/** Reads unencrypted PalmDOC, MOBI and KF8 without platform APIs. */
class PalmDocMobiBookParser(
    private val fileStore: LocalBookFileStore
) : MobiBookParser {
    private val mutex = Mutex()
    private var cached: CachedMobiDocument? = null

    override suspend fun parse(book: Book): ParsedMobiBook = mutex.withLock {
        val document = load(book)
        val context = currentCoroutineContext()
        val chapters = document.sections.mapIndexed { index, section ->
            context.ensureActive()
            BookChapter(
                bookUrl = book.bookUrl,
                index = index,
                title = section.title,
                url = "mobi:$index:filepos:${section.start}",
                start = section.start.toLong(),
                end = section.end.toLong(),
                isVolume = section.isVolume,
            )
        }
        val metadata = document.header.metadata
        val currentChapter = chapters.getOrNull(book.durChapterIndex)
        ParsedMobiBook(
            book = book.copy(
                type = BookType.LOCAL,
                name = metadata.title.takeIf { it.isNotBlank() } ?: book.name,
                author = metadata.authors.joinToString("、").takeIf { it.isNotBlank() } ?: book.author,
                intro = metadata.description.takeIf { it.isNotBlank() } ?: book.intro,
                kind = metadata.subjects.joinToString("、").takeIf { it.isNotBlank() } ?: book.kind,
                charset = document.header.encoding.charsetName,
                coverUrl = book.coverUrl?.takeIf { it.isNotBlank() } ?: document.header.coverRecord?.let { cover ->
                    document.header.resourceRecord?.let { MobiEmbeddedImage.toUrl(cover - it) }
                },
                totalChapterNum = chapters.size,
                latestChapterTitle = chapters.lastOrNull()?.title,
                durChapterTitle = currentChapter?.title ?: book.durChapterTitle,
            ),
            chapters = chapters,
        )
    }

    override suspend fun readContent(book: Book, chapter: BookChapter): String = mutex.withLock {
        require(chapter.bookUrl.isEmpty() || chapter.bookUrl == book.bookUrl) {
            "MOBI 章节不属于当前书籍"
        }
        val document = load(book)
        require(chapter.index in 0 until 50000 && MobiChapterIdentity.accepts(chapter)) {
            "MOBI 章节标识无效，请重新加载目录"
        }
        val span = MobiReadingSpan.of(chapter)
        require(span.end <= document.text.size && document.header.encoding.isBoundary(document.text, span.start.toInt()) &&
            document.header.encoding.isBoundary(document.text, span.end.toInt())) { "MOBI 章节超出正文或截断字符" }
        if (span.volume && span.start == span.end) return@withLock ""
        fun matches(section: MobiTextSection): Boolean = span.start == section.start.toLong() &&
            span.end == section.end.toLong() && span.volume == section.isVolume
        val section = document.sections.getOrNull(chapter.index)?.takeIf(::matches)
            ?: document.sections.firstOrNull(::matches)
        requireNotNull(section) {
            "MOBI 文件或目录已变化，请重新加载目录"
        }
        if (section.isVolume && section.start == section.end) return@withLock ""
        val context = currentCoroutineContext()
        context.ensureActive()
        val text = document.header.encoding.decode(document.text, section.start, section.end)
        val content = if (document.isHtml) MobiHtmlSupport.format(text, document.flows) { context.ensureActive() } else {
            text.replace("\r\n", "\n").replace('\r', '\n').trimEnd('\u0000')
        }
        context.ensureActive()
        content
    }

    suspend fun clearCache() = mutex.withLock {
        cached = null
    }

    override suspend fun readImage(book: Book, imageUrl: String): ByteArray? = mutex.withLock {
        val context = currentCoroutineContext()
        context.ensureActive()
        val path = LocalBookFileBinding.path(book)
        val modified = fileStore.lastModified(path)
        val source = fileStore.openRead(path)
        try {
            val records = MobiRecordReader(source)
            // Read the header even on a cache hit so DRM/header rejection is never bypassed.
            val header = records.readHeader()
            val flows = if (header.kf8 != null) {
                load(path, modified, source.size, records, header) { context.ensureActive() }.flows
            } else null
            MobiEmbeddedImage.read(records, header, imageUrl, { context.ensureActive() }, flows)
        } finally {
            source.closeSource()
        }
    }

    private suspend fun load(book: Book): MobiDocument {
        val context = currentCoroutineContext()
        context.ensureActive()
        val path = LocalBookFileBinding.path(book)
        val modified = fileStore.lastModified(path)
        val source = fileStore.openRead(path)
        try {
            val records = MobiRecordReader(source)
            val header = records.readHeader()
            return load(path, modified, source.size, records, header) { context.ensureActive() }
        } finally {
            source.closeSource()
        }
    }

    private fun load(
        path: String,
        modified: Long?,
        size: Long,
        records: MobiRecordReader,
        header: MobiHeader,
        checkActive: () -> Unit,
    ): MobiDocument {
        checkActive()
        val previous = cached
        if (modified != null && previous?.path == path && previous.modified == modified &&
            previous.size == size && previous.document.header == header) {
            return previous.document
        }
        cached = null
        val raw = MobiPalmDocDecoder.readText(records, header, checkActive)
        val kf8 = if (header.kf8 != null) MobiKf8Reader(records, header, checkActive).read(raw) else null
        val text = kf8?.text ?: raw
        header.encoding.validate(text, checkActive)
        val isHtml = kf8 != null || header.isMobi && MobiHtmlSupport.isHtml(text)
        val sections = kf8?.sections ?: run {
            val navigation = header.ncxRecord?.let {
                MobiNcxIndex(records, header.encoding, checkActive).read(it)
            }.orEmpty()
            MobiHtmlSupport.sections(text, header.encoding, isHtml, navigation, checkActive)
        }
        require(sections.any { !it.isVolume && it.end > it.start }) { "MOBI 正文为空" }
        val flows = MobiFlowResources(kf8?.flows.orEmpty(), header.encoding, checkActive)
        val document = MobiDocument(header, text, isHtml, sections, flows)
        checkActive()
        if (modified != null) cached = CachedMobiDocument(path, modified, size, document)
        return document
    }
}

private data class MobiDocument(
    val header: MobiHeader,
    val text: ByteArray,
    val isHtml: Boolean,
    val sections: List<MobiTextSection>,
    val flows: MobiFlowResources,
)

private data class CachedMobiDocument(
    val path: String,
    val modified: Long,
    val size: Long,
    val document: MobiDocument,
)

class UnsupportedMobiBookParser : MobiBookParser {
    override suspend fun parse(book: Book): ParsedMobiBook {
        throw UnsupportedOperationException("MOBI parsing is not implemented on this platform")
    }

    override suspend fun readContent(book: Book, chapter: BookChapter): String {
        throw UnsupportedOperationException("MOBI content reading is not implemented on this platform")
    }

    override suspend fun readImage(book: Book, imageUrl: String): ByteArray? {
        throw UnsupportedOperationException("MOBI images are not supported on this platform")
    }
}
