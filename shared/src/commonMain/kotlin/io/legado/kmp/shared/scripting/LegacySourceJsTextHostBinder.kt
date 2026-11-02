package io.legado.kmp.shared.scripting

import com.dokar.quickjs.QuickJs
import com.dokar.quickjs.binding.function
import io.legado.kmp.shared.platform.TextCodec
import io.legado.kmp.shared.util.ChineseConverter
import io.legado.kmp.shared.util.toNumChapter
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi

@OptIn(ExperimentalEncodingApi::class)
internal suspend fun QuickJs.bindLegacyTextHost(json: Json) {
    function("__legacyEncodeURI") { args ->
        val charset = args.getOrNull(1)?.toString()?.takeUnless { it.isBlank() || it == "undefined" || it == "null" }
        try {
            json.textArgument(args.firstOrNull()).legacyUrlEncode(charset ?: "UTF-8")
        } catch (_: Exception) {
            ""
        }
    }
    function("__legacyBase64Decode") { args ->
        val decodedText = try {
            val encoded = json.textArgument(args.firstOrNull())
            val decoded = Base64.decode(encoded.normalizedLegacyBase64(args.getOrNull(1).legacyBase64Flags()))
            val charset = args.getOrNull(1)?.toString()?.takeIf { it.toIntOrNull() == null }
            TextCodec.decode(decoded, charset?.takeUnless { it.isBlank() } ?: "UTF-8")
        } catch (_: Exception) { "" }
        json.encodeToString(decodedText)
    }
    function("__legacyBase64DecodeToByteArray") { args ->
        val encoded = json.textArgument(args.firstOrNull())
            .takeUnless { it.isBlank() || it == "undefined" || it == "null" }
            ?: return@function null
        try {
            Base64.decode(encoded.normalizedLegacyBase64(args.getOrNull(1).legacyBase64Flags()))
        } catch (_: Exception) {
            null
        }
    }
    function("__legacyBase64Encode") { args ->
        val plain = json.textArgument(args.firstOrNull())
        Base64.encode(plain.encodeToByteArray()).withLegacyBase64Flags(args.getOrNull(1).legacyBase64Flags())
    }
    function("__legacyStrToBytes") { args ->
        val text = json.textArgument(args.firstOrNull())
        val charset = args.getOrNull(1)?.toString()?.takeUnless { it.isBlank() || it == "undefined" || it == "null" }
        TextCodec.encode(text, charset ?: "UTF-8")
    }
    function("__legacyBytesToStr") { args ->
        val bytesJson = args.firstOrNull()?.toString().orEmpty()
        val charset = args.getOrNull(1)?.toString()?.takeUnless { it.isBlank() || it == "undefined" || it == "null" }
        val bytes = bytesJson.toLegacyByteArray()
        json.encodeToString(TextCodec.decode(bytes, charset ?: "UTF-8"))
    }
    function("__legacyJsoupDecodeBytes") { args ->
        require(args.size == 2 && args[0] is String) { "Expected Jsoup bytes and charset" }
        val bytes = legacyJavaCryptoBytes(args[0] as String)
        require(args[1] == null || args[1] is String) { "Expected Jsoup charset or null" }
        val charset = args[1] as? String
        val decoded = if (charset == null) bytes.decodeToString() else TextCodec.decode(bytes, charset)
        json.encodeToString(decoded)
    }
    function("__legacyT2s") { args ->
        json.encodeToString(ChineseConverter.t2s(json.textArgument(args.firstOrNull())))
    }
    function("__legacyS2t") { args ->
        json.encodeToString(ChineseConverter.s2t(json.textArgument(args.firstOrNull())))
    }
    function("__legacyToNumChapter") { args ->
        json.encodeToString(toNumChapter(json.textArgument(args.firstOrNull())))
    }
    function("__legacyHexDecodeToString") { args ->
        val decodedText = try {
            TextCodec.decode(json.textArgument(args.firstOrNull()).decodeLegacyHexBytes(), "UTF-8")
        } catch (_: Exception) { "" }
        json.encodeToString(decodedText)
    }
    function("__legacyHexDecodeToByteArray") { args ->
        try {
            json.textArgument(args.firstOrNull()).decodeLegacyHexBytes()
        } catch (_: Exception) {
            ByteArray(0)
        }
    }
    function("__legacyHexEncodeToString") { args ->
        try {
            json.textArgument(args.firstOrNull()).encodeToByteArray().joinToString("") {
                (it.toInt() and 0xff).toString(16).padStart(2, '0')
            }
        } catch (_: Exception) { "" }
    }
}

// JSON escaping retains embedded NUL across QuickJS's native C-string conversion.
private fun Json.textArgument(value: Any?): String = decodeFromString<String>(value?.toString() ?: "\"\"")
