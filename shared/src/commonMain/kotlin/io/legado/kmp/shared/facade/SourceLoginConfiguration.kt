package io.legado.kmp.shared.facade

import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

data class SourceLoginConfiguration(
    val name: String,
    val webUrl: String?,
    val rows: List<SourceLoginRow>,
    val valuesJson: String,
    val headersJson: String,
    val hasForm: Boolean = rows.isNotEmpty(),
)

@Serializable
data class SourceLoginRow(
    val name: String = "",
    val type: String = "text",
    val action: String? = null,
    val style: SourceLoginRowStyle? = null,
)

@Serializable
data class SourceLoginRowStyle(
    val layout_flexGrow: Float = 0f,
    val layout_flexShrink: Float = 1f,
    val layout_alignSelf: String = "auto",
    val layout_flexBasisPercent: Float = -1f,
    val layout_wrapBefore: Boolean = false,
)

internal object SourceLoginFormCodec {
    private val json = Json { ignoreUnknownKeys = true }

    fun rows(loginUi: String?): List<SourceLoginRow> {
        if (loginUi.isNullOrBlank()) return emptyList()
        return json.decodeFromString(ListSerializer(SourceLoginRow.serializer()), loginUi)
            .filter { it.type in listOf("text", "password", "button") }
    }

    fun values(rows: List<SourceLoginRow>, raw: String): Map<String, String> {
        val root = json.parseToJsonElement(raw) as? JsonObject
            ?: throw IllegalArgumentException("Invalid login form")
        return rows.filter { it.type == "text" || it.type == "password" }.associate { row ->
            val value = root[row.name]
            require(value == null || value is JsonPrimitive && value.isString) { "Invalid login field" }
            row.name to ((value as? JsonPrimitive)?.content ?: "")
        }
    }

    fun encode(values: Map<String, String>): String =
        JsonObject(values.mapValues { JsonPrimitive(it.value) }).toString()
}
