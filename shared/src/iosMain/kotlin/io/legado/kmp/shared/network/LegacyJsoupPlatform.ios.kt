@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.legado.kmp.shared.network

import io.legado.kmp.shared.platform.TextCodec
import kotlinx.cinterop.ByteVar
import kotlinx.cinterop.COpaquePointer
import kotlinx.cinterop.CPointerVar
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.alloc
import kotlinx.cinterop.convert
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.plus
import kotlinx.cinterop.ptr
import kotlinx.cinterop.usePinned
import kotlinx.cinterop.value
import okio.Buffer
import platform.iconv.iconv
import platform.iconv.iconv_close
import platform.iconv.iconv_open
import platform.posix.E2BIG
import platform.posix.EILSEQ
import platform.posix.EINVAL
import platform.posix.errno
import platform.posix.size_tVar

// NSURLSession transparently decodes these content codings before Darwin's data delegate;
// the original response headers can still contain Content-Encoding / compressed Content-Length.
internal actual fun legacyJsoupPlatformDecodesContentEncoding(encoding: String): Boolean =
    encoding == "gzip" || encoding == "deflate" || encoding == "br"

internal actual fun legacyJsoupPlatformSupportsCharset(name: String): Boolean {
    val converter = openCodec("UTF-8", name) ?: return false
    iconv_close(converter)
    return true
}

internal actual fun legacyJsoupPlatformEncode(text: String, charset: String, check: () -> Unit): ByteArray {
    check()
    if (text.isEmpty()) return byteArrayOf()
    val target = explicitUnicodeOrder(charset)
    // Keep the replacement in the destination encoding (including non-ASCII-compatible charsets).
    val replacement = convertBytes(byteArrayOf(63), "UTF-8", target, null, true, check)
    val result = convertBytes(TextCodec.encode(text, "UTF-8"), "UTF-8", target, replacement, true, check)
    return if (charset == "UTF-16") byteArrayOf(0xfe.toByte(), 0xff.toByte()) + result else result
}

internal actual fun legacyJsoupPlatformDecode(bytes: ByteArray, charset: String, check: () -> Unit): String {
    val result = convertBytes(bytes, explicitUnicodeOrder(charset), "UTF-8", REPLACEMENT_UTF8, false, check)
    check()
    return TextCodec.decode(result, "UTF-8")
}

private fun explicitUnicodeOrder(charset: String): String = when (charset.uppercase()) {
    "UTF-16" -> "UTF-16BE"
    "UTF-32" -> "UTF-32BE"
    else -> charset
}

private fun openCodec(to: String, from: String): COpaquePointer? {
    val converter = iconv_open(to, from) ?: return null
    return converter.takeUnless { it.rawValue.toLong() == -1L }
}

/** iconv keeps decoder state; only malformed sequences are replaced, never a whole-body charset fallback. */
private fun convertBytes(
    bytes: ByteArray,
    from: String,
    to: String,
    replacement: ByteArray?,
    encoding: Boolean,
    check: () -> Unit,
): ByteArray {
    check()
    if (bytes.isEmpty()) return byteArrayOf()
    val converter = requireNotNull(openCodec(to, from)) { "Unsupported Jsoup charset: $from -> $to" }
    val output = Buffer()
    val scratch = ByteArray(8192)
    try {
        bytes.usePinned { inputPin ->
            scratch.usePinned { outputPin ->
                memScoped {
                    val input = alloc<CPointerVar<ByteVar>>()
                    val inputLeft = alloc<size_tVar>()
                    val target = alloc<CPointerVar<ByteVar>>()
                    val targetLeft = alloc<size_tVar>()
                    input.value = inputPin.addressOf(0)
                    inputLeft.value = bytes.size.convert()

                    fun step(reset: Boolean): Int {
                        check()
                        target.value = outputPin.addressOf(0)
                        targetLeft.value = scratch.size.convert()
                        val result = if (reset) iconv(converter, null, null, target.ptr, targetLeft.ptr)
                            else iconv(converter, input.ptr, inputLeft.ptr, target.ptr, targetLeft.ptr)
                        val failure = if (result.toLong() == -1L) errno else 0
                        val count = scratch.size - targetLeft.value.toInt()
                        if (count > 0) output.write(scratch, 0, count)
                        return failure
                    }

                    fun reset() {
                        while (true) {
                            val failure = step(true)
                            if (failure == 0) return
                            require(failure == E2BIG) { "Jsoup charset state flush failed ($failure)" }
                        }
                    }

                    while (inputLeft.value > 0uL) {
                        val failure = step(false)
                        if (failure == 0 || failure == E2BIG) continue
                        require((failure == EILSEQ || failure == EINVAL) && replacement != null) {
                            "Jsoup charset conversion failed ($failure)"
                        }
                        if (encoding) reset()
                        output.write(requireNotNull(replacement))
                        val remaining = inputLeft.value.toInt()
                        val skip = when {
                            failure == EINVAL -> remaining
                            encoding -> {
                                val lead = bytes[bytes.size - remaining].toInt() and 0xff
                                when { lead < 0x80 -> 1; lead < 0xe0 -> 2; lead < 0xf0 -> 3; else -> 4 }
                            }
                            from.startsWith("UTF-32", true) -> 4
                            from.startsWith("UTF-16", true) -> 2
                            else -> 1
                        }.coerceAtMost(remaining)
                        input.value = requireNotNull(input.value) + skip
                        inputLeft.value -= skip.toULong()
                    }
                    reset()
                }
            }
        }
        check()
        return output.readByteArray()
    } finally {
        iconv_close(converter)
        output.clear()
    }
}

private val REPLACEMENT_UTF8 = byteArrayOf(0xef.toByte(), 0xbf.toByte(), 0xbd.toByte())
