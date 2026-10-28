package io.legado.kmp.shared.domain.localbook

import com.fleeksoft.ksoup.Ksoup
import com.fleeksoft.ksoup.nodes.Element
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.ReadConfig
import io.legado.kmp.shared.util.unescapeHtml4

internal object EpubChapterContent {
    private const val INLINE_SVG_PREFIX = "epub-inline-svg:///"
    private val hiddenStyle = Regex("(?:^|;)\\s*display\\s*:\\s*none\\s*(?:!important\\s*)?(?:;|$)", RegexOption.IGNORE_CASE)

    fun format(
        book: Book,
        path: String,
        html: String,
        startFragmentId: String? = null,
        endFragmentId: String? = null,
        checkActive: () -> Unit = {}
    ): String {
        checkActive()
        val originalBody = Ksoup.parse(html).body()
        // Replace whole SVGs before generic HTML cleanup can remove their style/title or split their graphics.
        inlineImages(originalBody).forEachIndexed { index, element ->
            checkActive()
            val source = INLINE_SVG_PREFIX + EpubResourcePaths.toUrl(path).removePrefix("epub-resource:///") + "?svg=$index"
            val image = Element("img").attr("src", source)
            listOf("id", "name").filter(element::hasAttr).forEach { image.attr(it, element.attr(it)) }
            if (element.hasAttr("hidden")) image.attr("hidden", "")
            if (hiddenStyle.containsMatchIn(element.attr("style"))) image.attr("style", "display:none")
            element.attr("alt").ifBlank { element.attr("aria-label") }.takeIf { it.isNotBlank() }
                ?.let { image.attr("alt", it) }
            element.replaceWith(image)
        }
        // Assign SVG indices in the full original document, never in a chapter fragment.
        val body = EpubDomRange.slice(originalBody, startFragmentId, endFragmentId, checkActive)
        body.select("script, style, title, head, iframe, [hidden]").remove()
        body.getAllElements().filter { hiddenStyle.containsMatchIn(it.attr("style")) }.forEach { it.remove() }
        if (book.config.hasDelTag(ReadConfig.Companion.DeleteTags.H_TAG)) body.select("h1, h2, h3, h4, h5, h6").remove()
        if (book.config.hasDelTag(ReadConfig.Companion.DeleteTags.RUBY_TAG)) body.select("rp, rt").remove()

        body.getAllElements().filter { it.epubName() in setOf("img", "image", "object") }.forEach { element ->
            checkActive()
            val reference = EpubEmbeddedImage.reference(element)
            if (isInlineImage(reference)) return@forEach
            if (element.epubName() == "object" && !EpubEmbeddedImage.isImagePath(reference.substringBefore('#'))) {
                return@forEach
            }
            val source = if (reference.startsWith("data:", true)) {
                reference.takeIf { EpubEmbeddedImage.readDataUrl(it, checkActive) != null }
            } else {
                // Missing archive entries stay image blocks and use the reader's existing failure state.
                EpubResourcePaths.resolve(path.substringBeforeLast('/', ""), reference)?.let(EpubResourcePaths::toUrl)
            }
            if (source == null) {
                element.remove()
            } else {
                val image = Element("img").attr("src", source)
                element.attr("alt").takeIf { it.isNotBlank() }?.let { image.attr("alt", it) }
                element.replaceWith(image)
            }
        }
        checkActive()
        return unescapeHtml4(LocalBookHtmlFormatter.formatKeepImg(body.html()))
    }

    fun isInlineImage(reference: String): Boolean = reference.startsWith(INLINE_SVG_PREFIX)

    fun readInlineImage(archive: EpubArchive, reference: String, checkActive: () -> Unit = {}): ByteArray? {
        checkActive()
        require(isInlineImage(reference) && reference.length <= 8192) { "EPUB inline SVG 地址无效或过长" }
        val value = reference.removePrefix(INLINE_SVG_PREFIX)
        val query = value.substringAfter('?', "")
        require(query.startsWith("svg=")) { "EPUB inline SVG 索引缺失" }
        val index = query.removePrefix("svg=").toIntOrNull()
        require(index != null && index in 0 until 100_000) { "EPUB inline SVG 索引无效" }
        val path = EpubResourcePaths.resolve("", value.substringBefore('?'))
            ?: error("EPUB inline SVG 章节路径无效")
        val html = archive.readText(path) ?: return null
        if (LocalBookSvg.isSvg(html.encodeToByteArray())) {
            require(index == 0) { "EPUB SVG 文档图片索引无效" }
            return EpubEmbeddedImage.prepareSvg(archive, path, html, checkActive)
        }
        // HTML parsing never expands custom entities; do not erase their declaration before SVG validation.
        require(!html.contains(Regex("<!ENTITY\\b|<!DOCTYPE[^>]*\\[", RegexOption.IGNORE_CASE))) {
            "EPUB inline SVG 不支持自定义 DTD 或实体"
        }
        val body = Ksoup.parse(html).body()
        val element = inlineImages(body).getOrNull(index) ?: error("EPUB inline SVG 已不存在")
        val xml = if (element.epubName() == "svg") LocalBookSvg.serialize(element) else {
            val bytes = requireNotNull(EpubEmbeddedImage.readDataUrl(EpubEmbeddedImage.reference(element), checkActive)) {
                "EPUB inline SVG data 图片无效"
            }
            decodeEpubText(bytes)
        }
        return EpubEmbeddedImage.prepareSvg(archive, path, xml, checkActive)
    }

    private fun inlineImages(body: Element): List<Element> = body.getAllElements().filter { element ->
        val name = element.epubName()
        (name == "svg" || name in setOf("img", "image", "object") &&
            EpubEmbeddedImage.isSvgDataUrl(EpubEmbeddedImage.reference(element))) &&
            element.parents().none { it.epubName() == "svg" }
    }
}
