package io.legado.kmp.shared.facade

import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.model.SourceGroups
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

internal data class NormalizedBookSourcePayload(
    val parsed: List<BookSource>,
    val normalized: List<BookSource>,
    val persisted: List<BookSource>,
    val duplicateCount: Int,
)

internal val importJson = Json {
    ignoreUnknownKeys = true
    isLenient = true
}

private val intFields =
    setOf(
        "bookSourceType",
        "customOrder",
        "weight",
    )

private val longFields =
    setOf(
        "lastUpdateTime",
        "respondTime",
    )

private val booleanFields =
    setOf(
        "enabled",
        "enabledExplore",
        "enabledCookieJar",
    )

private val defaultIntFields =
    mapOf(
        "bookSourceType" to 0,
        "customOrder" to 0,
        "weight" to 0,
    )

private val defaultLongFields =
    mapOf(
        "lastUpdateTime" to 0L,
        "respondTime" to 180000L,
    )

private val defaultBooleanFields =
    mapOf(
        "enabled" to true,
        "enabledExplore" to true,
        "enabledCookieJar" to true,
    )

private val objectFields =
    setOf(
        "ruleExplore",
        "ruleSearch",
        "ruleBookInfo",
        "ruleToc",
        "ruleContent",
        "ruleReview",
    )

internal fun normalizeBookSourcePayload(payload: String): NormalizedBookSourcePayload {
    val rawPayload = payload.trim()
    require(rawPayload.isNotEmpty()) { "Source payload is empty" }

    val normalizedPayload = normalizeImportJson(rawPayload)
    val parsedSources = runCatching {
        importJson.decodeFromJsonElement(ListSerializer(BookSource.serializer()), normalizedPayload)
    }.recoverCatching {
        listOf(importJson.decodeFromJsonElement(BookSource.serializer(), normalizedPayload))
    }.getOrElse { throwable ->
        throw IllegalArgumentException("Failed to parse book source payload", throwable)
    }

    val normalizedSources = parsedSources.mapNotNull(::normalizeImportedBookSource)
    require(normalizedSources.isNotEmpty()) { "No valid book sources found in payload" }

    val deduplicatedByUrl = LinkedHashMap<String, BookSource>()
    normalizedSources.forEach { source ->
        deduplicatedByUrl[source.bookSourceUrl] = source
    }

    return NormalizedBookSourcePayload(
        parsed = parsedSources,
        normalized = normalizedSources,
        persisted = deduplicatedByUrl.values.toList(),
        duplicateCount = normalizedSources.size - deduplicatedByUrl.size,
    )
}

private fun normalizeImportJson(payload: String): JsonElement {
    val root = importJson.parseToJsonElement(payload)
    return when (root) {
        is JsonArray -> JsonArray(root.map(::normalizeImportSource))
        is JsonObject -> normalizeImportSource(root)
        else -> root
    }
}

private fun normalizeImportSource(element: JsonElement): JsonElement {
    val source = element as? JsonObject ?: return element
    return JsonObject(
        source.mapValues { (key, value) ->
            when {
                key in intFields -> coerceNumber(value, NumberKind.Int, defaultIntFields[key])
                key in longFields -> coerceNumber(value, NumberKind.Long, defaultLongFields[key])
                key in booleanFields -> coerceBoolean(value, defaultBooleanFields[key])
                key in objectFields -> coerceRuleObject(value)
                else -> value
            }
        },
    )
}

private fun coerceNumber(
    element: JsonElement,
    kind: NumberKind,
    defaultValue: Number?,
): JsonElement {
    if (element is JsonNull) {
        return defaultValue?.let(::JsonPrimitive) ?: element
    }
    val primitive = element as? JsonPrimitive ?: return element
    val content = primitive.contentOrNull?.trim().orEmpty()
    if (content.isEmpty()) {
        return defaultValue?.let(::JsonPrimitive) ?: element
    }
    return when (kind) {
        NumberKind.Int -> content.toIntOrNull()?.let(::JsonPrimitive) ?: element
        NumberKind.Long -> content.toLongOrNull()?.let(::JsonPrimitive) ?: element
    }
}

private fun coerceBoolean(element: JsonElement, defaultValue: Boolean?): JsonElement {
    if (element is JsonNull) {
        return defaultValue?.let(::JsonPrimitive) ?: element
    }
    val primitive = element as? JsonPrimitive ?: return element
    return when (primitive.contentOrNull?.trim()?.lowercase()) {
        "true" -> JsonPrimitive(true)
        "false" -> JsonPrimitive(false)
        "1" -> JsonPrimitive(true)
        "0" -> JsonPrimitive(false)
        "" -> defaultValue?.let(::JsonPrimitive) ?: element
        else -> element
    }
}

private fun coerceRuleObject(element: JsonElement): JsonElement {
    return when (element) {
        is JsonArray -> JsonNull
        is JsonPrimitive -> {
            val content = element.contentOrNull?.trim().orEmpty()
            if (content.isEmpty()) {
                JsonNull
            } else {
                runCatching { importJson.parseToJsonElement(content) as? JsonObject }
                    .getOrNull()
                    ?: JsonNull
            }
        }
        else -> element
    }
}

private enum class NumberKind {
    Int,
    Long,
}

private fun normalizeImportedBookSource(source: BookSource): BookSource? {
    if (source.bookSourceUrl.isBlank() || source.bookSourceName.isBlank()) {
        return null
    }
    return source.copy(
        bookSourceUrl = source.bookSourceUrl.trim(),
        bookSourceName = source.bookSourceName.trim(),
        bookSourceGroup = SourceGroups.normalize(source.bookSourceGroup),
    )
}
