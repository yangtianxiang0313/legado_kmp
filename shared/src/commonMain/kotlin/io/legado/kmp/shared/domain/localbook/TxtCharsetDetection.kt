package io.legado.kmp.shared.domain.localbook

import io.legado.kmp.shared.platform.TextCodec

private const val TXT_CHARSET_WINDOW_BYTES = 512000
private const val TXT_CHARSET_SAMPLE_CONTEXT = 64L
private const val TXT_CHARSET_CHECK_INTERVAL = 4096

/** Detects without owning/closing [source] or retaining a document-sized byte array. */
internal fun detectTxtCharset(source: LocalBookByteSource, checkActive: () -> Unit): String {
    checkActive()
    val size = source.size
    require(size >= 0L) { "TXT byte source size must not be negative" }
    if (size == 0L) return detectTxtCharsetSample(ByteArray(0), checkActive)

    val utf8 = TxtCharsetUtf8State()
    var firstNonAscii: Long? = null
    var firstNul: Long? = null
    var offset = 0L
    while (offset < size) {
        checkActive()
        val length = minOf(TXT_CHARSET_WINDOW_BYTES.toLong(), size - offset).toInt()
        val bytes = readTxtCharsetBytes(source, offset, length, checkActive)
        if (offset == 0L) {
            when {
                bytes.size >= 3 && bytes[0].unsigned() == 0xef &&
                    bytes[1].unsigned() == 0xbb && bytes[2].unsigned() == 0xbf -> return "UTF-8"
                bytes.size >= 2 && bytes[0].unsigned() == 0xff &&
                    bytes[1].unsigned() == 0xfe -> return "UTF-16LE"
                bytes.size >= 2 && bytes[0].unsigned() == 0xfe &&
                    bytes[1].unsigned() == 0xff -> return "UTF-16BE"
            }
        }
        for (index in bytes.indices) {
            if (index % TXT_CHARSET_CHECK_INTERVAL == 0) checkActive()
            val value = bytes[index].unsigned()
            val byteOffset = offset + index
            if (value >= 0x80 && firstNonAscii == null) firstNonAscii = byteOffset
            if (value == 0 && firstNul == null) firstNul = byteOffset
            if (!utf8.accept(value, byteOffset)) {
                return detectTxtCharsetFromSource(
                    source, size, firstNonAscii, firstNul, utf8.sequenceStart, checkActive
                )
            }
        }
        offset += bytes.size
    }
    checkActive()
    if (utf8.remaining != 0) {
        return detectTxtCharsetFromSource(
            source, size, firstNonAscii, firstNul, utf8.sequenceStart, checkActive
        )
    }
    // NUL-containing UTF-16 without a BOM can also be legal UTF-8 bytes. Leave that decision to the codec.
    if (firstNul != null) {
        return detectTxtCharsetFromSource(source, size, firstNonAscii, firstNul, null, checkActive)
    }
    return "UTF-8"
}

private class TxtCharsetUtf8State {
    var remaining: Int = 0
        private set
    var sequenceStart: Long = 0L
        private set
    private var nextMinimum = 0x80
    private var nextMaximum = 0xbf

    fun accept(value: Int, offset: Long): Boolean {
        if (remaining != 0) {
            if (value !in nextMinimum..nextMaximum) return false
            remaining--
            nextMinimum = 0x80
            nextMaximum = 0xbf
            return true
        }
        sequenceStart = offset
        when (value) {
            in 0x00..0x7f -> return true
            in 0xc2..0xdf -> remaining = 1
            in 0xe0..0xef -> {
                remaining = 2
                nextMinimum = if (value == 0xe0) 0xa0 else 0x80
                nextMaximum = if (value == 0xed) 0x9f else 0xbf
            }
            in 0xf0..0xf4 -> {
                remaining = 3
                nextMinimum = if (value == 0xf0) 0x90 else 0x80
                nextMaximum = if (value == 0xf4) 0x8f else 0xbf
            }
            else -> return false
        }
        return true
    }
}

private fun detectTxtCharsetFromSource(
    source: LocalBookByteSource,
    size: Long,
    firstNonAscii: Long?,
    firstNul: Long?,
    invalidUtf8Offset: Long?,
    checkActive: () -> Unit
): String {
    checkActive()
    if (size <= TXT_CHARSET_WINDOW_BYTES) {
        // Preserve the existing platform detector's input for small, non-BOM documents.
        return detectTxtCharsetSample(readTxtCharsetBytes(source, 0L, size.toInt(), checkActive), checkActive)
    }

    val firstEvidence = listOfNotNull(firstNonAscii, firstNul).minOrNull() ?: 0L
    val otherEvidence = invalidUtf8Offset ?: firstNul ?: firstEvidence
    val earlier = minOf(firstEvidence, otherEvidence)
    val later = maxOf(firstEvidence, otherEvidence)
    val start = txtCharsetSampleStart(earlier)
    val knownUtf8End = invalidUtf8Offset ?: size
    if (later - start <= TXT_CHARSET_WINDOW_BYTES - 4L) {
        val sample = readTxtCharsetSample(source, size, start, TXT_CHARSET_WINDOW_BYTES, knownUtf8End, checkActive)
        return detectTxtCharsetSample(sample, checkActive)
    }

    // Keep both the first non-ASCII text and the UTF-8 failure even when separated by a long preamble.
    val halfWindow = TXT_CHARSET_WINDOW_BYTES / 2
    val first = readTxtCharsetSample(source, size, start, halfWindow, knownUtf8End, checkActive)
    val second = readTxtCharsetSample(
        source, size, txtCharsetSampleStart(later), halfWindow, knownUtf8End, checkActive
    )
    checkActive()
    val sample = ByteArray(first.size + second.size)
    first.copyInto(sample)
    checkActive()
    second.copyInto(sample, first.size)
    return detectTxtCharsetSample(sample, checkActive)
}

private fun txtCharsetSampleStart(evidenceOffset: Long): Long {
    val start = (evidenceOffset - TXT_CHARSET_SAMPLE_CONTEXT).coerceAtLeast(0L)
    // Preserve UTF-16 code-unit parity without choosing an encoding in commonMain.
    return start - start % 2L
}

private fun readTxtCharsetSample(
    source: LocalBookByteSource,
    size: Long,
    start: Long,
    limit: Int,
    knownUtf8End: Long,
    checkActive: () -> Unit
): ByteArray {
    val length = minOf(limit.toLong(), size - start).toInt()
    val bytes = readTxtCharsetBytes(source, start, length, checkActive)
    var from = 0
    var to = bytes.size
    // Only adjust boundaries in the validated prefix; never erase a real malformed sequence or EOF truncation.
    if (start > 0L && start < knownUtf8End) {
        while (from < minOf(3, to) && start + from < knownUtf8End && bytes[from].unsigned() in 0x80..0xbf) {
            checkActive()
            from++
        }
    }
    val end = start + bytes.size
    if (end < size && end <= knownUtf8End) {
        var lead = to - 1
        var continuations = 0
        while (lead >= from && continuations < 3 && bytes[lead].unsigned() in 0x80..0xbf) {
            checkActive()
            lead--
            continuations++
        }
        if (lead >= from) {
            val width = when (bytes[lead].unsigned()) {
                in 0xc2..0xdf -> 2
                in 0xe0..0xef -> 3
                in 0xf0..0xf4 -> 4
                else -> 1
            }
            if (to - lead < width) to = lead
        }
    }
    checkActive()
    return if (from == 0 && to == bytes.size) bytes else bytes.copyOfRange(from, to)
}

private fun detectTxtCharsetSample(sample: ByteArray, checkActive: () -> Unit): String {
    checkActive()
    val charset = TextCodec.detectCharset(sample)
    checkActive()
    return charset
}

private fun readTxtCharsetBytes(
    source: LocalBookByteSource,
    offset: Long,
    length: Int,
    checkActive: () -> Unit
): ByteArray {
    checkActive()
    val first = source.read(offset, length)
    checkActive()
    check(first.isNotEmpty() && first.size <= length) { "TXT byte source did not advance at byte $offset" }
    if (first.size == length) return first

    val bytes = ByteArray(length)
    first.copyInto(bytes)
    var copied = first.size
    while (copied < length) {
        checkActive()
        val part = source.read(offset + copied, length - copied)
        checkActive()
        check(part.isNotEmpty() && part.size <= length - copied) {
            "TXT byte source did not advance at byte ${offset + copied}"
        }
        part.copyInto(bytes, copied)
        copied += part.size
    }
    return bytes
}

private fun Byte.unsigned(): Int = toInt() and 0xff
