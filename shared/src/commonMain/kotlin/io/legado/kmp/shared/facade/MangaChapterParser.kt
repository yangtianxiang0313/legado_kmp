package io.legado.kmp.shared.facade

import io.legado.kmp.shared.content.BookImageMarkup
import io.legado.kmp.shared.model.BaseMangaPage
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.MangaChapter
import io.legado.kmp.shared.model.MangaPage
import io.legado.kmp.shared.model.ReaderLoading
import io.legado.kmp.shared.util.unescapeHtml4

internal object MangaChapterParser {
    private val ruleSuffix = Regex("""\s*,\s*(?=\{)""")
    private val absoluteScheme = Regex("""^[A-Za-z][A-Za-z0-9+.-]*:""")

    fun parse(chapter: BookChapter, content: String, chapterSize: Int, hideTitle: Boolean): MangaChapter {
        val sources = imageSources(chapter, content)
        val images = sources.mapIndexed { index, source ->
            MangaPage(
                chapterIndex = chapter.index,
                chapterSize = chapterSize,
                mImageUrl = source,
                index = index,
                imageCount = sources.size,
                mChapterName = chapter.title,
            )
        }
        if (hideTitle && images.isNotEmpty()) return MangaChapter(chapter, images, images.size)
        val pages = mutableListOf<BaseMangaPage>()
        if (images.isEmpty() && chapter.isVolume) {
            pages += ReaderLoading(chapter.index, -1, chapter.title, true)
        } else {
            pages += ReaderLoading(chapter.index, -1, "阅读 ${chapter.title}")
            pages.addAll(images)
            pages += ReaderLoading(chapter.index, images.size, "已读完 ${chapter.title}")
        }
        return MangaChapter(chapter, pages, images.size)
    }

    internal fun imageSources(chapter: BookChapter, content: String): List<String> {
        val sources = BookImageMarkup.images(content).map { it.source }.ifEmpty { lineImageSources(content) }
        val base = imageBaseUrl(chapter)
        // Keep every occurrence: repeated URLs still represent separate page positions.
        return sources.mapNotNull { raw ->
            val source = raw.trim().takeIf { it.isNotEmpty() } ?: return@mapNotNull null
            BookImageMarkup.absoluteSource(source, base)
        }
    }

    internal fun imageBaseUrl(chapter: BookChapter): String {
        val chapterUrl = chapter.getAbsoluteUrl()
        return ruleSuffix.find(chapterUrl)?.let { chapterUrl.substring(0, it.range.first) }
            ?: chapterUrl.ifBlank { chapter.baseUrl }
    }

    private fun lineImageSources(content: String): List<String> {
        // HTML extraction can fold raw URL line breaks into spaces. Options JSON must remain intact.
        val raw = if (ruleSuffix.containsMatchIn(content)) content.lineSequence() else content.splitToSequence(Regex("\\s+"))
        val lines = raw.map { unescapeHtml4(it.trim()) }.filter(String::isNotEmpty).toList()
        val imageExtensions = setOf("jpg", "jpeg", "png", "gif", "webp", "avif", "apng", "bmp", "svg", "ico", "tif", "tiff", "heic", "heif")
        // Android extracts img tags only; URL-only lines are an explicit shared extension.
        // Validate the URL separately so whitespace and quotes in ,{options} remain supported.
        return lines.takeIf { sources ->
            sources.all { source ->
                val separator = ruleSuffix.find(source)
                val url = separator?.let { source.substring(0, it.range.first) } ?: source
                val path = url.substringBefore('?').substringBefore('#')
                val recognizable = if (absoluteScheme.containsMatchIn(url)) {
                    url.startsWith("http://", ignoreCase = true) || url.startsWith("https://", ignoreCase = true)
                } else {
                    '/' in path || path.substringAfterLast('.', "").lowercase() in imageExtensions
                }
                recognizable && url.isNotEmpty() && url.none { it.isWhitespace() || it.isISOControl() || it in "<>\"" }
            }
        }.orEmpty()
    }
}
