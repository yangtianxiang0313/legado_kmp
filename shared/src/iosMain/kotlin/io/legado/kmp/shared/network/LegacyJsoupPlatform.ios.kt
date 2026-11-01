package io.legado.kmp.shared.network

import io.legado.kmp.shared.platform.TextCodec
import io.legado.kmp.shared.platform.convertPlatformTextBytes
import io.legado.kmp.shared.platform.platformSupportsTextCharset

// NSURLSession transparently decodes these content codings before Darwin's data delegate;
// the original response headers can still contain Content-Encoding / compressed Content-Length.
internal actual fun legacyJsoupPlatformDecodesContentEncoding(encoding: String): Boolean =
    encoding == "gzip" || encoding == "deflate" || encoding == "br"

internal actual fun legacyJsoupPlatformSupportsCharset(name: String): Boolean = platformSupportsTextCharset(name)

internal actual fun legacyJsoupPlatformEncode(text: String, charset: String, check: () -> Unit): ByteArray {
    check()
    if (text.isEmpty()) return byteArrayOf()
    val target = explicitUnicodeOrder(charset)
    // Keep the replacement in the destination encoding (including non-ASCII-compatible charsets).
    val replacement = convertPlatformTextBytes(byteArrayOf(63), "UTF-8", target, null, true, check)
    // Preserve Jsoup's existing Kotlin UTF-8 input normalization, independent of TextCodec's Java policy.
    val result = convertPlatformTextBytes(text.encodeToByteArray(), "UTF-8", target, replacement, true, check)
    return if (charset == "UTF-16") byteArrayOf(0xfe.toByte(), 0xff.toByte()) + result else result
}

internal actual fun legacyJsoupPlatformDecode(bytes: ByteArray, charset: String, check: () -> Unit): String {
    val result = convertPlatformTextBytes(bytes, explicitUnicodeOrder(charset), "UTF-8", REPLACEMENT_UTF8, false, check)
    check()
    return TextCodec.decode(result, "UTF-8")
}

private fun explicitUnicodeOrder(charset: String): String = when (charset.uppercase()) {
    "UTF-16" -> "UTF-16BE"
    "UTF-32" -> "UTF-32BE"
    else -> charset
}

private val REPLACEMENT_UTF8 = byteArrayOf(0xef.toByte(), 0xbf.toByte(), 0xbd.toByte())
