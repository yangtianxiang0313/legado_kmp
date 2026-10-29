package io.legado.kmp.shared.network

import com.fleeksoft.ksoup.Ksoup
import com.fleeksoft.ksoup.nodes.DocumentType
import com.fleeksoft.ksoup.nodes.Element
import com.fleeksoft.ksoup.parser.Parser
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.datetime.Instant
import kotlinx.datetime.LocalDateTime
import kotlinx.datetime.TimeZone
import kotlinx.datetime.toInstant

/** Same XML/namespace strategy as WebDavBackupXml; href, not displayname, defines identity. */
internal suspend fun parseScopedWebDavListing(
    xml: String,
    scope: ScopedWebDavScope,
    directoryUrl: String,
): List<WebDavFile> {
    if (xml.contains("<!DOCTYPE", true) || xml.contains("<!ENTITY", true)) invalidScopedWebDavResponse()
    val parser = Parser.xmlParser().setTrackErrors(1)
    val document = Ksoup.parse(html = xml.removePrefix("\uFEFF"), parser = parser)
    if (parser.getErrors().isNotEmpty() || document.childrenSize() != 1 ||
        document.childNodes().any { it is DocumentType } ||
        document.textNodes().any { it.getWholeText().isNotBlank() }) invalidScopedWebDavResponse()
    val root = document.child(0)
    if (!root.isScopedDav("multistatus")) invalidScopedWebDavResponse()
    val responses = root.scopedDavChildren("response")
    if (responses.size > 10_001) scopedWebDavFail(ScopedWebDavProblem.LIMIT)
    val parent = scope.requireUrl(directoryUrl)
    val seen = mutableSetOf<List<String>>()
    val files = mutableListOf<WebDavFile>()
    var foundCollection = false
    for (response in responses) {
        currentCoroutineContext().ensureActive()
        val href = response.scopedDavSingle("href")?.wholeText()?.trim()?.takeIf { it.isNotEmpty() }
            ?: invalidScopedWebDavResponse()
        val target = scope.resolveHref(href, directoryUrl)
        val self = target.segments == parent.segments
        if ((!self && (target.segments.size != parent.segments.size + 1 ||
                target.segments.dropLast(1) != parent.segments)) || !seen.add(target.segments)) {
            invalidScopedWebDavResponse()
        }
        response.scopedDavSingle("status")?.wholeText()?.let {
            val status = scopedDavStatus(it)
            if (status !in 200..299) scopedWebDavHttpFailure(status)
        }
        val properties = response.scopedDavChildren("propstat").flatMap { propstat ->
            val status = scopedDavStatus(propstat.scopedDavSingle("status")?.wholeText() ?: invalidScopedWebDavResponse())
            when (status) {
                in 200..299 -> propstat.scopedDavSingle("prop")?.children()?.toList() ?: invalidScopedWebDavResponse()
                404 -> emptyList()
                else -> scopedWebDavHttpFailure(status)
            }
        }
        fun property(local: String): Element? {
            val matches = properties.filter { it.isScopedDav(local) }
            if (matches.size > 1) invalidScopedWebDavResponse()
            return matches.singleOrNull()
        }
        val resourceType = property("resourcetype") ?: invalidScopedWebDavResponse()
        val collection = resourceType.scopedDavChildren("collection").isNotEmpty()
        if (self) {
            if (!collection) invalidScopedWebDavResponse()
            foundCollection = true
            continue
        }
        if (!collection && target.isDirectory) invalidScopedWebDavResponse()
        val length = property("getcontentlength")?.wholeText()?.trim()?.let {
            if (it.isEmpty() && collection) 0L
            else it.toLongOrNull()?.takeIf { value -> value >= 0 } ?: invalidScopedWebDavResponse()
        } ?: 0L
        files.add(WebDavFile(
            path = if (collection) scope.directory(target.url) else target.url,
            displayName = target.segments.last(),
            size = length,
            contentType = if (collection) "httpd/unix-directory" else "application/octet-stream",
            resourceType = if (collection) "collection" else "",
            lastModify = property("getlastmodified")?.wholeText()?.trim()?.let(::scopedDavHttpDate) ?: 0L,
        ))
    }
    if (!foundCollection) invalidScopedWebDavResponse()
    return files
}

private fun Element.isScopedDav(local: String): Boolean {
    val tag = tagName()
    if (tag.substringAfter(':') != local) return false
    val attribute = if (':' in tag) "xmlns:${tag.substringBefore(':')}" else "xmlns"
    var element: Element? = this
    while (element != null) {
        if (element.hasAttr(attribute)) return element.attr(attribute) == "DAV:"
        element = element.parent()
    }
    return false
}

private fun Element.scopedDavChildren(local: String): List<Element> = children().filter { it.isScopedDav(local) }

private fun Element.scopedDavSingle(local: String): Element? {
    val matches = scopedDavChildren(local)
    if (matches.size > 1) invalidScopedWebDavResponse()
    return matches.singleOrNull()
}

private fun scopedDavStatus(value: String): Int {
    val parts = value.trim().split(Regex("\\s+"), limit = 3)
    if (parts.size < 2 || !parts[0].startsWith("HTTP/") || parts[1].length != 3 ||
        parts[1].any { it !in '0'..'9' }) invalidScopedWebDavResponse()
    return parts[1].toIntOrNull()?.takeIf { it in 100..599 } ?: invalidScopedWebDavResponse()
}

private fun scopedDavHttpDate(value: String): Long {
    if (value.isBlank()) return 0L
    return try {
        if ('T' in value && value.endsWith('Z')) return Instant.parse(value).toEpochMilliseconds().coerceAtLeast(0L)
        val parts = value.split(Regex("\\s+"))
        if (parts.size != 6 || !parts[5].equals("GMT", true)) invalidScopedWebDavResponse()
        val months = listOf("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")
        val month = months.indexOfFirst { it.equals(parts[2], true) } + 1
        val time = parts[4].split(':')
        if (time.size != 3) invalidScopedWebDavResponse()
        LocalDateTime(parts[3].toInt(), month, parts[1].toInt(), time[0].toInt(), time[1].toInt(), time[2].toInt())
            .toInstant(TimeZone.UTC).toEpochMilliseconds().coerceAtLeast(0L)
    } catch (_: Exception) {
        invalidScopedWebDavResponse()
    }
}

private fun invalidScopedWebDavResponse(): Nothing = scopedWebDavFail(ScopedWebDavProblem.RESPONSE)
