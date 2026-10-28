package io.legado.kmp.shared.facade

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

internal class ForegroundWebRequestSupport(
    private val json: Json,
    parameters: String,
    val body: String,
) {
    private val query = json.parseToJsonElement(parameters.ifBlank { "{}" }) as? JsonObject
        ?: error("查询参数格式不对")

    fun parameter(vararg keys: String): String = optionalParameter(*keys)
        ?: error("缺少参数：${keys.first()}")

    fun optionalParameter(vararg keys: String): String? {
        return keys.firstNotNullOfOrNull { key ->
            val value = when (val raw = query[key]) {
                is JsonArray -> raw.firstOrNull()
                else -> raw
            }
            when (value) {
                null, JsonNull -> null
                is JsonPrimitive -> value.contentOrNull?.takeIf(String::isNotBlank)
                else -> error("参数格式不对：$key")
            }
        }
    }

    fun bodyObject(): JsonObject = bodyElement() as? JsonObject ?: error("正文必须为 JSON 对象")

    fun bodyArray(): JsonArray = bodyElement() as? JsonArray ?: error("正文必须为 JSON 数组")

    private fun bodyElement(): JsonElement {
        require(body.isNotBlank()) { "数据不能为空" }
        return json.parseToJsonElement(body)
    }
}

internal fun JsonObject.foregroundWebString(key: String): String? {
    val value = this[key] ?: return null
    if (value == JsonNull) return null
    require(value is JsonPrimitive && value.isString) { "字段必须为字符串：$key" }
    return value.content
}
