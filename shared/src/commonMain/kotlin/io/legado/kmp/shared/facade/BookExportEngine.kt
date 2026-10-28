package io.legado.kmp.shared.facade

import io.legado.kmp.shared.domain.repository.BookChapterRepository
import io.legado.kmp.shared.domain.repository.BookRepository
import io.legado.kmp.shared.domain.repository.ChapterContentRepository
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import okio.Buffer

internal class BookExportEngine(
    private val books: BookRepository,
    private val chapters: BookChapterRepository,
    private val content: ChapterContentRepository,
    private val images: BookImageFacade,
    private val localContent: BookExportLocalContent,
    private val transform: BookExportContentTransform? = null,
) {
    suspend fun prepare(
        bookUrl: String,
        format: String,
        onProgress: (BookExportProgress) -> Unit,
    ): BookExportResult {
        val context = currentCoroutineContext()
        val checkActive: () -> Unit = { context.ensureActive() }
        checkActive()
        val budget = BookExportBudget(checkActive)
        val (book, extension, directory) = snapshot(bookUrl, format, budget, checkActive)
        val state = State()
        progress(0, directory.size, onProgress, checkActive)
        val bytes = when (extension) {
            "txt" -> txt(book, directory, state, budget, onProgress, checkActive)
            else -> epub(book, directory, state, budget, onProgress, checkActive)
        }
        checkActive()
        return result(bytes, extension, directory.size, state)
    }

    suspend fun prepareConfigured(
        bookUrl: String,
        format: String,
        options: BookExportOptions,
        onProgress: (BookExportProgress) -> Unit,
    ): BookExportBatchResult {
        val context = currentCoroutineContext()
        val checkActive: () -> Unit = { context.ensureActive() }
        checkActive()
        val budget = BookExportBudget(checkActive)
        val (book, extension, directory) = snapshot(bookUrl, format, budget, checkActive)
        val selected = bookExportSelection(directory, options.chapterScope, checkActive)
        val volumes = bookExportVolumes(selected, options.chaptersPerFile, extension, checkActive)
        requireBookExport(!options.useReplaceRules || transform != null, "正文替换规则服务不可用，无法导出")
        if (extension == "txt") validateBookExportCharset(options.charset)
        val batchBudget = BookExportBatchBudget(budget, checkActive)
        val fileNames = volumes.indices.map { index ->
            checkActive()
            bookExportFileName(book, extension, if (options.chaptersPerFile > 0) index + 1 else null, options)
                .also {
                    checkActive()
                    batchBudget.reserveFileName(it)
                }
        }
        val parts = mutableListOf<BookExportPart>()
        var completed = 0
        var readable = 0
        progress(0, selected.size, onProgress, checkActive)
        for ((index, volume) in volumes.withIndex()) {
            checkActive()
            val state = State()
            val partProgress: (BookExportProgress) -> Unit = { value ->
                progress(completed + value.completed, selected.size, onProgress, checkActive)
            }
            val bytes = when (extension) {
                "txt" -> txt(book, volume, state, budget, partProgress, checkActive, options)
                else -> epub(book, volume, state, budget, partProgress, checkActive, options, batchBudget)
            }
            checkActive()
            batchBudget.accept(bytes)
            parts += BookExportPart(fileNames[index], result(bytes, extension, volume.size, state))
            completed += volume.size
            readable += state.readable
        }
        // A missing-only volume is valid only when another selected volume has real content.
        requireReadable(readable, txt = extension == "txt")
        checkActive()
        return BookExportBatchResult(parts.toList())
    }

    private suspend fun snapshot(
        bookUrl: String,
        format: String,
        budget: BookExportBudget,
        checkActive: () -> Unit,
    ): Snapshot {
        requireBookExportIdentity(bookUrl, budget)
        requireBookExport(format.length <= 16, "仅支持 TXT 或 EPUB 导出")
        val extension = format.trim().lowercase()
        requireBookExport(extension == "txt" || extension == "epub", "仅支持 TXT 或 EPUB 导出")
        val book = books.getBook(bookUrl)?.copy() ?: throw BookExportFailure("书籍不存在，无法导出")
        checkActive()
        requireBookExport(book.bookUrl == bookUrl, "书籍归属发生变化，无法导出")
        requireBookExportFormat(book)
        requireBookExportMetadata(book, budget)
        val directory = bookExportDirectory(book, chapters.getChaptersByBookUrl(bookUrl), budget, checkActive)
        checkActive()
        return Snapshot(book, extension, directory)
    }

    private suspend fun txt(
        book: Book,
        directory: List<BookChapter>,
        state: State,
        budget: BookExportBudget,
        onProgress: (BookExportProgress) -> Unit,
        checkActive: () -> Unit,
        options: BookExportOptions? = null,
    ): ByteArray {
        val output = Buffer()
        val configuredText = StringBuilder()
        var outputBytes = 0L
        fun append(text: String) {
            checkActive()
            val bytes = budget.rendered(text)
            requireBookExport(outputBytes + bytes <= BookExportLimits.PACKAGE_BYTES,
                "导出文件超过 128 MiB 限制")
            outputBytes += bytes
            if (options == null) output.writeUtf8(text) else configuredText.append(text)
        }
        try {
            append("${book.name}\n作者：${book.author}\n")
            book.displayIntro?.takeIf { it.isNotBlank() }?.let { intro ->
                val chapter = BookChapter(bookUrl = book.bookUrl)
                val document = BookExportDocument.parse(chapter, intro)
                append("\n简介：\n${document.renderText(missingImageText = TXT_IMAGE_MISSING)}\n")
            }
            directory.forEachIndexed { index, originalChapter ->
                checkActive()
                val source = chapterContent(book, originalChapter, budget, checkActive, options)
                val chapter = source.chapter
                val document = BookExportDocument.parse(chapter, source.body, imageBook = book.isImage)
                checkActive()
                repeat(document.imageCount) { budget.imageOccurrence() }
                state.missingImages += document.imageCount
                val readable = source.hasContent && document.hasReadableText
                val emptyVolume = !readable && chapter.isVolume && chapter.title.isNotBlank() && document.imageCount == 0
                when {
                    readable -> state.readable++
                    !emptyVolume -> state.missingChapters++
                }
                val rendered = document.renderText(missingImageText = TXT_IMAGE_MISSING)
                append(if (options?.includeChapterTitle == false) "\n\n" else "\n\n${chapter.title}\n")
                append(rendered)
                if (!readable && !emptyVolume) append("\n${missingChapterMessage(book)}\n")
                checkActive()
                progress(index + 1, directory.size, onProgress, checkActive)
            }
            if (options == null) requireReadable(state.readable, txt = true)
            checkActive()
            if (options == null) return output.readByteArray()
            val text = configuredText.toString()
            checkActive()
            budget.textBytes(text, BookExportLimits.PACKAGE_BYTES)
            val bytes = encodeBookExportText(text, options.charset, checkActive)
            checkActive()
            requireBookExport(bytes.isNotEmpty() && bytes.size.toLong() <= BookExportLimits.PACKAGE_BYTES,
                "导出文件为空或超过 128 MiB 限制")
            return bytes
        } finally {
            output.clear()
            configuredText.clear()
        }
    }

    private suspend fun epub(
        book: Book,
        directory: List<BookChapter>,
        state: State,
        budget: BookExportBudget,
        onProgress: (BookExportProgress) -> Unit,
        checkActive: () -> Unit,
        options: BookExportOptions? = null,
        batchBudget: BookExportBatchBudget? = null,
    ): ByteArray {
        val collector = BookExportImages(book, images, budget, directory.size + 5, checkActive)
        val chapterEntries = mutableListOf<EpubChapterEntry>()
        val zipEntries = mutableListOf<ZipEntryData>()
        directory.forEachIndexed { index, originalChapter ->
            checkActive()
            val source = chapterContent(book, originalChapter, budget, checkActive, options)
            val chapter = source.chapter
            val document = BookExportDocument.parse(chapter, source.body, imageBook = book.isImage)
            checkActive()
            repeat(document.imageCount) { budget.imageOccurrence() }
            val paths = linkedMapOf<String, String>()
            var missing = document.imageCount - document.imageSources.size
            for (imageSource in document.imageSources) {
                checkActive()
                val path = collector.bodyPath(imageSource)
                if (path == null) missing++ else paths[imageSource] = path
            }
            state.missingImages += missing
            val readable = source.hasContent && (document.hasReadableText || paths.isNotEmpty())
            val emptyVolume = !readable && chapter.isVolume && chapter.title.isNotBlank() && document.imageCount == 0
            when {
                readable -> state.readable++
                !emptyVolume -> state.missingChapters++
            }
            val body = document.render(paths) + if (!readable && !emptyVolume) {
                BookExportDocument.parse(chapter, missingChapterMessage(book)).render(emptyMap())
            } else ""
            checkActive()
            val entry = EpubChapterEntry(chapter, "chapter_${index + 1}.xhtml", "")
            val xhtml = epubChapterXhtml(book, entry, body = body, includeTitle = options?.includeChapterTitle ?: true)
            budget.rendered(xhtml)
            chapterEntries += entry
            zipEntries += ZipEntryData("OEBPS/Text/${entry.fileName}", xhtml.encodeToByteArray())
            checkActive()
            progress(index + 1, directory.size, onProgress, checkActive)
        }
        if (options == null) requireReadable(state.readable, txt = false)
        collector.cover()
        checkActive()
        fun document(path: String, text: String) {
            checkActive()
            budget.textBytes(text, BookExportLimits.RESOURCE_BYTES)
            zipEntries += ZipEntryData(path, text.encodeToByteArray())
        }
        document("mimetype", "application/epub+zip")
        document("META-INF/container.xml", epubContainerXml())
        document("OEBPS/content.opf", epubOpf(book.copy(intro = book.displayIntro), chapterEntries,
            resources = collector.resources, includeNcx = true))
        document("OEBPS/nav.xhtml", epubNav(book, chapterEntries))
        document("OEBPS/toc.ncx", epubNcx(book, chapterEntries))
        zipEntries += collector.entries
        budget.archive(zipEntries)
        batchBudget?.archive(zipEntries)
        checkActive()
        return buildStoredZip(zipEntries, checkActive).also { checkActive() }
    }

    private suspend fun chapterContent(
        book: Book,
        chapter: BookChapter,
        budget: BookExportBudget,
        checkActive: () -> Unit,
        options: BookExportOptions?,
    ): ChapterContent {
        val raw = read(book, chapter)
        checkActive()
        raw?.let(budget::body)
        val hasContent = !raw.isNullOrBlank()
        if (options == null || transform == null) {
            requireBookExport(options?.useReplaceRules != true, "正文替换规则服务不可用，无法导出")
            return ChapterContent(chapter, raw.orEmpty(), hasContent)
        }
        val transformed = transform.transform(book, chapter, raw.orEmpty(), options.useReplaceRules)
        checkActive()
        budget.textBytes(transformed.chapter.title, 64L * 1024, "导出章节标题超过 64 KiB 限制")
        budget.textBytes(transformed.body, BookExportLimits.CHAPTER_BODY_BYTES, "单章正文超过 16 MiB 导出限制")
        return ChapterContent(transformed.chapter, if (hasContent) transformed.body else "", hasContent)
    }

    private suspend fun read(book: Book, chapter: BookChapter): String? {
        currentCoroutineContext().ensureActive()
        // A local edit is authoritative; original parser content is only a cache-miss fallback.
        val cached = content.getContent(book, chapter)
        currentCoroutineContext().ensureActive()
        if (cached != null || !book.isLocal) return cached
        return try {
            localContent.read(book, chapter)
        } catch (error: Exception) {
            currentCoroutineContext().ensureActive()
            findFacadeRequestCancellation(error)?.let { throw it }
            if (error is BookExportFailure) throw error
            null
        }
    }

    private fun result(bytes: ByteArray, extension: String, chapterCount: Int, state: State): BookExportResult {
        requireBookExport(bytes.isNotEmpty() && bytes.size.toLong() <= BookExportLimits.PACKAGE_BYTES,
            "导出文件为空或超过 128 MiB 限制")
        return BookExportResult(
            data = bytes,
            fileExtension = extension,
            chapterCount = chapterCount,
            readableChapterCount = state.readable,
            missingChapterCount = state.missingChapters,
            missingImageCount = state.missingImages,
        )
    }

    private fun requireReadable(readable: Int, txt: Boolean) {
        requireBookExport(readable > 0, if (txt) {
            "没有可导出的正文文本；TXT 不包含图片，请检查本地文件、已有缓存或改用 EPUB"
        } else "全部正文或正文图片缺失，请检查本地文件或已有缓存后重试")
    }

    private fun missingChapterMessage(book: Book): String =
        if (book.isLocal) "[正文缺失：本地章节内容不可用]" else "[正文未缓存]"

    private fun progress(
        completed: Int,
        total: Int,
        callback: (BookExportProgress) -> Unit,
        checkActive: () -> Unit,
    ) {
        checkActive()
        callback(BookExportProgress(completed, total))
        checkActive()
    }

    private class State {
        var readable = 0
        var missingChapters = 0
        var missingImages = 0
    }

    private data class Snapshot(val book: Book, val extension: String, val directory: List<BookChapter>) {
        override fun toString(): String = "BookExportEngine.Snapshot(redacted)"
    }

    private data class ChapterContent(val chapter: BookChapter, val body: String, val hasContent: Boolean) {
        override fun toString(): String = "BookExportEngine.ChapterContent(redacted)"
    }

    private companion object {
        const val TXT_IMAGE_MISSING = "[图片未导出：TXT 不包含图片资源]"
    }
}
