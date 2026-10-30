package io.legado.kmp.shared.network

import com.fleeksoft.ksoup.Ksoup
import io.legado.kmp.shared.platform.TextCodec

internal data class LegacyJsoupDecodedBody(val text: String, val charset: String?)

internal fun legacyJsoupDecodeBody(bytes: ByteArray, contentType: String?, check: () -> Unit = {}): LegacyJsoupDecodedBody {
    check()
    val headerCharset = charsetFromContentType(contentType)
    if (bytes.isEmpty()) return LegacyJsoupDecodedBody("", headerCharset)
    val bom = when {
        bytes.startsWithBytes(0, 0, 0xfe, 0xff) -> "UTF-32BE" to 4
        bytes.startsWithBytes(0xff, 0xfe, 0, 0) -> "UTF-32LE" to 4
        TextCodec.hasUtf8Bom(bytes) -> "UTF-8" to 3
        bytes.startsWithBytes(0xfe, 0xff) -> "UTF-16BE" to 2
        bytes.startsWithBytes(0xff, 0xfe) -> "UTF-16LE" to 2
        else -> null
    }
    val explicitCharset = bom?.first ?: headerCharset ?: declaredCharset(bytes)
    val charset = explicitCharset ?: "UTF-8"
    val body = if (bom == null) bytes else bytes.copyOfRange(bom.second, bytes.size)
    val text = if (charset == "UTF-8") {
        // Truncation may split a scalar; NSString's all-or-nothing decode would fall back to Latin-1.
        body.decodeToString()
    } else legacyJsoupPlatformDecode(body, charset, check)
    check()
    return LegacyJsoupDecodedBody(text, explicitCharset)
}

private fun declaredCharset(bytes: ByteArray): String? {
    val sample = bytes.copyOf(minOf(bytes.size, 5119)).decodeToString()
    val document = Ksoup.parse(sample)
    for (meta in document.select("meta[http-equiv=content-type], meta[charset]")) {
        val value = (if (meta.hasAttr("http-equiv")) charsetFromContentType(meta.attr("content")) else null)
            ?: legacyJsoupCharset(meta.attr("charset"))
        if (value != null) return value
    }
    return XML_ENCODING.find(sample)?.groupValues?.getOrNull(1)?.let(::legacyJsoupCharset)
}

private fun charsetFromContentType(value: String?): String? = value?.let {
    CHARSET.find(it)?.groupValues?.getOrNull(1)?.let(::legacyJsoupCharset)
}

internal fun legacyJsoupCharset(value: String): String? {
    val name = value.trim().trim('"', '\'')
    if (name.isEmpty() || name.length > 128 || !name[0].isLetterOrDigit() ||
        name.any { it !in 'a'..'z' && it !in 'A'..'Z' && it !in '0'..'9' && it !in "-+._:" }
    ) return null
    return when (name.uppercase()) {
        "UTF-8", "UTF8" -> "UTF-8"
        "UTF-16", "UTF16" -> "UTF-16"
        "UTF-16LE", "UTF16LE" -> "UTF-16LE"
        "UTF-16BE", "UTF16BE" -> "UTF-16BE"
        "ASCII", "US-ASCII" -> "ASCII"
        "ISO-8859-1", "ISO8859-1", "LATIN1", "ISO_8859-1" -> "ISO-8859-1"
        "GBK" -> "GBK"
        "GB2312" -> "GB2312"
        "GB18030", "GB_18030" -> "GB18030"
        "BIG5", "BIG-5" -> "BIG5"
        "SHIFT_JIS", "SHIFT-JIS", "SJIS" -> "SHIFT_JIS"
        "EUC-JP", "EUCJP" -> "EUC-JP"
        "UTF-32", "UTF32" -> "UTF-32"
        "UTF-32BE", "UTF32BE" -> "UTF-32BE"
        "UTF-32LE", "UTF32LE" -> "UTF-32LE"
        else -> name.takeIf { legacyJsoupPlatformSupportsCharset(it) }
    }
}

internal fun legacyJsoupEncode(text: String, charset: String, check: () -> Unit): ByteArray {
    check()
    val bytes = if (charset == "UTF-8") TextCodec.encode(text, charset)
        else legacyJsoupPlatformEncode(text, charset, check)
    check()
    return bytes
}

internal fun legacyJsoupResponseHeader(value: String): String {
    if (value.none { it.code in 128..255 } || value.any { it.code > 255 }) return value
    val bytes = TextCodec.encode(value, "ISO-8859-1")
    return try { bytes.decodeToString(throwOnInvalidSequence = true) } catch (_: Exception) { value }
}

private fun ByteArray.startsWithBytes(vararg values: Int): Boolean = size >= values.size &&
    values.indices.all { this[it].toInt() and 0xff == values[it] }

private val CHARSET = Regex("(?i)charset\\s*=\\s*[\"']?([^\\s;\"'>]+)")
private val XML_ENCODING = Regex("(?is)^\\s*<\\?xml\\s+[^>]*encoding\\s*=\\s*[\"']([^\"']+)[\"']")
