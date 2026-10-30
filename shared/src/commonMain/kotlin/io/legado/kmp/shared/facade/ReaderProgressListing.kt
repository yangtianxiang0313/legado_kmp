package io.legado.kmp.shared.facade

import com.fleeksoft.ksoup.Ksoup
import com.fleeksoft.ksoup.nodes.DocumentType
import com.fleeksoft.ksoup.nodes.Element
import com.fleeksoft.ksoup.parser.Parser
import io.ktor.http.Url
import io.ktor.http.encodeURLParameter
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.datetime.Instant
import kotlinx.datetime.LocalDateTime
import kotlinx.datetime.TimeZone
import kotlinx.datetime.toInstant
import okio.Buffer

internal class ReaderProgressAddress(
    val url: String,
    val origin: String,
    val segments: List<String>,
    val isDirectory: Boolean,
) {
    override fun toString(): String = "ReaderProgressAddress(redacted)"
}

/** Validate raw syntax before Ktor can remove dot segments or interpret credentials/delimiters. */
internal fun readerProgressAddress(raw: String): ReaderProgressAddress {
    if (raw.isBlank() || raw.length > 16 * 1024 || raw.any { it.isISOControl() || it in "\\?#" }) invalidProgressAddress()
    val separator = raw.indexOf("://")
    if (separator < 0) invalidProgressAddress()
    val protocol = raw.substring(0, separator).lowercase()
    if (protocol != "http" && protocol != "https") invalidProgressAddress()
    val remainder = raw.substring(separator + 3)
    val authority = remainder.substringBefore('/')
    if (authority.isBlank() || authority.any { it.isWhitespace() || it in "@%" }) invalidProgressAddress()
    val portText = if (authority.startsWith('[')) {
        val end = authority.indexOf(']')
        if (end < 2 || ':' !in authority.substring(1, end) ||
            authority.substring(1, end).any { it !in "0123456789abcdefABCDEF:." }) invalidProgressAddress()
        val suffix = authority.substring(end + 1)
        if (suffix.isNotEmpty() && !suffix.startsWith(':')) invalidProgressAddress()
        suffix.removePrefix(":").also { if (suffix == ":") invalidProgressAddress() }
    } else {
        if (authority.count { it == ':' } > 1 || authority.any { it in "[]" }) invalidProgressAddress()
        val host = authority.substringBefore(':')
        if (host.isEmpty() || host.any { !(it in 'a'..'z' || it in 'A'..'Z' || it in '0'..'9' || it in ".-") }) {
            invalidProgressAddress()
        }
        if (':' in authority) authority.substringAfter(':').also { if (it.isEmpty()) invalidProgressAddress() } else ""
    }
    if (portText.isNotEmpty() && (portText.any { it !in '0'..'9' } ||
            portText.toIntOrNull()?.let { it !in 1..65535 } != false)) invalidProgressAddress()
    val rawPath = remainder.indexOf('/').let { if (it < 0) "/" else remainder.substring(it) }
    val segments = progressPath(rawPath)
    val parsed = try { Url("$protocol://$remainder") } catch (_: Exception) { invalidProgressAddress() }
    if (parsed.protocol.name != protocol || parsed.host.isBlank() || parsed.port !in 1..65535 ||
        parsed.user != null || parsed.password != null || parsed.parameters.names().isNotEmpty() || parsed.fragment.isNotEmpty() ||
        progressPath(parsed.encodedPath.ifEmpty { "/" }) != segments
    ) invalidProgressAddress()
    val host = if (':' in parsed.host && !parsed.host.startsWith('[')) "[${parsed.host}]" else parsed.host
    val port = if (parsed.port == parsed.protocol.defaultPort) "" else ":${parsed.port}"
    val origin = "$protocol://${host.lowercase()}$port"
    val directory = rawPath.endsWith('/')
    return ReaderProgressAddress(readerProgressUrl(origin, segments, directory), origin, segments, directory)
}

internal fun readerProgressUrl(origin: String, segments: List<String>, directory: Boolean): String {
    if (segments.size > 64) invalidProgressAddress()
    // RFC 3986 unreserved characters only: literal %, #, +, &, and ; retain their exact identity.
    val path = segments.joinToString("/") { readerProgressSegment(it).encodeURLParameter() }
    val result = origin + "/" + path + if (directory && segments.isNotEmpty()) "/" else ""
    if (result.length > 16 * 1024) invalidProgressAddress()
    return result
}

internal fun readerProgressSegment(value: String, invalid: () -> Nothing = ::invalidProgressAddress): String {
    if (value.isEmpty() || value.trim() in setOf(".", "..") || value.any { it.isISOControl() || it in "/\\" }) invalid()
    try { value.encodeToByteArray(throwOnInvalidSequence = true) } catch (_: Exception) { invalid() }
    return value
}

private fun progressPath(path: String): List<String> {
    if (!path.startsWith('/') || "//" in path) invalidProgressAddress()
    val inner = path.removePrefix("/").removeSuffix("/")
    if (inner.isEmpty()) return emptyList()
    val parts = inner.split('/')
    if (parts.size > 64) invalidProgressAddress()
    return parts.map { encoded ->
        val bytes = Buffer()
        try {
            var cursor = 0
            while (cursor < encoded.length) {
                if (encoded[cursor] == '%') {
                    if (cursor + 2 >= encoded.length) invalidProgressAddress()
                    val high = encoded[cursor + 1].digitToIntOrNull(16) ?: invalidProgressAddress()
                    val low = encoded[cursor + 2].digitToIntOrNull(16) ?: invalidProgressAddress()
                    bytes.writeByte((high shl 4) or low)
                    cursor += 3
                } else {
                    val end = encoded.indexOf('%', cursor).takeIf { it >= 0 } ?: encoded.length
                    val chunk = try { encoded.substring(cursor, end).encodeToByteArray(throwOnInvalidSequence = true) }
                    catch (_: Exception) { invalidProgressAddress() }
                    bytes.write(chunk)
                    cursor = end
                }
            }
            val decoded = try { bytes.readByteArray().decodeToString(throwOnInvalidSequence = true) }
            catch (_: Exception) { invalidProgressAddress() }
            readerProgressSegment(decoded)
        } finally {
            bytes.clear()
        }
    }
}

internal suspend fun parseReaderProgressListing(
    xml: String,
    directoryUrl: String,
    requireCollection: Boolean = false,
): Map<String, Long> {
    currentCoroutineContext().ensureActive()
    if (xml.contains("<!DOCTYPE", true) || xml.contains("<!ENTITY", true)) invalidProgressListing()
    val parser = Parser.xmlParser().setTrackErrors(1)
    val document = try { Ksoup.parse(html = xml, parser = parser) } catch (_: Exception) { invalidProgressListing() }
    currentCoroutineContext().ensureActive()
    if (parser.getErrors().isNotEmpty() || document.childrenSize() != 1 ||
        document.childNodes().any { it is DocumentType } || document.textNodes().any { it.getWholeText().isNotBlank() }
    ) invalidProgressListing()
    val root = document.child(0)
    if (!root.isProgressDav("multistatus") || root.textNodes().any { it.getWholeText().isNotBlank() } ||
        root.children().any { !it.isProgressDav("response") && !it.isProgressDav("responsedescription") }
    ) invalidProgressListing()
    val responses = root.progressDavChildren("response")
    if (responses.size > 10_001) {
        throw RecoverableSharedException("PROGRESS_LISTING_LIMIT", "云端进度目录响应超过条目数量限制")
    }
    val parent = readerProgressAddress(directoryUrl)
    val seen = mutableSetOf<List<String>>()
    val result = linkedMapOf<String, Long>()
    var foundCollection = false
    for (response in responses) {
        currentCoroutineContext().ensureActive()
        if (response.textNodes().any { it.getWholeText().isNotBlank() }) invalidProgressListing()
        val href = response.progressDavSingle("href")?.progressScalar()?.takeIf { it.isNotEmpty() }
            ?: invalidProgressListing()
        val target = progressHref(href, parent)
        val self = target.segments == parent.segments
        if ((!self && (target.segments.size != parent.segments.size + 1 || target.segments.dropLast(1) != parent.segments)) ||
            !seen.add(target.segments)
        ) invalidProgressListing()
        response.progressDavSingle("status")?.progressScalar()?.let {
            val code = progressDavStatus(it)
            if (code != 200) readerProgressHttpFailure(code, "获取云端进度目录")
        }
        val propstats = response.progressDavChildren("propstat")
        if (propstats.isEmpty()) invalidProgressListing()
        val properties = mutableListOf<Element>()
        for (propstat in propstats) {
            val code = progressDavStatus(propstat.progressDavSingle("status")?.progressScalar() ?: invalidProgressListing())
            val prop = propstat.progressDavSingle("prop") ?: invalidProgressListing()
            when (code) {
                200 -> properties.addAll(prop.children().toList())
                404 -> Unit
                else -> readerProgressHttpFailure(code, "获取云端进度属性")
            }
        }
        fun property(local: String): Element? {
            val matches = properties.filter { it.isProgressDav(local) }
            if (matches.size > 1) invalidProgressListing()
            return matches.singleOrNull()
        }
        val type = property("resourcetype") ?: invalidProgressListing()
        if (type.textNodes().any { it.getWholeText().isNotBlank() }) invalidProgressListing()
        val collection = type.progressDavChildren("collection")
        if (collection.size > 1 || collection.any { it.childrenSize() != 0 || it.progressScalar().isNotBlank() }) {
            invalidProgressListing()
        }
        if (self) {
            if (collection.isEmpty()) invalidProgressListing()
            foundCollection = true
        } else if (collection.isEmpty() && target.isDirectory) {
            invalidProgressListing()
        }
        property("getcontentlength")?.progressScalar()?.trim()?.let {
            if (it.isNotEmpty() && (it.any { digit -> digit !in '0'..'9' } || it.toLongOrNull() == null)) {
                invalidProgressListing()
            }
        }
        val modified = property("getlastmodified")?.progressScalar()?.let(::progressHttpDate) ?: 0L
        if (!self && collection.isEmpty() && target.segments.last().endsWith(".json")) {
            result[target.segments.last()] = modified
        }
    }
    if (requireCollection && (!foundCollection || responses.size != 1)) invalidProgressListing()
    currentCoroutineContext().ensureActive()
    return result
}

private fun progressHref(href: String, parent: ReaderProgressAddress): ReaderProgressAddress {
    if (href.startsWith("//") || href.any { it.isISOControl() || it in "\\?#" }) invalidProgressListing()
    val absolute = when {
        href.startsWith("http://", true) || href.startsWith("https://", true) -> href
        href.startsWith('/') -> parent.origin + href
        ':' in href.substringBefore('/') -> invalidProgressListing()
        else -> readerProgressUrl(parent.origin, parent.segments, true) + href
    }
    val target = try { readerProgressAddress(absolute) } catch (_: Exception) { invalidProgressListing() }
    if (target.origin != parent.origin) invalidProgressListing()
    return target
}

private fun Element.isProgressDav(local: String): Boolean {
    val tag = tagName()
    if (tag.count { it == ':' } > 1 || tag.substringAfter(':') != local) return false
    val attribute = if (':' in tag) "xmlns:${tag.substringBefore(':')}" else "xmlns"
    var node: Element? = this
    while (node != null) {
        val declaration = node.attributes().firstOrNull { it.key == attribute }
        if (declaration != null) return declaration.value == "DAV:"
        node = node.parent()
    }
    return false
}

private fun Element.progressDavChildren(local: String): List<Element> = children().filter { it.isProgressDav(local) }

private fun Element.progressDavSingle(local: String): Element? {
    val matches = progressDavChildren(local)
    if (matches.size > 1) invalidProgressListing()
    return matches.singleOrNull()
}

private fun Element.progressScalar(): String {
    if (childrenSize() != 0) invalidProgressListing()
    return wholeText()
}

private fun progressDavStatus(value: String): Int {
    val status = value.trim()
    if (status.any { it.isISOControl() }) invalidProgressListing()
    val match = Regex("HTTP/(?:1\\.[01]|[23](?:\\.0)?) ([1-5][0-9]{2})(?: [^\\r\\n]*)?").matchEntire(status)
        ?: invalidProgressListing()
    return match.groupValues[1].toInt()
}

private fun progressHttpDate(value: String): Long {
    val date = value.trim()
    if (date.isEmpty()) return 0L
    return try {
        if ('T' in date && date.endsWith('Z')) return Instant.parse(date).toEpochMilliseconds().coerceAtLeast(0L)
        val match = Regex("(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun), ([0-9]{1,2}) ([A-Za-z]{3}) ([0-9]{4}) " +
            "([0-9]{2}):([0-9]{2}):([0-9]{2}) GMT", RegexOption.IGNORE_CASE).matchEntire(date)
            ?: invalidProgressListing()
        val fields = match.groupValues
        val months = listOf("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")
        val month = months.indexOfFirst { it.equals(fields[2], true) } + 1
        LocalDateTime(fields[3].toInt(), month, fields[1].toInt(), fields[4].toInt(), fields[5].toInt(), fields[6].toInt())
            .toInstant(TimeZone.UTC).toEpochMilliseconds().coerceAtLeast(0L)
    } catch (_: Exception) {
        invalidProgressListing()
    }
}

internal fun invalidProgressAddress(): Nothing = throw RecoverableSharedException("WEBDAV_URL", "WebDAV 地址或进度路径无效")

internal fun invalidProgressListing(): Nothing =
    throw RecoverableSharedException("PROGRESS_LISTING_INVALID", "云端进度目录响应无效，未访问其他路径")
