package io.legado.kmp.shared.domain.rss

import com.fleeksoft.ksoup.Ksoup
import com.fleeksoft.ksoup.nodes.Element
import com.fleeksoft.ksoup.nodes.TextNode
import com.fleeksoft.ksoup.parser.Parser
import io.legado.kmp.shared.model.RssArticle

object RssParserDefault {

    fun parse(
        sortName: String,
        xml: String,
        sourceUrl: String,
        baseUrl: String = sourceUrl
    ): Pair<List<RssArticle>, String?> {
        val document = parseDefaultRssXml(xml, baseUrl)
        val root = document.children().single()
        return when {
            root.hasName("rss") && root.hasNoNamespace() -> {
                require(root.attr("version").trim() in setOf("", "2.0")) {
                    "Unsupported feed format: expected RSS 2.0"
                }
                val channels = root.childrenNamed("channel")
                require(channels.size == 1) { "Invalid RSS feed: expected one channel" }
                val channel = channels.single()
                channel.childrenNamed("item").mapNotNull { parseRssItem(it, sortName, sourceUrl, baseUrl) } to
                    nextLink(channel, atomNamespace, baseUrl)
            }
            root.hasName("feed") && (root.tag().namespace() == atomNamespace || root.hasNoNamespace()) -> {
                root.childrenNamed("entry").mapNotNull { parseAtomEntry(it, sortName, sourceUrl, baseUrl) } to
                    nextLink(root, root.tag().namespace(), baseUrl)
            }
            else -> throw IllegalArgumentException("Unsupported feed format: expected RSS 2.0 or Atom")
        }
    }

    private fun parseRssItem(item: Element, sortName: String, sourceUrl: String, baseUrl: String): RssArticle? {
        val title = item.childNamed("title")?.text()?.trim().orEmpty()
        val link = item.childNamed("link")?.let { resolveUrl(it, it.wholeText(), baseUrl) }
        if (title.isBlank() || link == null) return null

        val description = item.childNamed("description")?.let { rssBody(it, baseUrl) }
        val content = item.childNamed("encoded", contentNamespace)?.let { rssBody(it, baseUrl) }
            ?: description
        val enclosure = item.childrenNamed("enclosure").firstNotNullOfOrNull { element ->
            if (element.isImage()) resolveUrl(element, element.attr("url"), baseUrl) else null
        }
        val date = item.childText("pubDate") ?: item.childText("time")
            ?: item.childText("date", dcNamespace) ?: item.childText("date", dcTermsNamespace)

        return RssArticle(
            origin = sourceUrl,
            sort = sortName,
            title = title,
            link = link,
            pubDate = date,
            description = description?.text,
            content = content?.html,
            image = mediaImage(item, baseUrl) ?: enclosure ?: content?.image ?: description?.image
        )
    }

    private fun parseAtomEntry(entry: Element, sortName: String, sourceUrl: String, baseUrl: String): RssArticle? {
        val title = entry.childNamed("title")?.let { atomTitle(it, baseUrl) }.orEmpty()
        val alternateLinks = entry.childrenNamed("link").filter {
            it.attr("rel").trim().let { rel -> rel.isEmpty() || rel == "alternate" }
        }.sortedBy {
            when (it.mediaType()) {
                "text/html", "application/xhtml+xml" -> 0
                "" -> 1
                else -> 2
            }
        }
        val link = alternateLinks.firstNotNullOfOrNull { resolveUrl(it, it.attr("href"), baseUrl) }
            ?: entry.childNamed("id")?.let {
                // Atom ids can be URNs; only web ids can substitute for an article link.
                val id = it.wholeText().trim()
                if (id.startsWith("https://", true) || id.startsWith("http://", true)) {
                    resolveUrl(it, id, baseUrl)
                } else null
            }
        if (title.isBlank() || link == null) return null

        val description = entry.childNamed("summary")?.let { atomBody(it, baseUrl) }
        val content = entry.childNamed("content")?.let { atomBody(it, baseUrl) } ?: description
        val enclosure = entry.childrenNamed("link").firstNotNullOfOrNull { element ->
            if (element.attr("rel").trim() == "enclosure" && element.isImage()) {
                resolveUrl(element, element.attr("href"), baseUrl)
            } else null
        }

        return RssArticle(
            origin = sourceUrl,
            sort = sortName,
            title = title,
            link = link,
            pubDate = entry.childText("published") ?: entry.childText("updated"),
            description = description?.text,
            content = content?.html,
            image = mediaImage(entry, baseUrl) ?: enclosure ?: content?.image ?: description?.image
        )
    }

    private fun rssBody(element: Element, baseUrl: String): Body? {
        // XML entities and CDATA are already decoded. Keep any actual child markup as markup.
        val markup = element.childNodes().joinToString("") { node ->
            when (node) {
                is TextNode -> node.getWholeText()
                is Element -> node.outerHtml()
                else -> ""
            }
        }.trim()
        if (markup.isBlank()) return null
        return htmlBody(markup, effectiveBase(element, baseUrl))
    }

    private fun atomTitle(element: Element, baseUrl: String): String {
        return when (element.mediaType()) {
            "", "text", "text/plain" -> element.wholeText().trim()
            "html", "text/html" -> Ksoup.parseBodyFragment(element.wholeText()).body().text()
            "xhtml", "application/xhtml+xml" -> xhtmlBody(element, baseUrl)?.text.orEmpty()
            else -> throw IllegalArgumentException("Unsupported Atom title type: ${element.mediaType()}")
        }
    }

    private fun atomBody(element: Element, baseUrl: String): Body? {
        // External Atom content is not fetched by this synchronous parser.
        if (element.attr("src").isNotBlank()) return null
        return when (element.mediaType()) {
            "", "text", "text/plain" -> {
                val text = element.wholeText().trim()
                if (text.isEmpty()) null else {
                    val body = Ksoup.parseBodyFragment("").body().text(text)
                    body.ownerDocument()?.outputSettings()?.prettyPrint(false)
                    Body(body.html(), null, text)
                }
            }
            "html", "text/html" -> htmlBody(element.wholeText(), effectiveBase(element, baseUrl))
            "xhtml", "application/xhtml+xml" -> xhtmlBody(element, baseUrl)
            else -> throw IllegalArgumentException("Unsupported Atom content type: ${element.mediaType()}")
        }
    }

    private fun xhtmlBody(element: Element, baseUrl: String): Body? {
        val div = element.children().singleOrNull()
        require(div != null && div.hasName("div") && div.tag().namespace() == xhtmlNamespace) {
            "Invalid Atom XHTML: expected one XHTML div"
        }
        require(element.textNodes().all { it.getWholeText().isBlank() }) {
            "Invalid Atom XHTML: text outside the XHTML div"
        }
        val wrapper = div.clone()
        normalizeMarkup(wrapper, effectiveBase(element, baseUrl))
        // Resolve xml:base on the XHTML wrapper before discarding it.
        return htmlBody(wrapper.html(), effectiveBase(element, baseUrl))
    }

    private fun htmlBody(markup: String, baseUrl: String): Body? {
        if (markup.isBlank()) return null
        val document = Ksoup.parseBodyFragment(markup, baseUrl)
        document.outputSettings().prettyPrint(false)
        val body = document.body()
        normalizeMarkup(body, baseUrl)
        val html = body.html().trim().takeIf { it.isNotEmpty() } ?: return null
        val image = body.select("img[src]").firstNotNullOfOrNull {
            it.attr("src").trim().takeIf { value -> value.isNotEmpty() }
        }
        return Body(html, image, body.text())
    }

    private fun normalizeMarkup(root: Element, baseUrl: String) {
        val pending = ArrayDeque<Pair<Element, String>>()
        pending.addLast(root to baseUrl)
        while (pending.isNotEmpty()) {
            val (element, inheritedBase) = pending.removeLast()
            val base = applyXmlBase(element, inheritedBase)
            if (element.tag().namespace() == xhtmlNamespace) {
                element.tagName(element.tagName().substringAfter(':'), Parser.NamespaceHtml)
            }
            for (attribute in listOf("href", "src", "poster")) {
                val value = element.attr(attribute).trim()
                if (value.isNotEmpty()) {
                    element.attr(attribute, requireNotNull(resolveUrl(base, value)) {
                        "Invalid RSS/Atom content URL"
                    })
                }
            }
            element.removeAttr("xml:base")
            element.children().asReversed().forEach { pending.addLast(it to base) }
        }
    }

    private fun mediaImage(item: Element, baseUrl: String): String? {
        val media = item.getAllElements().filter { it.tag().namespace() == mediaNamespace }
        return media.filter { it.hasName("thumbnail") }.firstNotNullOfOrNull {
            resolveUrl(it, it.attr("url"), baseUrl)
        } ?: media.filter { it.hasName("content") && (it.isImage() || it.attr("medium") == "image") }
            .firstNotNullOfOrNull { resolveUrl(it, it.attr("url"), baseUrl) }
    }

    private fun nextLink(parent: Element, namespace: String, baseUrl: String): String? {
        return parent.childrenNamed("link", namespace).filter { it.attr("rel").trim() == "next" }
            .firstNotNullOfOrNull { resolveUrl(it, it.attr("href"), baseUrl) }
    }

    private fun resolveUrl(element: Element, value: String, baseUrl: String): String? {
        return resolveUrl(effectiveBase(element, baseUrl), value)
    }

    private fun resolveUrl(baseUrl: String, value: String): String? {
        val url = value.trim().takeIf { it.isNotEmpty() } ?: return null
        // Use Ksoup's public DOM URL resolver, not the RSS service's path-concatenating helper.
        val anchor = Element("a")
        anchor.setBaseUri(baseUrl)
        return anchor.attr("href", url).absUrl("href").takeIf { it.isNotEmpty() }
    }

    private fun effectiveBase(element: Element, baseUrl: String): String {
        return generateSequence(element) { it.parent() }.toList().asReversed()
            .fold(baseUrl) { base, ancestor -> applyXmlBase(ancestor, base) }
    }

    private fun applyXmlBase(element: Element, inheritedBase: String): String {
        val declaredBase = element.attr("xml:base").trim()
        if (declaredBase.isEmpty()) return inheritedBase
        return requireNotNull(resolveUrl(inheritedBase, declaredBase)) { "Invalid RSS/Atom xml:base" }
    }

    private fun Element.hasName(name: String): Boolean = tagName().substringAfter(':') == name

    private fun Element.hasNoNamespace(): Boolean {
        return tag().namespace().let { it.isEmpty() || it == Parser.NamespaceXml }
    }

    private fun Element.childrenNamed(name: String, namespace: String = tag().namespace()): List<Element> {
        return children().filter { it.hasName(name) && it.tag().namespace() == namespace }
    }

    private fun Element.childNamed(name: String, namespace: String = tag().namespace()): Element? {
        return childrenNamed(name, namespace).firstOrNull()
    }

    private fun Element.childText(name: String, namespace: String = tag().namespace()): String? {
        return childNamed(name, namespace)?.wholeText()?.trim()?.takeIf { it.isNotEmpty() }
    }

    private fun Element.mediaType(): String = attr("type").substringBefore(';').trim().lowercase()

    private fun Element.isImage(): Boolean = mediaType().startsWith("image/")

    private data class Body(val html: String, val image: String?, val text: String)

    private const val atomNamespace = "http://www.w3.org/2005/Atom"
    private const val contentNamespace = "http://purl.org/rss/1.0/modules/content/"
    private const val mediaNamespace = "http://search.yahoo.com/mrss/"
    private const val dcNamespace = "http://purl.org/dc/elements/1.1/"
    private const val dcTermsNamespace = "http://purl.org/dc/terms/"
    private const val xhtmlNamespace = "http://www.w3.org/1999/xhtml"
}
