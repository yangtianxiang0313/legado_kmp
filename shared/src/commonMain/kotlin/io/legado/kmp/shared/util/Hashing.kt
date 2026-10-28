package io.legado.kmp.shared.util

import kotlin.math.abs
import kotlin.math.sin

fun String.md5Hex(): String {
    return encodeToByteArray().md5Hex()
}

fun ByteArray.md5Hex(): String {
    val padded = padForMd5(this)
    var a0 = 0x67452301
    var b0 = -0x10325477
    var c0 = -0x67452302
    var d0 = 0x10325476

    val words = IntArray(16)
    var offset = 0
    while (offset < padded.size) {
        for (index in 0 until 16) {
            val base = offset + index * 4
            words[index] = (padded[base].toInt() and 0xff) or
                ((padded[base + 1].toInt() and 0xff) shl 8) or
                ((padded[base + 2].toInt() and 0xff) shl 16) or
                ((padded[base + 3].toInt() and 0xff) shl 24)
        }

        var a = a0
        var b = b0
        var c = c0
        var d = d0

        for (index in 0 until 64) {
            val f: Int
            val g: Int
            when (index) {
                in 0..15 -> {
                    f = (b and c) or (b.inv() and d)
                    g = index
                }
                in 16..31 -> {
                    f = (d and b) or (d.inv() and c)
                    g = (5 * index + 1) % 16
                }
                in 32..47 -> {
                    f = b xor c xor d
                    g = (3 * index + 5) % 16
                }
                else -> {
                    f = c xor (b or d.inv())
                    g = (7 * index) % 16
                }
            }
            val temp = d
            d = c
            c = b
            val rotated = leftRotate(a + f + MD5_K[index] + words[g], MD5_S[index])
            b += rotated
            a = temp
        }

        a0 += a
        b0 += b
        c0 += c
        d0 += d
        offset += 64
    }

    return buildString(32) {
        appendWordHex(a0)
        appendWordHex(b0)
        appendWordHex(c0)
        appendWordHex(d0)
    }
}

private fun padForMd5(input: ByteArray): ByteArray {
    val bitLength = input.size.toLong() * 8L
    val paddingLength = ((56 - ((input.size + 1) % 64)) + 64) % 64
    val result = ByteArray(input.size + 1 + paddingLength + 8)
    input.copyInto(result, 0, 0, input.size)
    result[input.size] = 0x80.toByte()
    for (index in 0 until 8) {
        result[result.lastIndex - 7 + index] = ((bitLength ushr (index * 8)) and 0xffL).toByte()
    }
    return result
}

private fun leftRotate(value: Int, bits: Int): Int {
    return (value shl bits) or (value ushr (32 - bits))
}

private fun StringBuilder.appendWordHex(word: Int) {
    for (shift in 0 until 32 step 8) {
        appendByteHex((word ushr shift) and 0xff)
    }
}

private fun StringBuilder.appendByteHex(value: Int) {
    append(HEX_DIGITS[(value ushr 4) and 0x0f])
    append(HEX_DIGITS[value and 0x0f])
}

private val MD5_S = intArrayOf(
    7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
    5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21
)

private val MD5_K = IntArray(64) { index ->
    (abs(sin(index + 1.0)) * 4294967296.0).toLong().toInt()
}

private const val HEX_DIGITS = "0123456789abcdef"
