package io.legado.kmp.shared.facade

import com.fleeksoft.ksoup.Ksoup
import com.fleeksoft.ksoup.nodes.DataNode
import com.fleeksoft.ksoup.nodes.Element
import com.fleeksoft.ksoup.nodes.TextNode
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter

/** Layout only: the caller owns image collection, budgets, reading order and ZIP writes. */
internal class BookExportEpubLayout(
    private val book: Book,
    custom: BookExportEpubTemplateArchive?,
    private val coverPath: String?,
    private val includeTitle: Boolean,
    private val checkActive: () -> Unit,
) {
    val frontMatter: List<EpubChapterEntry>
    val resources: List<EpubResourceEntry>
    val entries: List<ZipEntryData>
    val resourceProperties: Map<String, Set<String>>

    private val chapterTemplate = custom?.chapterTemplate ?: DEFAULT_CHAPTER
    private val hasTemplateCover = custom?.resources?.any { it.path == "Images/cover.jpg" } == true

    init {
        checkActive()
        coverPath?.let(::validateExportArchivePath)
        val paths = mutableSetOf("content.opf", "nav.xhtml", "toc.ncx")
        coverPath?.let { paths += it.lowercase() }
        val resourceList = mutableListOf<EpubResourceEntry>()
        val entryList = mutableListOf<ZipEntryData>()
        val resourceContent = mutableMapOf<String, String>()
        val assets = custom?.resources ?: listOf(
            BookExportEpubTemplateAsset("Styles/fonts.css", DEFAULT_FONTS.encodeToByteArray(), "text/css"),
            BookExportEpubTemplateAsset("Styles/main.css", DEFAULT_CSS.encodeToByteArray(), "text/css"),
        )
        assets.forEach { asset ->
            checkActive()
            claimPath(asset.path, paths)
            requireEpubStaticMediaType(asset.mediaType)
            require(asset.data.size <= 64 * 1024 * 1024) { "EPUB 模板资源超过 64 MiB：${asset.path}" }
            val mediaType = if (asset.mediaType == "text/html") "application/xhtml+xml" else asset.mediaType
            val text = when (asset.mediaType) {
                "text/css" -> epubTemplateCss(asset.data.decodeToString(throwOnInvalidSequence = true), checkActive)
                "image/svg+xml" -> epubTemplateSvg(asset.data.decodeToString(throwOnInvalidSequence = true), checkActive)
                "text/html", "application/xhtml+xml" -> {
                    val document = epubTemplateDocument(asset.data.decodeToString(throwOnInvalidSequence = true), checkActive)
                    if (document.head().select("title").isEmpty()) document.head().appendElement("title")
                        .text(asset.path.substringAfterLast('/').substringBeforeLast('.'))
                    epubTemplateXhtml(document, checkActive)
                }
                "application/xml", "application/smil+xml", "application/pls+xml", "application/mathml+xml" ->
                    epubTemplateXml(asset.data.decodeToString(throwOnInvalidSequence = true), checkActive)
                else -> null
            }
            val bytes = text?.encodeToByteArray() ?: asset.data
            if (text != null) resourceContent[asset.path] = text
            resourceList += EpubResourceEntry(asset.path, mediaType)
            entryList += ZipEntryData("OEBPS/${asset.path}", bytes)
        }
        resources = resourceList
        entries = entryList
        resourceProperties = epubStaticResourceProperties(resourceList, resourceContent, checkActive)

        val intro = BookExportDocument.parse(BookChapter(), book.displayIntro.orEmpty(), checkActive = checkActive)
            .render(emptyMap(), "")
        val values = mapOf(
            "name" to book.name, "author" to book.author, "intro" to Ksoup.parseBodyFragment(intro).text(),
            "kind" to book.kind.orEmpty(), "wordCount" to book.wordCount.orEmpty(),
        )
        val sections = custom?.sectionTemplates ?: listOf(
            BookExportEpubTemplateAsset("Text/cover.html", DEFAULT_COVER.encodeToByteArray(), "application/xhtml+xml"),
            BookExportEpubTemplateAsset("Text/intro.html", DEFAULT_INTRO.encodeToByteArray(), "application/xhtml+xml"),
        )
        frontMatter = sections.map { asset ->
            checkActive()
            claimPath(asset.path, paths)
            require(asset.path.startsWith("Text/") && asset.path.length > 5) { "EPUB 前页必须位于 Text/：${asset.path}" }
            val fileName = asset.path.removePrefix("Text/")
            val title = if (custom == null) {
                if (fileName == "cover.html") "封面" else "简介"
            } else fileName.substringAfterLast('/').substringBeforeLast('.')
            val xhtml = render(
                asset.data.decodeToString(throwOnInvalidSequence = true), asset.path, values,
                mapOf("intro" to intro), "$title - ${book.name}",
            )
            EpubChapterEntry(BookChapter(title = title, bookUrl = book.bookUrl), fileName, xhtml)
        }
    }

    /** body is the existing BookExportDocument's rendered XHTML, with Text/-relative image paths. */
    fun chapter(entry: EpubChapterEntry, body: String): String {
        checkActive()
        val path = "Text/${entry.fileName}"
        validateExportArchivePath(path)
        val values = mapOf("title" to entry.chapter.title, "ori_title" to entry.chapter.title,
            "content" to Ksoup.parseBodyFragment(body).text())
        val fragments = mapOf("title" to chapterTitle(entry.chapter.title), "content" to body)
        return render(chapterTemplate, path, values, fragments,
            "${entry.chapter.title} - ${book.name}", chapter = true)
    }

    private fun render(
        template: String,
        path: String,
        values: Map<String, String>,
        fragments: Map<String, String>,
        accessibleTitle: String,
        chapter: Boolean = false,
    ): String {
        val document = epubTemplateDocument(template, checkActive)
        val contentSlots = if (chapter) epubTemplateContentSlots(document, checkActive).toSet() else emptySet()
        require(!chapter || contentSlots.isNotEmpty()) { "EPUB 章节模板缺少有效的正文占位符" }
        var contentInsertions = 0
        val contentParents = mutableSetOf<Element>()
        // Snapshot before insertion: tokens inside metadata, intro or body are never expanded again.
        val nodes = epubTemplateNodes(document, checkActive)
        val titleHeadings = if (chapter && !includeTitle) document.body().select("h1,h2,h3,h4,h5,h6")
            .filter { TITLE_TOKEN.containsMatchIn(it.text()) && "{content}" !in it.text() } else emptyList()
        nodes.forEach { node ->
            checkActive()
            when (node) {
                is Element -> node.attributes().toList().forEach { attribute ->
                    node.attr(attribute.key, replaceText(attribute.value, values))
                }
                is TextNode -> {
                    val original = node.getWholeText()
                    if (!TOKEN.containsMatchIn(original)) return@forEach
                    val inHead = node.parentsContain("head")
                    val rawText = inHead || RAW_TEXT_CONTEXTS.any { node.parentsContain(it) }
                    if (rawText) node.text(replaceText(original, values)) else {
                        val replacement = TOKEN.replace(original.xmlEscaped()) { match ->
                            val key = match.groupValues[1]
                            if (key == "content" && node in contentSlots) {
                                contentInsertions++
                                (node.parent() as? Element)?.let(contentParents::add)
                            }
                            if (chapter && !includeTitle && key in TITLE_KEYS) ""
                            else fragments[key] ?: values[key]?.xmlEscaped() ?: match.value
                        }
                        node.before(replacement)
                        node.remove()
                    }
                }
                is DataNode -> node.replaceWith(TextNode(replaceText(node.getWholeData(), values)))
            }
        }
        titleHeadings.filter { it.text().isBlank() && it.children().isEmpty() }.forEach { it.remove() }
        // Only the Android cover slot is redirected; unrelated images and CSS URLs stay untouched.
        document.select("img[src], image[href], image[xlink:href]").forEach { image ->
            listOf("src", "href", "xlink:href").forEach { attribute ->
                if (image.attr(attribute).trim() == "../Images/cover.jpg") {
                    if (coverPath != null) image.attr(attribute, relativePath(path, coverPath))
                    else if (!hasTemplateCover) image.remove()
                }
            }
        }
        val head = document.head()
        if (head.select("title").isEmpty()) head.appendElement("title").text(accessibleTitle)
        else if (head.select("title").first()?.text().isNullOrBlank()) head.select("title").first()?.text(accessibleTitle)
        require(!chapter || contentInsertions > 0) { "EPUB 章节正文未插入模板" }
        val rendered = epubTemplateXhtml(document, checkActive)
        require(!chapter || contentParents.any { parent ->
            parent === document.body() || parent.parents().any { it === document.body() }
        }) { "EPUB 章节正文被模板净化移除" }
        return rendered
    }

    private fun replaceText(value: String, values: Map<String, String>): String =
        TOKEN.replace(value) { values[it.groupValues[1]] ?: it.value }

    private fun chapterTitle(title: String): String {
        // Java's first \\s+ splits the sequence number, not arbitrary injected </span> text.
        val space = TITLE_SPACE.find(title) ?: return title.xmlEscaped()
        return "<span class=\"chapter-sequence-number\">${title.substring(0, space.range.first).xmlEscaped()}</span><br/>" +
            title.substring(space.range.last + 1).xmlEscaped()
    }

    private fun claimPath(path: String, paths: MutableSet<String>) {
        validateExportArchivePath(path)
        require(paths.add(path.lowercase())) { "EPUB 模板路径重名：$path" }
    }

    private fun relativePath(from: String, to: String): String {
        val parent = from.split('/').dropLast(1)
        val target = to.split('/')
        val shared = parent.zip(target).takeWhile { (left, right) -> left == right }.size
        return (List(parent.size - shared) { ".." } + target.drop(shared)).joinToString("/")
    }

    companion object {
        private val TOKEN = Regex("\\{(title|ori_title|content|name|author|intro|kind|wordCount)\\}")
        private val TITLE_TOKEN = Regex("\\{(?:title|ori_title)\\}")
        private val TITLE_KEYS = setOf("title", "ori_title")
        private val RAW_TEXT_CONTEXTS = setOf("style", "title", "textarea", "xmp", "plaintext", "noembed", "noframes", "svg", "math", "audio", "video", "picture")
        private val TITLE_SPACE = Regex("""[ \t\n\x0B\f\r]+""")

        // Android 5f5d31404: epub/{chapter,cover,intro}.html and the used main.css selectors.
        private const val DEFAULT_CHAPTER = """<html xmlns="http://www.w3.org/1999/xhtml"><head>
<title>{ori_title}</title><link href="../Styles/fonts.css" type="text/css" rel="stylesheet"/>
<link href="../Styles/main.css" type="text/css" rel="stylesheet"/></head><body>
<h2 class="head">{title}</h2>{content}</body></html>"""
        private const val DEFAULT_COVER = """<html xmlns="http://www.w3.org/1999/xhtml"><head>
<title>{name}</title><link href="../Styles/fonts.css" type="text/css" rel="stylesheet"/>
<link href="../Styles/main.css" type="text/css" rel="stylesheet"/></head><body class="cover">
<div class="pic"><img src="../Images/cover.jpg" alt="{name}"/></div>
<h1 class="cover-title">{name}</h1><div class="author"><b>{author}</b> <span>/ 著</span></div>
</body></html>"""
        private const val DEFAULT_INTRO = """<html xmlns="http://www.w3.org/1999/xhtml"><head>
<title>内容简介 - {name}</title><link href="../Styles/fonts.css" type="text/css" rel="stylesheet"/>
<link href="../Styles/main.css" type="text/css" rel="stylesheet"/></head><body>
<h1 class="head" style="margin-bottom:2em;">内容简介</h1>{intro}</body></html>"""
        private const val DEFAULT_FONTS = """@charset "utf-8";
@font-face { font-family: "zw"; src: local("宋体"), local("Songti SC"), local("Songti TC"), local("DK-SONGTI"); }
@font-face { font-family: "fs"; src: local("仿宋"), local("Yuanti SC"), local("DK-FANGSONG"); }
@font-face { font-family: "kt"; src: local("楷体"), local("Kaiti SC"), local("Kaiti TC"), local("DK-KAITI"); }
@font-face { font-family: "ht"; src: local("黑体"), local("Heiti SC"), local("Heiti TC"), local("DK-HEITI"); }
@font-face { font-family: "h2"; src: local("方正大标宋_GBK"), local("Dabiaosong"), local("DK-XIAOBIAOSONG"); }
"""
        private const val DEFAULT_CSS = """@charset "utf-8";
@import url("fonts.css");
body { padding: 0; margin: 0 0.5%; line-height: 130%; text-align: justify;
    font-family: "DK-SONGTI", "zw", serif; overflow-wrap: break-word; }
p { text-align: justify; text-indent: 2em; line-height: 130%; margin-left: 0.5%; margin-right: 0.5%; }
div { margin: 0; padding: 0; line-height: 120%; }
img { max-width: 100%; height: auto; }
p.kaiti, span.xinli { font-family: "DK-KAITI", "kt", serif; }
p.fangsong { font-family: "DK-FANGSONG", "fs", serif; }
span.xinli { color: #4e753f; }
span.english { font-style: italic; }
h1.head { line-height: 130%; font-size: 1.4em; text-align: center; color: #BA2213;
    font-weight: bold; margin-top: 2em; margin-bottom: 1em; font-family: "h2", serif; }
h2.head { font-family: "h2", serif; text-align: left; font-weight: bold; font-size: 1.1em;
    margin: 1em 2em 2em 0; color: #3f83e8; line-height: 140%; }
h2.head .chapter-sequence-number { font-family: "fs", serif; font-size: 0.7em;
    background-color: #3f83e8; border-radius: 9px; padding: 4px; color: #fff; }
body.cover { text-align: center; }
.pic { margin: 50% 30% 0; padding: 2px; border: 1px solid #f5f5dc; }
.pic:empty { display: none; }
.pic img { width: 100%; height: auto; }
.cover-title { margin-top: 5%; font-size: 110%; }
.author { margin-top: 0; }
.author span { font-size: smaller; }
"""
    }
}

private fun com.fleeksoft.ksoup.nodes.Node.parentsContain(name: String): Boolean {
    var ancestor = parent()
    while (ancestor != null) {
        if (ancestor is Element && ancestor.tagName().equals(name, true)) return true
        ancestor = ancestor.parent()
    }
    return false
}
