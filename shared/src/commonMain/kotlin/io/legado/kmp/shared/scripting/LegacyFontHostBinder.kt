package io.legado.kmp.shared.scripting

import com.dokar.quickjs.QuickJs
import com.dokar.quickjs.binding.function
import io.legado.kmp.shared.network.SourceResponse
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.Json
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi
import okio.ByteString.Companion.toByteString

/** Handles and all retained fonts belong to one QuickJS execution, never another source. */
internal suspend fun QuickJs.bindLegacyFontHost(
    connect: (String, String?) -> SourceResponse,
    readFile: (String) -> ByteArray?,
) {
    val session = LegacyFontSession(connect, readFile)
    function("__legacyQueryTTF") { args ->
        val input = when (args.firstOrNull()?.toString()) {
            "bytes" -> {
                val payload = args.getOrNull(1)?.toString().orEmpty()
                fontRequire(payload.length <= LegacyFontLimits.MAX_BYTES * 5 + 2, "Font byte input limit exceeded")
                try {
                    Json.decodeFromString<ByteArray>(payload)
                } catch (_: Exception) {
                    throw LegacyFontException("Invalid font ByteArray")
                }
            }
            "string" -> args.getOrNull(1)?.toString()
            else -> null
        }
        session.query(input, args.getOrNull(2) != false, args.getOrNull(3)?.toString())
    }
    function("__legacyFontCall") { args ->
        val font = session.get(args.firstOrNull())
        val argument = args.getOrNull(2)
        val number = (argument as? Number)?.toDouble()
        fontRequire(number == null || (number.isFinite() && number >= Int.MIN_VALUE && number <= Int.MAX_VALUE),
            "Font query integer is outside supported range")
        val code = number?.toInt() ?: 0
        when (args.getOrNull(1)?.toString()) {
            "getGlyfById" -> font.getGlyfById(code)
            "getGlyfIdByUnicode" -> font.getGlyfIdByUnicode(code)
            "getGlyfByUnicode" -> font.getGlyfByUnicode(code)
            "getUnicodeByGlyf" -> font.getUnicodeByGlyf(argument?.toString())
            "isBlankUnicode" -> font.isBlankUnicode(code)
            else -> throw LegacyFontException("Unknown font query method")
        }
    }
    function("__legacyFontMap") { args ->
        legacyFontMapJson(session.get(args.firstOrNull()), args.getOrNull(1)?.toString().orEmpty(),
            args.getOrNull(2)?.toString().orEmpty(), args.getOrNull(3)?.toString())
    }
    function("__legacyReplaceFont") { args ->
        val text = args.firstOrNull()?.toString().orEmpty()
        val error = args.getOrNull(1)?.let(session::get)
        val correct = args.getOrNull(2)?.let(session::get)
        legacyReplaceFont(text, error, correct, args.getOrNull(3) == true)
    }
    function("__legacyFontRelease") { args ->
        session.release(args.firstOrNull())
        null
    }
}

private class LegacyFontSession(
    private val connect: (String, String?) -> SourceResponse,
    private val readFile: (String) -> ByteArray?,
) {
    private val fonts = LinkedHashMap<Int, LegacyQueryTTF>()
    private val cache = LinkedHashMap<String, Int>()
    private var sequence = 0
    private var retainedBytes = 0L

    @OptIn(ExperimentalEncodingApi::class)
    fun query(input: Any?, useCache: Boolean, headerJson: String?): Int? {
        if (input !is String && input !is ByteArray) return null
        val inputKey = when (input) {
            is String -> {
                fontRequire(input.length <= LegacyFontLimits.MAX_BYTES * 2, "Font text input limit exceeded")
                "text:" + (input + "\u0000" + headerJson.orEmpty()).encodeToByteArray().fontDigest()
            }
            is ByteArray -> {
                fontRequire(input.size <= LegacyFontLimits.MAX_BYTES, "Font byte input limit exceeded")
                "bytes:" + input.fontDigest()
            }
            else -> return null
        }
        if (useCache) cache[inputKey]?.let { return it }
        val bytes = when (input) {
            is ByteArray -> input
            is String -> when {
                input.trimStart().startsWith("http://", true) || input.trimStart().startsWith("https://", true) -> {
                    fontRequire(input.length <= 64 * 1024, "Font request rule is too long")
                    // Use the source's unmodified AnalyzeUrl/connect pipeline, including headers and cookies.
                    val response = connect(input, headerJson)
                    fontRequire(response.statusCode in 200..299, "Font request failed: HTTP ${response.statusCode}")
                    response.body
                }
                input.startsWith("file://") || input.startsWith("/") || input.startsWith("./") || input.startsWith("../") -> {
                    readFile(input.removePrefix("file://")) ?: throw LegacyFontException("Font file was not found")
                }
                else -> {
                    val data = if (input.startsWith("data:", true)) {
                        val comma = input.indexOf(',')
                        fontRequire(comma >= 0 && input.substring(0, comma).endsWith(";base64", true),
                            "Font data URI must contain base64")
                        input.substring(comma + 1)
                    } else input
                    val normalized = data.normalizedLegacyBase64(8)
                    fontRequire(normalized.length.toLong() * 3 / 4 <= LegacyFontLimits.MAX_BYTES + 2L,
                        "Decoded font size exceeds 32 MiB")
                    try {
                        Base64.decode(normalized)
                    } catch (_: Exception) {
                        throw LegacyFontException("Invalid font base64 data")
                    }
                }
            }
            else -> return null
        }
        fontRequire(bytes.size <= LegacyFontLimits.MAX_BYTES, "Font size exceeds 32 MiB")
        val bytesKey = "bytes:" + bytes.fontDigest()
        if (useCache) cache[bytesKey]?.let {
            remember(inputKey, it)
            return it
        }
        fontRequire(fonts.size < LegacyFontLimits.MAX_FONTS, "Font handle limit exceeded; release unused fonts with close()")
        val font = LegacyQueryTTF(bytes)
        fontRequire(font.retainedBytes <= LegacyFontLimits.MAX_SESSION_BYTES - retainedBytes,
            "Font session storage limit exceeded")
        val id = ++sequence
        fonts[id] = font
        retainedBytes += font.retainedBytes
        if (useCache) {
            remember(bytesKey, id)
            remember(inputKey, id)
        }
        return id
    }

    fun get(handle: Any?): LegacyQueryTTF {
        val id = (handle as? Number)?.toInt() ?: throw LegacyFontException("Invalid font handle")
        return fonts[id] ?: throw LegacyFontException("Invalid or released font handle")
    }

    fun release(handle: Any?) {
        val id = (handle as? Number)?.toInt() ?: return
        val removed = fonts.remove(id) ?: return
        retainedBytes -= removed.retainedBytes
        cache.entries.removeAll { it.value == id }
    }

    private fun remember(key: String, id: Int) {
        cache.remove(key)
        if (cache.size >= 64) cache.remove(cache.keys.first())
        cache[key] = id
    }
}

private fun ByteArray.fontDigest(): String = toByteString().sha256().hex()

private fun legacyFontMapJson(font: LegacyQueryTTF, name: String, operation: String, key: String?): String {
    val unicodeMap = name == "unicodeToGlyph" || name == "unicodeToGlyphId"
    fontRequire(unicodeMap || name == "glyphToUnicode", "Unknown font map")
    val code = key?.toIntOrNull()
    val value: Any? = when (operation) {
        "get" -> when (name) {
            "unicodeToGlyph" -> code?.let(font::getGlyfByUnicode)
            "unicodeToGlyphId" -> code?.let { font.unicodeToGlyphId[it] }
            else -> key?.let { font.glyphToUnicode[it] }
        }
        "contains" -> if (unicodeMap) code != null && font.unicodeToGlyphId.containsKey(code)
            else key != null && font.glyphToUnicode.containsKey(key)
        "size" -> if (unicodeMap) font.unicodeToGlyphId.size else font.glyphToUnicode.size
        "keys" -> {
            val keys = if (unicodeMap) font.unicodeToGlyphId.keys else font.glyphToUnicode.keys
            var size = 0L
            keys.forEach {
                size += it.toString().length + 4L
                fontRequire(size <= LegacyFontLimits.MAX_EXPORT_CHARS, "Font map export size limit exceeded")
            }
            keys.toList()
        }
        "snapshot" -> {
            var size = 0L
            val map = when (name) {
                "unicodeToGlyph" -> font.unicodeToGlyph
                "unicodeToGlyphId" -> font.unicodeToGlyphId
                else -> font.glyphToUnicode
            }
            map.forEach { (entryKey, entryValue) ->
                size += entryKey.toString().length + (entryValue?.toString()?.length ?: 4) + 8L
                fontRequire(size <= LegacyFontLimits.MAX_EXPORT_CHARS, "Font map export size limit exceeded")
            }
            map
        }
        else -> throw LegacyFontException("Unknown font map operation")
    }
    return value.toJsonElement().toString()
}
