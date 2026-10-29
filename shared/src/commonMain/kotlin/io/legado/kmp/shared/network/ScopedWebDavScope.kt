package io.legado.kmp.shared.network

import io.ktor.http.URLBuilder
import io.ktor.http.Url
import io.ktor.http.encodeURLPathPart
import io.ktor.http.encodedPath
import io.legado.kmp.shared.domain.localbook.remoteBookHttpUrl
import io.legado.kmp.shared.domain.localbook.requireRemoteBookWithinRoot

internal enum class ScopedWebDavProblem(val userMessage: String) {
    ADDRESS("远程书库地址或路径无效"),
    SCOPE("远程书库地址超出当前会话根目录，已拒绝访问"),
    RESPONSE("远程书库返回的目录信息无效，请刷新后重试"),
    LIMIT("远程书库目录响应超过大小或条目数量限制"),
    REDIRECT("远程书库管理请求不跟随重定向，请配置最终服务地址"),
    AUTH("远程书库认证失败，请检查账号和应用专用密码"),
    FORBIDDEN("当前账号没有此远程书库的访问权限"),
    NOT_FOUND("远程书库目录或文件不存在，请刷新后重试"),
    SPACE("远程书库存储空间不足"),
    HTTP("远程书库请求未成功，请刷新后重试"),
}

internal class ScopedWebDavFailure(val problem: ScopedWebDavProblem) : Exception(problem.userMessage) {
    override fun toString(): String = "ScopedWebDavFailure(${problem.name})"
}

internal fun scopedWebDavFail(problem: ScopedWebDavProblem): Nothing = throw ScopedWebDavFailure(problem)

internal fun scopedWebDavHttpFailure(status: Int): Nothing = scopedWebDavFail(when (status) {
    in 300..399 -> ScopedWebDavProblem.REDIRECT
    401 -> ScopedWebDavProblem.AUTH
    403 -> ScopedWebDavProblem.FORBIDDEN
    404 -> ScopedWebDavProblem.NOT_FOUND
    507 -> ScopedWebDavProblem.SPACE
    else -> ScopedWebDavProblem.HTTP
})

/** Parsed identities never retain user-info, query strings, fragments, or an unvalidated raw href. */
internal class ScopedWebDavAddress(
    val url: String,
    val origin: String,
    val segments: List<String>,
    val isDirectory: Boolean,
) {
    override fun toString(): String = "ScopedWebDavAddress(redacted)"
}

/** Strict scope for the new transfer facade only; legacy WebDavClient behavior is unchanged. */
internal class ScopedWebDavScope(root: String) {
    private val address = scopedWebDavAddress(root)
    val rootUrl: String = scopedWebDavRender(address.origin, address.segments, true)
    val origin: String = address.origin
    val rootSegments: List<String> = address.segments

    fun requireUrl(raw: String): ScopedWebDavAddress {
        val target = scopedWebDavAddress(raw)
        try {
            requireRemoteBookWithinRoot(target.url, rootUrl)
        } catch (_: Exception) {
            scopedWebDavFail(ScopedWebDavProblem.SCOPE)
        }
        return target
    }

    fun directory(raw: String): String {
        val target = requireUrl(raw)
        return scopedWebDavRender(origin, target.segments, true)
    }

    fun rootFile(name: String): String = scopedWebDavRender(origin, rootSegments + scopedWebDavSegment(name), false)

    fun childRoot(parts: List<String>): String = scopedWebDavRender(
        origin, rootSegments + parts.map(::scopedWebDavSegment), true,
    )

    fun resolveHref(href: String, directoryUrl: String): ScopedWebDavAddress {
        if (href.startsWith("//")) scopedWebDavFail(ScopedWebDavProblem.SCOPE)
        val absolute = when {
            "://" in href -> href
            href.startsWith('/') -> origin + href
            else -> directory(directoryUrl) + href
        }
        return requireUrl(absolute)
    }

    override fun toString(): String = "ScopedWebDavScope(redacted)"
}

internal fun scopedWebDavAddress(raw: String): ScopedWebDavAddress {
    if (raw.isBlank() || raw.length > 16_384 ||
        raw.any { it.isISOControl() || it in "\\?#" }) invalidScopedWebDavAddress()
    val separator = raw.indexOf("://")
    if (separator < 0) invalidScopedWebDavAddress()
    val protocol = when (raw.substring(0, separator).lowercase()) {
        "http", "dav" -> "http"
        "https", "davs" -> "https"
        else -> invalidScopedWebDavAddress()
    }
    val remainder = raw.substring(separator + 3)
    val authority = remainder.substringBefore('/')
    if (authority.isBlank() || authority.any { it.isWhitespace() || it in "@%" }) invalidScopedWebDavAddress()
    val rawPath = remainder.indexOf('/').let { if (it < 0) "/" else remainder.substring(it) }
    // Validate before Ktor (or the platform) has an opportunity to normalize dot segments.
    val segments = scopedWebDavPath(rawPath)
    val parsed = try { Url("$protocol://$remainder") } catch (_: Exception) { invalidScopedWebDavAddress() }
    if (parsed.protocol.name !in setOf("http", "https") || parsed.host.isBlank() ||
        parsed.port !in 1..65535 || !parsed.user.isNullOrEmpty() || !parsed.password.isNullOrEmpty() ||
        scopedWebDavPath(parsed.encodedPath.ifEmpty { "/" }) != segments) invalidScopedWebDavAddress()
    val host = if (':' in parsed.host && !parsed.host.startsWith('[')) "[${parsed.host}]" else parsed.host
    val port = if (parsed.port == parsed.protocol.defaultPort) "" else ":${parsed.port}"
    val origin = URLBuilder("$protocol://${host.lowercase()}$port/").buildString().removeSuffix("/")
    val directory = rawPath.endsWith('/')
    val canonical = scopedWebDavRender(origin, segments, directory)
    // Reuse the provenance agent's canonical HTTP parser; raw guards above are deliberately stricter.
    try { remoteBookHttpUrl(canonical) } catch (_: Exception) { invalidScopedWebDavAddress() }
    return ScopedWebDavAddress(canonical, origin, segments, directory)
}

private fun scopedWebDavRender(origin: String, segments: List<String>, directory: Boolean): String {
    if (segments.size > 64) invalidScopedWebDavAddress()
    val result = URLBuilder("$origin/").apply {
        encodedPath = "/" + segments.joinToString("/") { it.encodeURLPathPart() } +
            if (directory && segments.isNotEmpty()) "/" else ""
    }.buildString()
    if (result.length > 16 * 1024 - 64) invalidScopedWebDavAddress()
    return result
}

private fun scopedWebDavPath(path: String): List<String> {
    if (!path.startsWith('/') || "//" in path) invalidScopedWebDavAddress()
    val inner = path.removePrefix("/").removeSuffix("/")
    if (inner.isEmpty()) return emptyList()
    val parts = inner.split('/')
    if (parts.size > 64) invalidScopedWebDavAddress()
    return parts.map { encoded ->
        val bytes = mutableListOf<Byte>()
        var cursor = 0
        while (cursor < encoded.length) {
            if (encoded[cursor] == '%') {
                if (cursor + 2 >= encoded.length) invalidScopedWebDavAddress()
                val high = encoded[cursor + 1].digitToIntOrNull(16) ?: invalidScopedWebDavAddress()
                val low = encoded[cursor + 2].digitToIntOrNull(16) ?: invalidScopedWebDavAddress()
                bytes.add(((high shl 4) or low).toByte())
                cursor += 3
            } else {
                val end = encoded.indexOf('%', cursor).takeIf { it >= 0 } ?: encoded.length
                val chunk = try { encoded.substring(cursor, end).encodeToByteArray(throwOnInvalidSequence = true) }
                catch (_: Exception) { invalidScopedWebDavAddress() }
                bytes.addAll(chunk.toList())
                cursor = end
            }
        }
        val decoded = try { bytes.toByteArray().decodeToString(throwOnInvalidSequence = true) }
        catch (_: Exception) { invalidScopedWebDavAddress() }
        scopedWebDavSegment(decoded)
    }
}

internal fun scopedWebDavSegment(name: String): String {
    if (name.isBlank() || name.trim() in setOf(".", "..") || name.length > 1024 ||
        name.any { it.isISOControl() || it in "/\\%;" }) invalidScopedWebDavAddress()
    val bytes = try { name.encodeToByteArray(throwOnInvalidSequence = true) }
    catch (_: Exception) { invalidScopedWebDavAddress() }
    if (bytes.size > 1024) invalidScopedWebDavAddress()
    return name
}

private fun invalidScopedWebDavAddress(): Nothing = scopedWebDavFail(ScopedWebDavProblem.ADDRESS)
