package io.legado.kmp.shared.scripting

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi

/** Adapt bytes before the DOM result codec, which does not preserve native typed-array slots. */
internal fun buildImageDecodeScript(script: String): String = """
    (function(__imageRuleScript, __imageEncodeBytes, __imageParseJson) {
      var decodedBytes = eval(__imageRuleScript);
      if (typeof decodedBytes === 'string') decodedBytes = __imageParseJson(decodedBytes);
      return { imageBytesBase64: __imageEncodeBytes(decodedBytes) };
    })(${JsonPrimitive(normalizeLegacyJavascriptSyntax(script.trim()))},
       java.util.Base64.getEncoder().encodeToString, JSON.parse);
""".trimIndent()

@OptIn(ExperimentalEncodingApi::class)
internal fun JsResult.toImageDecodedBytesOrNull(): ByteArray? = when (this) {
    is JsResult.JsObject -> (value["imageBytesBase64"] as? String)?.let {
        runCatching { Base64.decode(it) }.getOrNull()
    }
    is JsResult.JsArray -> value.toImageBytesOrNull()
    is JsResult.JsString -> parseImageByteArrayLiteral(value)
    else -> null
}

private fun List<Any?>.toImageBytesOrNull(): ByteArray? {
    val bytes = ByteArray(size)
    for (index in indices) {
        val number = (this[index] as? Number)?.toDouble() ?: return null
        if (!number.isFinite() || number < -128 || number > 255 || number % 1.0 != 0.0) return null
        bytes[index] = number.toInt().toByte()
    }
    return bytes
}

private fun parseImageByteArrayLiteral(raw: String): ByteArray? {
    val array = runCatching { Json.parseToJsonElement(raw) }.getOrNull() as? JsonArray ?: return null
    val numbers = ArrayList<Double>(array.size)
    for (element in array) {
        val primitive = element as? JsonPrimitive ?: return null
        if (primitive.isString) return null
        numbers.add(primitive.doubleOrNull ?: return null)
    }
    return numbers.toImageBytesOrNull()
}
