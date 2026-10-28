package io.legado.kmp.shared.image

import io.legado.kmp.shared.platform.FileAccess

/**
 * Basic cross-platform image size decoder.
 *
 * Reads image dimensions from file headers without fully decoding pixel data.
 * Supports: PNG, JPEG, GIF, BMP, WEBP.
 *
 * For SVG, parses width/height attributes from the root <svg> element.
 *
 * Platform-specific implementations can override this for better performance
 * or additional format support.
 */
class BasicImageSizeDecoder(
    private val fileAccess: FileAccess,
) : ImageSizeDecoder {

    override fun decodeSize(data: ByteArray): ImageSize? {
        if (data.size < 8) return null
        return decodePng(data)
            ?: decodeJpeg(data)
            ?: decodeGif(data)
            ?: decodeBmp(data)
            ?: decodeWebp(data)
            ?: decodeSvg(data)
    }

    override suspend fun decodeSizeFromPath(path: String): ImageSize? {
        if (!fileAccess.exists(path)) return null
        val data = runCatching { fileAccess.read(path) }.getOrNull() ?: return null
        return decodeSize(data)
    }

    // PNG: 8-byte signature, then IHDR chunk with width/height at offset 16-23
    private fun decodePng(data: ByteArray): ImageSize? {
        if (data.size < 24) return null
        // PNG signature: 137 80 78 71 13 10 26 10
        if (data[0] != 0x89.toByte() || data[1] != 0x50.toByte() ||
            data[2] != 0x4E.toByte() || data[3] != 0x47.toByte()
        ) return null
        val width = readInt32BE(data, 16)
        val height = readInt32BE(data, 20)
        return if (width > 0 && height > 0) ImageSize(width, height) else null
    }

    // JPEG: SOI marker (FF D8), then scan for SOFn markers
    private fun decodeJpeg(data: ByteArray): ImageSize? {
        if (data.size < 4) return null
        if (data[0] != 0xFF.toByte() || data[1] != 0xD8.toByte()) return null
        var offset = 2
        while (offset + 4 < data.size) {
            if (data[offset] != 0xFF.toByte()) {
                offset++
                continue
            }
            val marker = data[offset + 1].toInt() and 0xFF
            // SOF0-SOF15 (except SOF4=DHT, SOF8=JPG, SOF12=DAC)
            if (marker in 0xC0..0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC) {
                if (offset + 9 < data.size) {
                    val height = readInt16BE(data, offset + 5)
                    val width = readInt16BE(data, offset + 7)
                    return if (width > 0 && height > 0) ImageSize(width, height) else null
                }
            }
            val segmentLength = readInt16BE(data, offset + 2)
            if (segmentLength < 2) break
            offset += 2 + segmentLength
        }
        return null
    }

    // GIF: "GIF87a" or "GIF89a", width/height at offset 6-9 (little-endian)
    private fun decodeGif(data: ByteArray): ImageSize? {
        if (data.size < 10) return null
        if (data[0] != 0x47.toByte() || data[1] != 0x49.toByte() || data[2] != 0x46.toByte()) return null
        val width = readInt16LE(data, 6)
        val height = readInt16LE(data, 8)
        return if (width > 0 && height > 0) ImageSize(width, height) else null
    }

    // BMP: "BM" header, width/height at offset 18-25 (little-endian, 32-bit)
    private fun decodeBmp(data: ByteArray): ImageSize? {
        if (data.size < 26) return null
        if (data[0] != 0x42.toByte() || data[1] != 0x4D.toByte()) return null
        val width = readInt32LE(data, 18)
        val height = readInt32LE(data, 22)
        return if (width > 0 && height > 0) ImageSize(width, kotlin.math.abs(height)) else null
    }

    // WEBP: "RIFF....WEBP" header
    private fun decodeWebp(data: ByteArray): ImageSize? {
        if (data.size < 30) return null
        // RIFF header
        if (data[0] != 0x52.toByte() || data[1] != 0x49.toByte() ||
            data[2] != 0x46.toByte() || data[3] != 0x46.toByte()
        ) return null
        // WEBP signature
        if (data[8] != 0x57.toByte() || data[9] != 0x45.toByte() ||
            data[10] != 0x42.toByte() || data[11] != 0x50.toByte()
        ) return null
        // VP8 chunk
        if (data[12] == 0x56.toByte() && data[13] == 0x50.toByte() &&
            data[14] == 0x38.toByte()
        ) {
            when (data[15].toInt().toChar()) {
                ' ' -> {
                    // VP8 lossy: width/height at offset 26-29
                    if (data.size < 30) return null
                    val width = readInt16LE(data, 26) and 0x3FFF
                    val height = readInt16LE(data, 28) and 0x3FFF
                    return if (width > 0 && height > 0) ImageSize(width, height) else null
                }
                'L' -> {
                    // VP8L lossless: width/height encoded in bits at offset 21
                    if (data.size < 25) return null
                    val bits = readInt32LE(data, 21)
                    val width = (bits and 0x3FFF) + 1
                    val height = ((bits shr 14) and 0x3FFF) + 1
                    return if (width > 0 && height > 0) ImageSize(width, height) else null
                }
                'X' -> {
                    // VP8X extended: width/height at offset 24-29 (24-bit LE + 1)
                    if (data.size < 30) return null
                    val width = (readInt24LE(data, 24) + 1)
                    val height = (readInt24LE(data, 27) + 1)
                    return if (width > 0 && height > 0) ImageSize(width, height) else null
                }
            }
        }
        return null
    }

    // SVG: parse width/height from <svg> root element
    private fun decodeSvg(data: ByteArray): ImageSize? {
        // Quick check: SVG starts with '<' or '<?xml'
        val start = data.decodeToString(0, minOf(data.size, 1024), throwOnInvalidSequence = false)
        if (!start.contains("<svg", ignoreCase = true)) return null
        val svgTag = Regex("<svg[^>]*>", RegexOption.IGNORE_CASE).find(start) ?: return null
        val tag = svgTag.value
        val widthMatch = Regex("""width\s*=\s*"(\d+(?:\.\d+)?)""").find(tag)
        val heightMatch = Regex("""height\s*=\s*"(\d+(?:\.\d+)?)""").find(tag)
        if (widthMatch != null && heightMatch != null) {
            val width = widthMatch.groupValues[1].toFloatOrNull()?.toInt() ?: return null
            val height = heightMatch.groupValues[1].toFloatOrNull()?.toInt() ?: return null
            if (width > 0 && height > 0) return ImageSize(width, height)
        }
        // Try viewBox
        val viewBoxMatch = Regex("""viewBox\s*=\s*"([^"]+)"""").find(tag) ?: return null
        val parts = viewBoxMatch.groupValues[1].trim().split(Regex("[\\s,]+"))
        if (parts.size >= 4) {
            val width = parts[2].toFloatOrNull()?.toInt() ?: return null
            val height = parts[3].toFloatOrNull()?.toInt() ?: return null
            if (width > 0 && height > 0) return ImageSize(width, height)
        }
        return null
    }

    // Byte reading helpers
    private fun readInt16BE(data: ByteArray, offset: Int): Int {
        return ((data[offset].toInt() and 0xFF) shl 8) or
            (data[offset + 1].toInt() and 0xFF)
    }

    private fun readInt16LE(data: ByteArray, offset: Int): Int {
        return (data[offset].toInt() and 0xFF) or
            ((data[offset + 1].toInt() and 0xFF) shl 8)
    }

    private fun readInt24LE(data: ByteArray, offset: Int): Int {
        return (data[offset].toInt() and 0xFF) or
            ((data[offset + 1].toInt() and 0xFF) shl 8) or
            ((data[offset + 2].toInt() and 0xFF) shl 16)
    }

    private fun readInt32BE(data: ByteArray, offset: Int): Int {
        return ((data[offset].toInt() and 0xFF) shl 24) or
            ((data[offset + 1].toInt() and 0xFF) shl 16) or
            ((data[offset + 2].toInt() and 0xFF) shl 8) or
            (data[offset + 3].toInt() and 0xFF)
    }

    private fun readInt32LE(data: ByteArray, offset: Int): Int {
        return (data[offset].toInt() and 0xFF) or
            ((data[offset + 1].toInt() and 0xFF) shl 8) or
            ((data[offset + 2].toInt() and 0xFF) shl 16) or
            ((data[offset + 3].toInt() and 0xFF) shl 24)
    }
}
