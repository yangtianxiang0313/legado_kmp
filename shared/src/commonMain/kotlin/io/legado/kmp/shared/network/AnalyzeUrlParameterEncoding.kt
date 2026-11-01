package io.legado.kmp.shared.network

import io.ktor.http.encodeURLQueryComponent
import io.legado.kmp.shared.platform.TextCodec
import io.legado.kmp.shared.platform.encodeCharsetWriterText

internal fun encodeLegacyUrlParameters(params: String, charset: String?, isQuery: Boolean): String {
    val escapeMode = charset.equals("escape", ignoreCase = true)
    if (params.isBlank() && (escapeMode || charset.isNullOrBlank())) return params
    if (!escapeMode && !charset.isNullOrBlank()) {
        // Resolve explicit charsets even when the input does not need encoding.
        TextCodec.encode("", charset)
        if (isQuery) {
            return if (params.isLegacyEncodedQuery()) params else params.percentEncodeWithCharset(
                charsetName = charset,
                spaceToPlus = false
            )
        }
    }
    if (isQuery && !escapeMode && charset.isNullOrBlank()) {
        return splitLegacyParamSegments(params).joinToString("&") { segment ->
            if (segment.isBlank()) return@joinToString ""
            val (rawKey, rawValue) = splitLegacyParam(segment)
            val key = rawKey.percentEncodeUtf8ForLegacyQueryComponent()
            val value = rawValue?.percentEncodeUtf8ForLegacyQueryComponent()
            if (value == null) key else "$key=$value"
        }
    }
    return splitLegacyParamSegments(params).joinToString("&") { segment ->
        if (segment.isBlank() && (escapeMode || charset.isNullOrBlank())) return@joinToString ""
        val (rawKey, rawValue) = splitLegacyParam(segment)
        val key = encodeValue(rawKey, charset, isQuery)
        val value = rawValue?.let { encodeValue(it, charset, isQuery) }
        if (value == null) key else "$key=$value"
    }
}

private fun splitLegacyParamSegments(params: String): List<String> {
    if (!params.contains("&")) return listOf(params)
    val parts = mutableListOf<String>()
    var start = 0
    scanLegacyParamText(params) { index, char, depth ->
        if (char == '&' && depth == 0) {
            parts += params.substring(start, index)
            start = index + 1
        }
    }
    parts += params.substring(start)
    return parts
}

private fun splitLegacyParam(segment: String): Pair<String, String?> {
    var delimiter = -1
    scanLegacyParamText(segment) { index, char, depth ->
        if (delimiter < 0 && char == '=' && depth == 0) {
            delimiter = index
        }
    }
    return if (delimiter < 0) {
        segment to null
    } else {
        segment.substring(0, delimiter) to segment.substring(delimiter + 1)
    }
}

private inline fun scanLegacyParamText(
    text: String,
    onTopLevelChar: (index: Int, char: Char, depth: Int) -> Unit
) {
    var depth = 0
    var quote: Char? = null
    var escaped = false
    var index = 0
    while (index < text.length) {
        val encodedChar = text.percentEncodedCharAt(index)
        val char = encodedChar ?: text[index]
        val charLength = if (encodedChar == null) 1 else 3
        if (escaped) {
            escaped = false
            index += charLength
            continue
        }
        if (quote != null) {
            if (char == '\\') {
                escaped = true
            } else if (char == quote) {
                quote = null
            }
            index += charLength
            continue
        }
        when (char) {
            '\'', '"', '`' -> quote = char
            '(', '[', '{' -> depth++
            ')', ']', '}' -> if (depth > 0) depth--
            else -> if (encodedChar == null) onTopLevelChar(index, char, depth)
        }
        index += charLength
    }
}

private fun String.percentEncodedCharAt(index: Int): Char? {
    if (this[index] != '%' || index + 2 >= length) return null
    val high = this[index + 1].hexValueOrNull() ?: return null
    val low = this[index + 2].hexValueOrNull() ?: return null
    return ((high shl 4) or low).toChar()
}

private fun String.isLegacyEncodedQuery(): Boolean {
    var index = 0
    while (index < length) {
        val char = this[index]
        when {
            char.isAsciiLetterOrDigit() || char in legacyQuerySafeChars -> index++
            char == '%' && percentEncodedCharAt(index) != null -> index += 3
            else -> return false
        }
    }
    return true
}

private fun encodeValue(value: String, charset: String?, isQuery: Boolean): String {
    return when {
        charset.equals("escape", ignoreCase = true) -> value.escapeLikeLegacy()
        !charset.isNullOrBlank() -> value.percentEncodeWithCharset(
            charsetName = charset,
            spaceToPlus = !isQuery
        )
        isQuery -> value.encodeURLQueryComponent()
        else -> value.encodeURLQueryComponent(spaceToPlus = true)
    }
}

private fun String.percentEncodeUtf8ForLegacyQueryComponent(): String {
    val result = StringBuilder(length)
    var index = 0
    while (index < length) {
        val char = this[index]
        when {
            char in legacyQueryComponentSafeChars || char.isAsciiLetterOrDigit() -> {
                result.append(char)
                index++
            }
            char == '%' && index + 2 < length && this[index + 1].isHexDigit() && this[index + 2].isHexDigit() -> {
                result.append(char)
                result.append(this[index + 1])
                result.append(this[index + 2])
                index += 3
            }
            else -> {
                // Keep valid UTF-16 pairs intact; retain the encoder fallback for unpaired surrogates.
                val charLength = if (
                    char.isHighSurrogate() && index + 1 < length && this[index + 1].isLowSurrogate()
                ) 2 else 1
                substring(index, index + charLength).encodeToByteArray().forEach { byte ->
                    val value = byte.toInt() and 0xFF
                    result.append('%')
                    result.append(hexDigits[value ushr 4])
                    result.append(hexDigits[value and 0x0F])
                }
                index += charLength
            }
        }
    }
    return result.toString()
}

private fun Char.isHexDigit(): Boolean {
    return this in '0'..'9' || this in 'A'..'F' || this in 'a'..'f'
}

private fun Char.hexValueOrNull(): Int? {
    return when (this) {
        in '0'..'9' -> code - '0'.code
        in 'A'..'F' -> code - 'A'.code + 10
        in 'a'..'f' -> code - 'a'.code + 10
        else -> null
    }
}

private fun Char.isAsciiLetterOrDigit(): Boolean {
    return this in '0'..'9' || this in 'A'..'Z' || this in 'a'..'z'
}

private fun String.escapeLikeLegacy(): String {
    val result = StringBuilder(length * 2)
    forEach { ch ->
        when {
            ch.isLetterOrDigit() || ch in legacyEscapeSafeChars -> result.append(ch)
            ch.code < 256 -> {
                result.append('%')
                result.append(ch.code.toString(16).uppercase().padStart(2, '0'))
            }
            else -> {
                result.append("%u")
                result.append(ch.code.toString(16).uppercase().padStart(4, '0'))
            }
        }
    }
    return result.toString()
}

private fun String.percentEncodeWithCharset(
    charsetName: String,
    spaceToPlus: Boolean
): String {
    val safeChars = if (spaceToPlus) legacyFormSafeChars else legacyQueryEncoderSafeChars
    val queryBomLength = if (spaceToPlus) 0 else legacyQueryCharsetBomLength(charsetName)
    val result = StringBuilder(length)
    var index = 0
    var encodedUnsafeRun = false
    while (index < length) {
        val char = this[index]
        when {
            char.isAsciiLetterOrDigit() || char in safeChars -> {
                result.append(char)
                index++
            }
            char == ' ' && spaceToPlus -> {
                result.append('+')
                index++
            }
            else -> {
                val start = index
                // Surrogates are unsafe, so a legal pair stays within the same run.
                do {
                    index++
                } while (
                    index < length && !this[index].isAsciiLetterOrDigit() && this[index] !in safeChars &&
                    !(spaceToPlus && this[index] == ' ')
                )
                val run = substring(start, index)
                val bytes = if (spaceToPlus) TextCodec.encode(run, charsetName)
                    else encodeCharsetWriterText(run, charsetName)
                // URLEncoder restarts per run; PercentCodec keeps one writer for the whole query.
                val byteStart = if (encodedUnsafeRun) queryBomLength else 0
                for (byteIndex in byteStart until bytes.size) {
                    val value = bytes[byteIndex].toInt() and 0xFF
                    result.append('%')
                    result.append(hexDigits[value ushr 4])
                    result.append(hexDigits[value and 0x0F])
                }
                encodedUnsafeRun = true
            }
        }
    }
    return result.toString()
}

private fun legacyQueryCharsetBomLength(charsetName: String): Int {
    return when (charsetName.uppercase()) {
        "UTF-16", "UTF16", "UTF_16", "UNICODE", "UNICODEBIG", "X-UTF-16LE-BOM", "UNICODELITTLE" -> 2
        "UTF-32", "UTF32", "UTF_32", "X-UTF-32BE-BOM", "UTF-32BE-BOM", "UTF_32BE_BOM",
        "X-UTF-32LE-BOM", "UTF-32LE-BOM", "UTF_32LE_BOM" -> 4
        else -> 0
    }
}

private val legacyEscapeSafeChars = setOf('*', '@', '-', '_', '+', '.', '/')
private val legacyFormSafeChars = setOf('*', '-', '.', '_')
private val legacyQuerySafeChars = setOf(
    '!', '$', '&', '(', ')', '*', '+', ',', '-', '.', '/', ':', ';', '=', '?', '@',
    '[', '\\', ']', '^', '_', '`', '{', '|', '}', '~',
)
private val legacyQueryComponentSafeChars = legacyQuerySafeChars - setOf('&', '=')
private val legacyQueryEncoderSafeChars = legacyQuerySafeChars + '%'
private val hexDigits = "0123456789ABCDEF".toCharArray()
