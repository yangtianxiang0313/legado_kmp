@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.legado.kmp.shared.platform

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

internal fun isPlatformCharsetName(name: String): Boolean = name.isNotEmpty() &&
    name.withIndex().all { (index, char) ->
        char in 'a'..'z' || char in 'A'..'Z' || char in '0'..'9' ||
            (index > 0 && char in "-+._:")
    }

internal fun platformSupportsTextCharset(name: String): Boolean {
    val converter = openTextCodec("UTF-8", name) ?: return false
    iconv_close(converter)
    return true
}

private fun openTextCodec(to: String, from: String): COpaquePointer? {
    // Charset names, not iconv options: reject //TRANSLIT, //IGNORE and embedded NULs.
    if (!isPlatformCharsetName(to) || !isPlatformCharsetName(from)) return null
    val converter = iconv_open(to, from) ?: return null
    return converter.takeUnless { it.rawValue.toLong() == -1L }
}

/**
 * Preserves iconv state and replaces individual failures, never the whole body.
 * encodingUtf8 requires well-formed UTF-8 input so an unmappable scalar is skipped as a unit.
 */
internal fun convertPlatformTextBytes(
    bytes: ByteArray,
    from: String,
    to: String,
    replacement: ByteArray?,
    encodingUtf8: Boolean,
    check: () -> Unit = {},
): ByteArray {
    check()
    require(isPlatformCharsetName(from) && isPlatformCharsetName(to)) { "Illegal charset name: $from -> $to" }
    if (bytes.isEmpty()) return byteArrayOf()
    val converter = requireNotNull(openTextCodec(to, from)) { "Unsupported charset: $from -> $to" }
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
                            require(failure == E2BIG) { "Charset state flush failed ($failure)" }
                        }
                    }

                    while (inputLeft.value > 0uL) {
                        val failure = step(false)
                        if (failure == 0 || failure == E2BIG) continue
                        require((failure == EILSEQ || failure == EINVAL) && replacement != null) {
                            "Charset conversion failed ($failure)"
                        }
                        if (encodingUtf8) reset()
                        output.write(requireNotNull(replacement))
                        val remaining = inputLeft.value.toInt()
                        val skip = when {
                            failure == EINVAL -> remaining
                            encodingUtf8 -> {
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
