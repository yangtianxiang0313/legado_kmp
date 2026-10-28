package io.legado.kmp.shared.network

import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi

data class SourceResponse(
    val url: String,
    val bodyText: String,
    val body: ByteArray,
    val statusCode: Int,
    val statusText: String,
    val headers: Map<String, String>,
    val allHeaders: Map<String, List<String>>,
    val errorBodyText: String? = null
) {
    fun toHttpResponse(): HttpResponse {
        return HttpResponse(
            statusCode = statusCode,
            statusText = statusText,
            headers = headers,
            allHeaders = allHeaders,
            body = body,
            bodyText = bodyText,
            url = url,
            errorBodyText = errorBodyText
        )
    }

    fun toJsMap(): Map<String, Any?> {
        return linkedMapOf(
            "url" to url,
            "body" to bodyText,
            "statusCode" to statusCode,
            "status" to statusCode,
            "statusText" to statusText,
            "message" to statusText,
            "headers" to headers,
            "allHeaders" to allHeaders,
            "errorBody" to errorBodyText
        )
    }

    companion object {
        fun fromHttpResponse(response: HttpResponse): SourceResponse {
            return SourceResponse(
                url = response.url,
                bodyText = response.bodyText,
                body = response.body,
                statusCode = response.statusCode,
                statusText = response.statusText,
                headers = response.headers,
                allHeaders = response.allHeaders,
                errorBodyText = response.errorBodyText
            )
        }
    }
}

data class LoginCheckResult(
    val passed: Boolean = true,
    val response: SourceResponse? = null
)

internal fun Any?.toBooleanLike(): Boolean? {
    return when (this) {
        is Boolean -> this
        is Number -> toInt() != 0
        is String -> when (trim().lowercase()) {
            "true", "1", "yes" -> true
            "false", "0", "no", "null", "undefined", "" -> false
            else -> null
        }
        else -> null
    }
}

internal fun Any?.toIntLike(): Int? {
    return when (this) {
        is Int -> this
        is Long -> toInt()
        is Double -> toInt()
        is Float -> toInt()
        is String -> trim().toIntOrNull()
        else -> null
    }
}

internal fun Any?.toStringMap(): Map<String, String>? {
    val map = this as? Map<*, *> ?: return null
    val values = linkedMapOf<String, String>()
    map.forEach { (key, value) ->
        val normalizedKey = key?.toString() ?: return@forEach
        val normalizedValue = value?.toString() ?: return@forEach
        values[normalizedKey] = normalizedValue
    }
    return values
}

internal fun Any?.toMultiValueStringMap(): Map<String, List<String>>? {
    val map = this as? Map<*, *> ?: return null
    val values = linkedMapOf<String, List<String>>()
    map.forEach { (key, value) ->
        val normalizedKey = key?.toString() ?: return@forEach
        val normalizedValue = when (value) {
            is List<*> -> value.mapNotNull { it?.toString() }
            null -> emptyList()
            else -> listOf(value.toString())
        }
        values[normalizedKey] = normalizedValue
    }
    return values
}

@OptIn(ExperimentalEncodingApi::class)
internal fun buildSourceResponse(
    base: SourceResponse,
    payload: Map<String, Any?>
): SourceResponse {
    val nested = payload["response"] as? Map<*, *>
    @Suppress("UNCHECKED_CAST")
    val responsePayload = (nested?.mapKeys { it.key.toString() } as? Map<String, Any?>) ?: payload
    val bodyText = responsePayload["body"]?.toString() ?: base.bodyText
    val bodyBytes = when (val bodyBase64 = responsePayload["bodyBase64"]) {
        is String -> runCatching { Base64.decode(bodyBase64) }.getOrDefault(bodyText.encodeToByteArray())
        else -> bodyText.encodeToByteArray()
    }
    val headers = responsePayload["headers"].toStringMap() ?: base.headers
    val allHeaders = responsePayload["allHeaders"].toMultiValueStringMap()
        ?: headers.mapValues { listOf(it.value) }
    return base.copy(
        url = responsePayload["url"]?.toString() ?: base.url,
        bodyText = bodyText,
        body = bodyBytes,
        statusCode = responsePayload["statusCode"].toIntLike()
            ?: responsePayload["status"].toIntLike()
            ?: base.statusCode,
        statusText = responsePayload["statusText"]?.toString()
            ?: responsePayload["message"]?.toString()
            ?: base.statusText,
        headers = headers,
        allHeaders = allHeaders,
        errorBodyText = responsePayload["errorBody"]?.toString() ?: base.errorBodyText
    )
}
