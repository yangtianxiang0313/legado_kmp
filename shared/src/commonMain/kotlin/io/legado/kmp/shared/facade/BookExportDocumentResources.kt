package io.legado.kmp.shared.facade

import io.legado.kmp.shared.domain.localbook.LocalBookSvg

/** Path is relative to content.opf, not to a chapter or to the ZIP root. */
internal data class EpubResourceEntry(
    val path: String,
    val mediaType: String,
    val isCover: Boolean = false,
)

internal data class EpubImageFormat(val extension: String, val mediaType: String)

/** Classifies the actual payload; a cache filename or source URL is not a format declaration. */
internal fun epubImageFormat(bytes: ByteArray): EpubImageFormat? {
    if (bytes.isEmpty() || bytes.size > 64 * 1024 * 1024) return null
    fun magic(vararg values: Int): Boolean = bytes.size >= values.size &&
        values.indices.all { bytes[it].toInt() and 0xff == values[it] }
    fun ascii(offset: Int, size: Int): String = bytes.decodeToString(offset, offset + size)
    return when {
        magic(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a) -> EpubImageFormat("png", "image/png")
        magic(0xff, 0xd8, 0xff) -> EpubImageFormat("jpg", "image/jpeg")
        bytes.size >= 6 && ascii(0, 6) in setOf("GIF87a", "GIF89a") -> EpubImageFormat("gif", "image/gif")
        bytes.size >= 12 && ascii(0, 4) == "RIFF" && ascii(8, 4) == "WEBP" -> EpubImageFormat("webp", "image/webp")
        magic(0x42, 0x4d) -> EpubImageFormat("bmp", "image/bmp")
        magic(0x49, 0x49, 0x2a, 0) || magic(0x4d, 0x4d, 0, 0x2a) -> EpubImageFormat("tiff", "image/tiff")
        magic(0, 0, 1, 0) -> EpubImageFormat("ico", "image/x-icon")
        bytes.size >= 16 && ascii(4, 4) == "ftyp" -> {
            val boxSize = (0..3).fold(0L) { value, index -> (value shl 8) or (bytes[index].toLong() and 0xff) }
            if (boxSize < 16 || boxSize > bytes.size || boxSize > 4096) return null
            val brands = mutableSetOf(ascii(8, 4))
            var offset = 16
            while (offset + 4 <= boxSize.toInt()) {
                brands += ascii(offset, 4)
                offset += 4
            }
            when {
                brands.any { it == "avif" || it == "avis" } -> EpubImageFormat("avif", "image/avif")
                brands.any { it in setOf("heic", "heix", "hevc", "hevx", "heim", "heis") } -> EpubImageFormat("heic", "image/heic")
                brands.any { it == "mif1" || it == "msf1" } -> EpubImageFormat("heif", "image/heif")
                else -> null
            }
        }
        LocalBookSvg.isSvg(bytes) -> EpubImageFormat("svg", "image/svg+xml")
        else -> null
    }
}

internal fun String.xmlEscaped(): String = buildString(length) {
    var index = 0
    while (index < this@xmlEscaped.length) {
        val char = this@xmlEscaped[index++]
        when (char) {
            '&' -> append("&amp;")
            '<' -> append("&lt;")
            '>' -> append("&gt;")
            '"' -> append("&quot;")
            '\'' -> append("&apos;")
            in '\uD800'..'\uDBFF' -> {
                val next = this@xmlEscaped.getOrNull(index)
                if (next != null && next in '\uDC00'..'\uDFFF') {
                    append(char).append(next)
                    index++
                } else append('\uFFFD')
            }
            in '\uDC00'..'\uDFFF', '\uFFFE', '\uFFFF' -> append('\uFFFD')
            else -> if (char >= ' ' || char in "\t\n\r") append(char) else append('\uFFFD')
        }
    }
}

internal fun epubLanguage(language: String): String =
    language.takeIf { it.length <= 64 && it.matches(Regex("[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*")) } ?: "zh-CN"
