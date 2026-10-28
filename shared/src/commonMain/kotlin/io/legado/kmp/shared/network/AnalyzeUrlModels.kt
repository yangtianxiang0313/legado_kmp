package io.legado.kmp.shared.network

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

private const val CONTENT_TYPE = "Content-Type"
private const val FORM_CONTENT_TYPE = "application/x-www-form-urlencoded"
private const val JSON_CONTENT_TYPE = "application/json; charset=UTF-8"

enum class VariableType {
    STRING,
    INT,
    URL_ENCODED,
    URL_COMPONENT
}

data class UrlVariable(
    val name: String,
    val value: Any?,
    val type: VariableType = VariableType.STRING
)

data class BuiltUrl(
    val ruleUrl: String,
    val url: String,
    val urlNoQuery: String,
    val baseUrl: String,
    val method: HttpMethod = HttpMethod.GET,
    val headers: Map<String, String> = emptyMap(),
    val body: String? = null,
    val encodedForm: String? = null,
    val encodedQuery: String? = null,
    val rawBody: Boolean = false,
    val charset: String? = null,
    val retry: Int = 0,
    val type: String? = null,
    val useWebView: Boolean = false,
    val webJs: String? = null,
    val sourceRegex: String? = null,
    val requestJs: String? = null,
    val serverId: Long? = null,
    val proxy: String? = null,
    val webViewDelayTime: Long = 0L,
    val usedVariables: Map<String, Any?> = emptyMap()
) {
    /**
     * Check if this is a POST request.
     * Aligned with legado AnalyzeUrl.UrlOption.isPost().
     * U10: isPost method.
     */
    fun isPost(): Boolean = method == HttpMethod.POST || !body.isNullOrBlank()

    fun toHttpRequestConfig(defaultHeaders: Map<String, String> = emptyMap()): HttpRequestConfig {
        val mergedHeaders = LinkedHashMap<String, String>()
        mergedHeaders.putAllUserAgentAware(defaultHeaders)
        mergedHeaders.putAllUserAgentAware(headers)
        val requestBody = when {
            method == HttpMethod.POST && rawBody -> body.orEmpty()
            method == HttpMethod.POST && (encodedForm != null || body.isNullOrBlank()) -> encodedForm.orEmpty()
            else -> encodedForm ?: body
        }
        if (method == HttpMethod.POST) {
            when {
                rawBody -> Unit
                encodedForm != null || body.isNullOrBlank() -> {
                    mergedHeaders.setHeaderIfMissing(CONTENT_TYPE, FORM_CONTENT_TYPE)
                }
                !mergedHeaders.hasHeader(CONTENT_TYPE) -> {
                    mergedHeaders[CONTENT_TYPE] = JSON_CONTENT_TYPE
                }
            }
        }
        val requestUrl = if (!encodedQuery.isNullOrBlank()) {
            "$urlNoQuery?$encodedQuery"
        } else {
            urlNoQuery
        }
        return HttpRequestConfig(
            url = requestUrl,
            method = method,
            headers = mergedHeaders,
            body = requestBody
        )
    }
}

private fun Map<String, String>.hasHeader(name: String): Boolean {
    return keys.any { it.equals(name, ignoreCase = true) }
}

private fun MutableMap<String, String>.setHeaderIfMissing(name: String, value: String) {
    if (!hasHeader(name)) {
        this[name] = value
    }
}

/**
 * File upload request data.
 *
 * Aligned with legado AnalyzeUrl.upload() which supports multipart file uploads
 * (used in WebDAV and other upload scenarios).
 *
 * In KMP, the actual upload execution is delegated to platform-specific HTTP clients.
 * This data class represents the upload intent so that [SourceRequestExecutor] or
 * platform layers can execute the actual multipart upload.
 */
data class UploadRequest(
    val url: String,
    val fileName: String,
    val fileData: ByteArray,
    val mimeType: String = "application/octet-stream",
    val headers: Map<String, String> = emptyMap(),
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is UploadRequest) return false
        return url == other.url && fileName == other.fileName &&
            fileData.contentEquals(other.fileData) &&
            mimeType == other.mimeType && headers == other.headers
    }

    override fun hashCode(): Int {
        var result = url.hashCode()
        result = 31 * result + fileName.hashCode()
        result = 31 * result + fileData.contentHashCode()
        result = 31 * result + mimeType.hashCode()
        result = 31 * result + headers.hashCode()
        return result
    }
}

sealed interface MultipartUploadPart {
    val name: String
}

data class MultipartFormField(
    override val name: String,
    val value: String
) : MultipartUploadPart

data class MultipartFileField(
    override val name: String,
    val fileName: String,
    val fileData: ByteArray,
    val contentType: String
) : MultipartUploadPart {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is MultipartFileField) return false
        return name == other.name &&
            fileName == other.fileName &&
            fileData.contentEquals(other.fileData) &&
            contentType == other.contentType
    }

    override fun hashCode(): Int {
        var result = name.hashCode()
        result = 31 * result + fileName.hashCode()
        result = 31 * result + fileData.contentHashCode()
        result = 31 * result + contentType.hashCode()
        return result
    }
}

internal fun buildAnalyzeUrlMultipartParts(
    body: String?,
    fileName: String,
    fileData: ByteArray,
    contentType: String
): List<MultipartUploadPart> {
    val trimmed = body?.trim().orEmpty()
    require(trimmed.isNotEmpty()) { "AnalyzeUrl upload body is empty" }
    val root = runCatching { Json.parseToJsonElement(trimmed) as? JsonObject }.getOrNull()
        ?: throw IllegalArgumentException("AnalyzeUrl upload body must be a JSON object")
    return root.entries.map { (name, value) ->
        if (value.toMultipartString() == "fileRequest") {
            MultipartFileField(
                name = name,
                fileName = fileName,
                fileData = fileData,
                contentType = contentType
            )
        } else {
            MultipartFormField(name = name, value = value.toMultipartString())
        }
    }
}

private fun JsonElement.toMultipartString(): String {
    return when (this) {
        is JsonPrimitive -> contentOrNull ?: toString()
        is JsonNull -> "null"
        is JsonObject, is JsonArray -> toString()
    }
}
