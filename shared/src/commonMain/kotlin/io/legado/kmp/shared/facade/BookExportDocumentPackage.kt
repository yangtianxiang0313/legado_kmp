package io.legado.kmp.shared.facade

import com.fleeksoft.ksoup.Ksoup
import io.ktor.http.encodeURLPathPart
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.util.md5Hex
import kotlinx.datetime.Clock
import kotlinx.datetime.Instant

internal fun epubOpf(
    book: Book,
    chapters: List<EpubChapterEntry>,
    resources: List<EpubResourceEntry> = emptyList(),
    language: String = "zh-CN",
    includeNcx: Boolean = false,
    resourceProperties: Map<String, Set<String>> = emptyMap(),
): String {
    val indexed = epubIndexedChapters(chapters)
    val paths = (listOf("content.opf", "nav.xhtml", "toc.ncx") + indexed.map { it.path }).map { it.lowercase() }.toMutableSet()
    require(resources.count { it.isCover } <= 1) { "EPUB 只能声明一张封面" }
    resources.forEach { resource ->
        validateExportArchivePath(resource.path)
        require(paths.add(resource.path.lowercase())) { "EPUB 资源路径重名：${resource.path}" }
        requireEpubStaticMediaType(resource.mediaType, resource.isCover)
    }
    val coverIndex = resources.indexOfFirst { it.isCover }
    val description = book.displayIntro?.takeIf { it.isNotEmpty() }?.let {
        val safe = BookExportDocument.parse(BookChapter(), it).render(emptyMap(), "")
        Ksoup.parseBodyFragment(safe).text()
    }.orEmpty()
    val modified = Instant.fromEpochSeconds(Clock.System.now().epochSeconds).toString()
    return buildString {
        append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
        append("<package xmlns=\"http://www.idpf.org/2007/opf\" unique-identifier=\"book-id\" version=\"3.0\" xml:lang=\"")
            .append(epubLanguage(language)).append("\">\n")
        append("  <metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\">\n")
        append("    <dc:identifier id=\"book-id\">").append(epubIdentifier(book)).append("</dc:identifier>\n")
        append("    <dc:title>").append(book.name.xmlEscaped()).append("</dc:title>\n")
        append("    <dc:creator>").append(book.author.ifBlank { "Unknown" }.xmlEscaped()).append("</dc:creator>\n")
        append("    <dc:language>").append(epubLanguage(language)).append("</dc:language>\n")
        append("    <dc:publisher>Legado</dc:publisher>\n")
        if (description.isNotEmpty()) append("    <dc:description>").append(description.xmlEscaped()).append("</dc:description>\n")
        append("    <meta property=\"dcterms:modified\">").append(modified).append("</meta>\n")
        if (coverIndex >= 0) append("    <meta name=\"cover\" content=\"resource-").append(coverIndex + 1).append("\"/>\n")
        append("  </metadata>\n  <manifest>\n")
        append("    <item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>\n")
        if (includeNcx) append("    <item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>\n")
        indexed.forEach { chapter ->
            append("    <item id=\"").append(chapter.id).append("\" href=\"").append(chapter.path.epubHref())
                .append("\" media-type=\"application/xhtml+xml\"")
            val properties = epubXhtmlManifestProperties(chapter.entry.content, chapter.path, resourceProperties)
            if (properties.isNotEmpty()) append(" properties=\"").append(properties.joinToString(" ")).append('"')
            append("/>\n")
        }
        resources.forEachIndexed { index, resource ->
            append("    <item id=\"resource-").append(index + 1).append("\" href=\"").append(resource.path.epubHref())
                .append("\" media-type=\"").append(resource.mediaType.xmlEscaped()).append('"')
            val properties = resourceProperties[resource.path].orEmpty().toMutableSet()
            require(properties.all { it in setOf("svg", "mathml", "remote-resources") }) { "EPUB 静态资源属性无效" }
            require(resource.mediaType in setOf("text/html", "application/xhtml+xml") ||
                properties.none { it in setOf("svg", "mathml") }) { "EPUB 独立资源不能声明 XHTML 内联属性" }
            if (resource.isCover) properties += "cover-image"
            if (properties.isNotEmpty()) append(" properties=\"").append(properties.joinToString(" ")).append('"')
            append("/>\n")
        }
        append("  </manifest>\n  <spine")
        if (includeNcx) append(" toc=\"ncx\"")
        append(">\n")
        indexed.forEach { append("    <itemref idref=\"").append(it.id).append("\"/>\n") }
        append("  </spine>\n</package>\n")
    }
}

internal fun epubNav(book: Book, chapters: List<EpubChapterEntry>, language: String = "zh-CN"): String {
    val roots = epubNavigation(chapters)
    return buildString {
        append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE html>\n")
        append("<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\" lang=\"")
            .append(epubLanguage(language)).append("\" xml:lang=\"").append(epubLanguage(language)).append("\">\n")
        append("<head><title>").append(book.name.xmlEscaped()).append("</title></head>\n<body>\n")
        append("<nav epub:type=\"toc\" id=\"toc\"><h1>").append(book.name.xmlEscaped()).append("</h1>\n<ol>\n")
        roots.forEach { root ->
            appendNavItem(root.chapter)
            if (root.children.isNotEmpty()) {
                append("<ol>\n")
                root.children.forEach { child -> appendNavItem(child); append("</li>\n") }
                append("</ol>\n")
            }
            append("</li>\n")
        }
        append("</ol></nav>\n</body>\n</html>\n")
    }
}

internal fun epubNcx(book: Book, chapters: List<EpubChapterEntry>, language: String = "zh-CN"): String {
    val roots = epubNavigation(chapters)
    return buildString {
        append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
        append("<ncx xmlns=\"http://www.daisy.org/z3986/2005/ncx/\" version=\"2005-1\" xml:lang=\"")
            .append(epubLanguage(language)).append("\">\n<head>\n")
        append("<meta name=\"dtb:uid\" content=\"").append(epubIdentifier(book)).append("\"/>\n")
        append("<meta name=\"dtb:depth\" content=\"").append(if (roots.any { it.children.isNotEmpty() }) 2 else 1).append("\"/>\n")
        append("<meta name=\"dtb:totalPageCount\" content=\"0\"/><meta name=\"dtb:maxPageNumber\" content=\"0\"/>\n</head>\n")
        append("<docTitle><text>").append(book.name.xmlEscaped()).append("</text></docTitle>\n<navMap>\n")
        roots.forEach { root ->
            appendNcxPoint(root.chapter)
            root.children.forEach { child -> appendNcxPoint(child); append("</navPoint>\n") }
            append("</navPoint>\n")
        }
        append("</navMap>\n</ncx>\n")
    }
}

/** entry.content remains raw content. Only body is already rendered, safe XHTML. */
internal fun epubChapterXhtml(
    book: Book,
    entry: EpubChapterEntry,
    body: String? = null,
    language: String = "zh-CN",
    includeTitle: Boolean = true,
): String {
    val rendered = body ?: BookExportDocument.parse(entry.chapter, entry.content).render(emptyMap())
    return """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" lang="${epubLanguage(language)}" xml:lang="${epubLanguage(language)}">
<head>
  <title>${entry.chapter.title.xmlEscaped()} - ${book.name.xmlEscaped()}</title>
  <meta charset="UTF-8"/>
  <style type="text/css">body { overflow-wrap: break-word; } img { max-width: 100%; height: auto; }</style>
</head>
<body>
  ${if (includeTitle) "<h1>${entry.chapter.title.xmlEscaped()}</h1>" else ""}
$rendered
</body>
</html>
"""
}

private data class IndexedEpubChapter(val entry: EpubChapterEntry, val order: Int) {
    val id: String = "chapter-$order"
    val path: String = "Text/${entry.fileName}"
}

private data class EpubNavigationNode(val chapter: IndexedEpubChapter, val children: MutableList<IndexedEpubChapter> = mutableListOf())

private fun epubIndexedChapters(chapters: List<EpubChapterEntry>): List<IndexedEpubChapter> {
    val paths = mutableSetOf<String>()
    return chapters.mapIndexed { index, entry ->
        IndexedEpubChapter(entry, index + 1).also {
            validateExportArchivePath(it.path)
            require(paths.add(it.path.lowercase())) { "EPUB 正文章节文件名重名：${entry.fileName}" }
        }
    }
}

private fun epubNavigation(chapters: List<EpubChapterEntry>): List<EpubNavigationNode> {
    val roots = mutableListOf<EpubNavigationNode>()
    var volume: EpubNavigationNode? = null
    epubIndexedChapters(chapters).forEach { chapter ->
        if (chapter.entry.chapter.isVolume) {
            volume = EpubNavigationNode(chapter).also { roots.add(it) }
        } else {
            val parent = volume
            if (parent == null) roots += EpubNavigationNode(chapter) else parent.children += chapter
        }
    }
    return roots
}

private fun StringBuilder.appendNavItem(chapter: IndexedEpubChapter) {
    append("<li id=\"toc-").append(chapter.id).append("\"><a href=\"").append(chapter.path.epubHref()).append("\">")
        .append(chapter.entry.chapter.title.xmlEscaped()).append("</a>\n")
}

private fun StringBuilder.appendNcxPoint(chapter: IndexedEpubChapter) {
    append("<navPoint id=\"nav-").append(chapter.id).append("\" playOrder=\"").append(chapter.order).append("\">\n")
    append("<navLabel><text>").append(chapter.entry.chapter.title.xmlEscaped()).append("</text></navLabel>\n")
    append("<content src=\"").append(chapter.path.epubHref()).append("\"/>\n")
}

private fun epubIdentifier(book: Book): String = "legado-" + book.bookUrl.ifBlank { "${book.name}\n${book.author}" }.md5Hex()

private fun String.epubHref(): String = split('/').joinToString("/") { it.encodeURLPathPart() }.xmlEscaped()

private val EPUB_IMAGE_MEDIA_TYPES = setOf(
    "image/jpeg", "image/png", "image/gif", "image/webp", "image/bmp", "image/svg+xml", "image/avif",
    "image/heic", "image/heif", "image/tiff", "image/x-icon",
)

internal fun requireEpubStaticMediaType(mediaType: String, isCover: Boolean = false) {
    require(mediaType in EPUB_IMAGE_MEDIA_TYPES || mediaType in EPUB_STATIC_MEDIA_TYPES) {
        "EPUB 静态资源媒体类型无效：$mediaType"
    }
    require(!isCover || mediaType in EPUB_IMAGE_MEDIA_TYPES) { "EPUB 封面必须是真实图片资源" }
}

private val EPUB_STATIC_MEDIA_TYPES = setOf(
    "text/css", "font/ttf", "font/otf", "font/woff", "font/woff2", "font/collection", "font/sfnt",
    "application/vnd.ms-opentype", "application/font-sfnt", "application/font-woff",
    "application/x-font-ttf", "application/x-font-truetype", "application/x-font-opentype",
    "application/x-font-otf", "application/x-font-woff", "application/x-font-woff2",
    "application/xhtml+xml", "text/html", "text/plain", "application/xml", "application/json",
    "application/smil+xml", "application/pls+xml", "application/mathml+xml", "text/vtt",
    "audio/mpeg", "audio/mp4", "audio/ogg", "audio/wav", "audio/flac",
)
