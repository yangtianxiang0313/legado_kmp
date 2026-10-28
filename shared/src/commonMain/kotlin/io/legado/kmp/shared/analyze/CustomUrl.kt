package io.legado.kmp.shared.analyze

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

/**
 * URL with JSON attribute encapsulation.
 *
 * Aligned with legado CustomUrl.kt (48 lines):
 * Parses URLs in the form `url,{options}` and provides
 * [putAttribute]/[getUrl]/[getAttr]/[toString] methods.
 *
 * KMP note: In KMP, AnalyzeUrl.splitRuleAndOption already handles
 * this inline for URL building. This class is provided for cases
 * where JS code or external callers need the CustomUrl API directly.
 */
class CustomUrl(url: String) {

    private val mUrl: String
    private val attribute = linkedMapOf<String, Any>()

    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
    }

    init {
        // Pattern: url followed by comma and JSON object
        val paramPattern = Regex("\\s*,\\s*(?=\\{)")
        val match = paramPattern.find(url)
        mUrl = if (match != null) {
            val attr = url.substring(match.range.last + 1)
            runCatching {
                val parsed = json.parseToJsonElement(attr)
                if (parsed is JsonObject) {
                    parsed.forEach { (key, value) ->
                        val strValue = when (value) {
                            is JsonPrimitive -> value.contentOrNull ?: value.toString()
                            else -> value.toString()
                        }
                        attribute[key] = strValue
                    }
                }
            }
            url.substring(0, match.range.first)
        } else {
            url
        }
    }

    fun putAttribute(key: String, value: Any?): CustomUrl {
        if (value == null) {
            attribute.remove(key)
        } else {
            attribute[key] = value
        }
        return this
    }

    fun getUrl(): String = mUrl

    fun getAttr(): Map<String, Any> = attribute

    override fun toString(): String {
        if (attribute.isEmpty()) {
            return mUrl
        }
        val attrJson = buildString {
            append("{")
            attribute.entries.forEachIndexed { index, (key, value) ->
                if (index > 0) append(",")
                append("\"$key\":")
                when (value) {
                    is String -> append("\"${value.replace("\"", "\\\"")}\"")
                    is Number, is Boolean -> append(value)
                    else -> append("\"${value.toString().replace("\"", "\\\"")}\"")
                }
            }
            append("}")
        }
        return "$mUrl,$attrJson"
    }
}
