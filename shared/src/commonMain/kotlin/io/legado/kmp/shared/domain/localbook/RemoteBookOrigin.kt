package io.legado.kmp.shared.domain.localbook

import io.ktor.http.Url
import io.ktor.http.decodeURLPart
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookType
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** Android-compatible provenance. A missing ID is legacy, never the currently selected server. */
internal data class RemoteBookOrigin(val url: String, val serverID: Long?) {
    val encoded: String
        get() = BookType.WEBDAV_TAG + url + (serverID?.let { ",{\"serverID\":$it}" } ?: "")

    companion object {
        private const val MAX_LENGTH = 16 * 1024

        fun create(url: String, serverID: Long): RemoteBookOrigin {
            require(serverID >= 0) { "远程书籍服务器标识无效" }
            require(url.length <= MAX_LENGTH - 64) { "远程书籍来源过长" }
            return RemoteBookOrigin(remoteBookHttpUrl(url).toString(), serverID)
        }

        fun parse(origin: String): RemoteBookOrigin? {
            if (!origin.startsWith(BookType.WEBDAV_TAG, ignoreCase = true)) return null
            require(origin.length <= MAX_LENGTH) { "远程书籍来源过长" }
            val body = origin.substring(BookType.WEBDAV_TAG.length)
            // Split attributes before parsing the URL, including when the URL has a query.
            val attributeStart = Regex(",\\s*\\{").find(body)?.range?.first
            val url = if (attributeStart == null) body else body.substring(0, attributeStart)
            val id = attributeStart?.let {
                val attributes = body.substring(it + 1).trim()
                require(attributes.length <= 128) { "远程书籍来源属性无效" }
                require(attributes.matches(Regex("\\{\\s*\"serverID\"\\s*:\\s*(0|[1-9][0-9]{0,18})\\s*\\}"))) {
                    "远程书籍来源属性无效"
                }
                val objectValue = Json.parseToJsonElement(attributes) as? JsonObject
                    ?: error("远程书籍来源属性无效")
                require(objectValue.keys == setOf("serverID")) { "远程书籍来源属性无效" }
                val value = objectValue["serverID"] as? JsonPrimitive
                    ?: error("远程书籍服务器标识无效")
                require(!value.isString && value.content.matches(Regex("0|[1-9][0-9]{0,18}"))) {
                    "远程书籍服务器标识无效"
                }
                value.content.toLongOrNull() ?: error("远程书籍服务器标识无效")
            }
            return RemoteBookOrigin(remoteBookHttpUrl(url).toString(), id)
        }

        fun parseOrNull(origin: String): RemoteBookOrigin? = try {
            parse(origin)
        } catch (_: Exception) {
            null
        }
    }
}

/** Reject credentials, fragments and ambiguous encodings rather than normalizing them into a request. */
internal fun remoteBookHttpUrl(value: String): Url {
    require(value.startsWith("https://", true) || value.startsWith("http://", true)) {
        "远程书籍仅支持 HTTP(S) 地址"
    }
    require(value.none { it.isWhitespace() || it.code < 32 || it.code == 127 || it in "\\\"{}<>#" }) {
        "远程书籍地址无效"
    }
    value.indices.filter { value[it] == '%' }.forEach { index ->
        require(index + 2 < value.length && value.substring(index + 1, index + 3).all { it in '0'..'9' || it.lowercaseChar() in 'a'..'f' }) {
            "远程书籍地址编码无效"
        }
    }
    val url = Url(value)
    require(url.host.isNotBlank() && url.port in 1..65535 && url.user == null && url.password == null && url.fragment.isEmpty()) {
        "远程书籍地址无效"
    }
    return url
}

/** Segment comparison prevents sibling-prefix, encoded traversal and encoded-separator escapes. */
internal fun requireRemoteBookWithinRoot(value: String, root: String): String {
    val target = remoteBookHttpUrl(value)
    val base = remoteBookHttpUrl(root)
    require(base.encodedQuery.isEmpty()) { "远程书籍服务器根目录无效" }
    require(target.protocol == base.protocol && target.host.equals(base.host, true) && target.port == base.port) {
        "远程书籍不属于原服务器，请检查来源配置"
    }
    fun segments(url: Url): List<String> = url.encodedPath.split('/').drop(1).let { path ->
        if (path.lastOrNull().isNullOrEmpty()) path.dropLast(1) else path
    }.map { encoded ->
        val decoded = encoded.decodeURLPart()
        require(decoded.isNotEmpty() && decoded != "." && decoded != ".." && decoded.none {
            it == '/' || it == '\\' || it == '%' || it == ';' || it.code < 32 || it.code == 127
        }) { "远程书籍目录无效" }
        decoded
    }
    val baseSegments = segments(base)
    val targetSegments = segments(target)
    require(targetSegments.size >= baseSegments.size && targetSegments.take(baseSegments.size) == baseSegments) {
        "远程书籍不属于原服务器根目录，请检查来源配置"
    }
    return target.toString()
}

internal const val REMOTE_BOOK_ORIGINS_KEY = "io.legado.remoteBook.remoteOrigins"
private const val MAX_REMOTE_BOOK_ORIGINS = 64
private const val MAX_REMOTE_BOOK_VARIABLE = 2 * 1024 * 1024

/** RuleData's Map<String, String> may have round-tripped an older native JSON array. */
private fun remoteBookOriginArray(value: kotlinx.serialization.json.JsonElement?): JsonArray {
    if (value == null) return JsonArray(emptyList())
    val array = when (value) {
        is JsonArray -> value
        is JsonPrimitive -> {
            require(value.isString && value.content.length <= MAX_REMOTE_BOOK_VARIABLE) { "书籍远程来源记录无效" }
            Json.parseToJsonElement(value.content) as? JsonArray ?: error("书籍远程来源记录无效")
        }
        else -> error("书籍远程来源记录无效")
    }
    require(array.size <= MAX_REMOTE_BOOK_ORIGINS) { "书籍远程来源数量超过限制" }
    return array
}

/** Only this namespaced array is changed; unknown variable keys retain their JSON values. */
internal fun mergeRemoteBookOrigin(variable: String?, remote: RemoteBookOrigin): String {
    require(variable == null || variable.length <= MAX_REMOTE_BOOK_VARIABLE) { "书籍来源记录过大" }
    val variables = if (variable.isNullOrBlank()) JsonObject(emptyMap()) else
        Json.parseToJsonElement(variable) as? JsonObject ?: error("书籍变量不是有效的 JSON 对象，未修改来源")
    val items = remoteBookOriginArray(variables[REMOTE_BOOK_ORIGINS_KEY])
    val origins = items.map { item ->
        val text = (item as? JsonPrimitive)?.takeIf { it.isString }?.content
            ?: error("书籍远程来源记录无效，未修改来源")
        requireNotNull(RemoteBookOrigin.parse(text)) { "书籍远程来源记录无效，未修改来源" }.encoded
    }.distinct().toMutableList()
    if (remote.encoded !in origins) {
        require(origins.size < MAX_REMOTE_BOOK_ORIGINS) { "书籍远程来源数量已达上限，未修改来源" }
        origins += remote.encoded
    }
    val array = JsonArray(origins.map { JsonPrimitive(it) })
    val merged = JsonObject(variables + (REMOTE_BOOK_ORIGINS_KEY to JsonPrimitive(array.toString()))).toString()
    require(merged.length <= MAX_REMOTE_BOOK_VARIABLE) { "书籍来源记录过大" }
    return merged
}

/** Associations are provenance, not a recovery URL for an archive entry. */
internal val Book.remoteBookOrigins: List<RemoteBookOrigin>
    get() {
        val primary = RemoteBookOrigin.parseOrNull(origin)
        val associated = try {
            val value = variable?.takeIf { it.length <= MAX_REMOTE_BOOK_VARIABLE }
                ?.let { Json.parseToJsonElement(it) as? JsonObject }?.get(REMOTE_BOOK_ORIGINS_KEY)
            remoteBookOriginArray(value).mapNotNull {
                (it as? JsonPrimitive)?.takeIf { it.isString }?.content?.let(RemoteBookOrigin::parseOrNull)
            }
        } catch (_: Exception) {
            emptyList()
        }
        return (listOfNotNull(primary) + associated).distinct()
    }
