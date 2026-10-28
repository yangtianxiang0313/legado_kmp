package io.legado.kmp.shared.network

import io.ktor.http.encodeURLQueryComponent
import io.legado.kmp.shared.platform.TextCodec

internal fun encodeLegacyUrlParameters(params: String, charset: String?, isQuery: Boolean): String {
    if (params.isBlank()) return params
    val escapeMode = charset.equals("escape", ignoreCase = true)
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
        if (segment.isBlank()) return@joinToString ""
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
                char.toString().encodeToByteArray().forEach { byte ->
                    val value = byte.toInt() and 0xFF
                    result.append('%')
                    result.append(hexDigits[value ushr 4])
                    result.append(hexDigits[value and 0x0F])
                }
                index++
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
    val bytes = TextCodec.encode(this, charsetName)
    val result = StringBuilder(bytes.size * 3)
    for (byte in bytes) {
        val value = byte.toInt() and 0xFF
        when {
            value.isUrlUnreserved() -> result.append(value.toChar())
            value == 0x20 && spaceToPlus -> result.append('+')
            else -> {
                result.append('%')
                result.append(hexDigits[value ushr 4])
                result.append(hexDigits[value and 0x0F])
            }
        }
    }
    return result.toString()
}

private fun Int.isUrlUnreserved(): Boolean {
    return this in 'A'.code..'Z'.code ||
        this in 'a'.code..'z'.code ||
        this in '0'.code..'9'.code ||
        this == '-'.code ||
        this == '_'.code ||
        this == '.'.code ||
        this == '~'.code
}

private val legacyEscapeSafeChars = setOf('*', '@', '-', '_', '+', '.', '/')
private val legacyQuerySafeChars = setOf(
    '!', '$', '&', '(', ')', '*', '+', ',', '-', '.', '/', ':', ';', '=', '?', '@',
    '[', '\\', ']', '^', '_', '`', '{', '|', '}', '~',
)
private val legacyQueryComponentSafeChars = legacyQuerySafeChars - setOf('&', '=')
private val hexDigits = "0123456789ABCDEF".toCharArray()
