package io.legado.kmp.shared.facade

import com.fleeksoft.ksoup.Ksoup
import com.fleeksoft.ksoup.nodes.DocumentType
import com.fleeksoft.ksoup.nodes.Element
import com.fleeksoft.ksoup.parser.Parser
import kotlinx.datetime.Instant
import kotlinx.datetime.LocalDateTime
import kotlinx.datetime.TimeZone
import kotlinx.datetime.toInstant

internal data class WebDavBackupResource(
    val name: String?,
    val isCollection: Boolean,
    val size: Long,
    val lastModified: Long,
)

/** Parses DAV properties, never displayname, into same-origin, direct-child resource identities. */
internal fun parseWebDavBackups(xml: String, config: CloudBackupConfiguration): List<WebDavBackupResource> {
    val parser = Parser.xmlParser().setTrackErrors(1)
    val document = Ksoup.parse(html = xml.removePrefix("\uFEFF"), parser = parser)
    if (parser.getErrors().isNotEmpty() || document.childrenSize() != 1 ||
        document.childNodes().any { it is DocumentType } ||
        document.textNodes().any { it.getWholeText().isNotBlank() }) invalidDavResponse()
    val root = document.child(0)
    if (!root.isDav("multistatus")) invalidDavResponse()
    val responses = root.davChildren("response")
    if (responses.size > 10_000) cloudBackupError("CLOUD_BACKUP_LIMIT", "WebDAV 目录文件数量超过 10000 个")
    val names = mutableSetOf<String?>()
    return responses.map { response ->
        val href = response.davSingle("href")?.wholeText()?.trim()?.takeIf { it.isNotEmpty() }
            ?: invalidDavResponse()
        val name = backupResourceName(href, config)
        if (!names.add(name)) invalidDavResponse()
        response.davSingle("status")?.wholeText()?.let { requireDavStatus(it) }
        val successfulProps = response.davChildren("propstat").flatMap { propstat ->
            val status = propstat.davSingle("status")?.wholeText() ?: invalidDavResponse()
            val code = davStatus(status)
            when {
                code == 401 || code == 403 -> davHttpFailure(code)
                code in 200..299 -> propstat.davSingle("prop")?.children()?.toList() ?: invalidDavResponse()
                code == 404 -> emptyList()
                else -> davHttpFailure(code)
            }
        }
        fun prop(local: String): Element? {
            val matching = successfulProps.filter { it.isDav(local) }
            if (matching.size > 1) invalidDavResponse()
            return matching.singleOrNull()
        }
        val resourceType = prop("resourcetype") ?: invalidDavResponse()
        val length = prop("getcontentlength")?.wholeText()?.trim()?.let {
            it.toLongOrNull()?.takeIf { value -> value >= 0 } ?: invalidDavResponse()
        } ?: 0
        WebDavBackupResource(
            name = name,
            isCollection = resourceType.davChildren("collection").isNotEmpty(),
            size = length,
            lastModified = prop("getlastmodified")?.wholeText()?.let(::backupHttpDate) ?: 0,
        )
    }
}

private fun backupResourceName(href: String, config: CloudBackupConfiguration): String? {
    if (href.startsWith("//") || href.any { it.isISOControl() || it in "\\?#" }) invalidDavResponse()
    val absolute = when {
        href.startsWith("http://", true) || href.startsWith("https://", true) -> href
        href.startsWith('/') -> config.origin + href
        else -> config.root + href
    }
    val parsed = cloudBackupUrl(absolute)
    if (cloudBackupOrigin(parsed) != config.origin) invalidDavResponse()
    val path = cloudBackupPath(parsed.encodedPath)
    if (path == config.pathSegments) return null
    if (path.size != config.pathSegments.size + 1 || path.dropLast(1) != config.pathSegments) {
        invalidDavResponse()
    }
    return path.last()
}

private fun Element.isDav(local: String): Boolean {
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

private fun Element.davChildren(local: String): List<Element> = children().filter { it.isDav(local) }

private fun Element.davSingle(local: String): Element? {
    val matches = davChildren(local)
    if (matches.size > 1) invalidDavResponse()
    return matches.singleOrNull()
}

private fun davStatus(value: String): Int {
    val parts = value.trim().split(Regex("\\s+"), limit = 3)
    if (parts.size < 2 || !parts[0].startsWith("HTTP/")) invalidDavResponse()
    return parts[1].toIntOrNull()?.takeIf { it in 100..599 } ?: invalidDavResponse()
}

private fun requireDavStatus(value: String) {
    val code = davStatus(value)
    if (code !in 200..299) davHttpFailure(code)
}

internal fun backupHttpDate(value: String): Long {
    if (value.isBlank()) return 0
    return try {
        // DAV getlastmodified is RFC 1123 GMT; ISO timestamps are accepted for interoperable servers.
        if ('T' in value && value.endsWith('Z')) return Instant.parse(value).toEpochMilliseconds()
        val parts = value.trim().split(Regex("\\s+"))
        require(parts.size == 6 && parts[5].equals("GMT", true))
        val months = listOf("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")
        val month = months.indexOfFirst { it.equals(parts[2], true) } + 1
        val time = parts[4].split(':')
        require(time.size == 3)
        LocalDateTime(parts[3].toInt(), month, parts[1].toInt(), time[0].toInt(), time[1].toInt(), time[2].toInt())
            .toInstant(TimeZone.UTC).toEpochMilliseconds().coerceAtLeast(0)
    } catch (_: Exception) {
        invalidDavResponse()
    }
}

internal fun davHttpFailure(status: Int): Nothing = when (status) {
    401 -> cloudBackupError("CLOUD_BACKUP_UNAUTHORIZED", "WebDAV 认证失败，请检查账号和应用专用密码")
    403 -> cloudBackupError("CLOUD_BACKUP_FORBIDDEN", "WebDAV 没有此目录或文件的访问权限")
    404 -> cloudBackupError("CLOUD_BACKUP_NOT_FOUND", "云端备份目录或文件不存在，请刷新列表后重试")
    507 -> cloudBackupError("CLOUD_BACKUP_STORAGE_FULL", "WebDAV 云端存储空间不足")
    in 300..399 -> cloudBackupError("CLOUD_BACKUP_REDIRECT", "WebDAV 返回重定向，请填写最终服务地址后重试")
    else -> cloudBackupError("CLOUD_BACKUP_HTTP_ERROR", "WebDAV 请求失败（HTTP $status）")
}

internal fun invalidDavResponse(): Nothing =
    cloudBackupError("CLOUD_BACKUP_INVALID_RESPONSE", "WebDAV 返回的目录或文件信息无效，未访问其他路径")
