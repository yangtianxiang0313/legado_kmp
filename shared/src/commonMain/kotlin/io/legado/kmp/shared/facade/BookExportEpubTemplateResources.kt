package io.legado.kmp.shared.facade

import com.fleeksoft.ksoup.Ksoup
import com.fleeksoft.ksoup.parser.Parser
import kotlinx.serialization.json.Json

/** An explicit passive-resource allowlist; bytes and author CSS are never rewritten here. */
internal object BookExportEpubTemplateResources {
    private val htmlExtensions = setOf("html", "xhtml", "htm")
    private val imageExtensions = setOf(
        "png", "jpg", "jpeg", "jpe", "gif", "webp", "bmp", "tif", "tiff", "ico", "svg", "avif", "heic", "heif",
    )
    private val fontExtensions = setOf("ttf", "otf", "woff", "woff2")
    private val textTypes = mapOf(
        "css" to "text/css",
        "txt" to "text/plain",
        "xml" to "application/xml",
        "json" to "application/json",
        "smil" to "application/smil+xml",
        "pls" to "application/pls+xml",
        "mml" to "application/mathml+xml",
        "vtt" to "text/vtt",
    )
    private val audioExtensions = setOf("mp3", "m4a", "ogg", "opus", "wav", "flac")

    fun isHtml(path: String): Boolean = extension(path) in htmlExtensions

    fun isSupported(path: String): Boolean = extension(path).let {
        it in htmlExtensions || it in imageExtensions || it in fontExtensions || it in textTypes || it in audioExtensions
    }

    fun mediaType(path: String, data: ByteArray, checkActive: () -> Unit): String {
        checkActive()
        val extension = extension(path)
        return when {
            extension in htmlExtensions -> {
                rejectScriptTags(utf8(data, checkActive), xml = false, checkActive = checkActive)
                if (extension == "xhtml") "application/xhtml+xml" else "text/html"
            }
            extension in imageExtensions -> {
                val format = epubImageFormat(data) ?: invalidResource()
                if (format.extension == "svg") {
                    rejectScriptTags(utf8(data, checkActive), xml = true, checkActive = checkActive)
                }
                checkActive()
                format.mediaType
            }
            extension in fontExtensions -> fontMediaType(data, checkActive) ?: invalidResource()
            extension in textTypes -> {
                val text = utf8(data, checkActive)
                when (extension) {
                    "xml", "smil", "pls", "mml" -> rejectScriptTags(
                        text,
                        xml = true,
                        checkActive = checkActive,
                        expectedRoot = when (extension) {
                            "smil" -> "smil"
                            "pls" -> "lexicon"
                            "mml" -> "math"
                            else -> null
                        },
                    )
                    "json" -> {
                        // Bound parser recursion independently of the resource byte budget.
                        var depth = 0
                        var quoted = false
                        var escaped = false
                        text.forEachIndexed { index, char ->
                            if (index and 65535 == 0) checkActive()
                            if (quoted) {
                                if (escaped) escaped = false else when (char) {
                                    '\\' -> escaped = true
                                    '"' -> quoted = false
                                }
                            } else when (char) {
                                '"' -> quoted = true
                                '{', '[' -> {
                                    depth++
                                    requireTemplate(depth <= 128, BookExportEpubTemplateProblem.INVALID_RESOURCE)
                                }
                                '}', ']' -> depth--
                            }
                        }
                        Json.parseToJsonElement(text)
                    }
                    "vtt" -> requireTemplate(text.removePrefix("\uFEFF").startsWith("WEBVTT"),
                        BookExportEpubTemplateProblem.INVALID_RESOURCE)
                }
                checkActive()
                textTypes.getValue(extension)
            }
            extension in audioExtensions -> audioMediaType(data) ?: invalidResource()
            else -> throw BookExportEpubTemplateFailure(BookExportEpubTemplateProblem.UNSUPPORTED_RESOURCE)
        }
    }

    fun utf8(data: ByteArray, checkActive: () -> Unit): String {
        checkActive()
        val text = try {
            data.decodeToString(throwOnInvalidSequence = true)
        } catch (error: Exception) {
            findFacadeRequestCancellation(error)?.let { throw it }
            throw BookExportEpubTemplateFailure(BookExportEpubTemplateProblem.INVALID_UTF8)
        }
        checkActive()
        return text
    }

    private fun rejectScriptTags(
        text: String,
        xml: Boolean,
        checkActive: () -> Unit,
        expectedRoot: String? = null,
    ) {
        checkActive()
        val document = if (xml) Ksoup.parse(html = text, parser = Parser.xmlParser()) else Ksoup.parse(text)
        checkActive()
        if (xml) {
            val roots = document.children()
            requireTemplate(roots.size == 1, BookExportEpubTemplateProblem.INVALID_RESOURCE)
            if (expectedRoot != null) {
                requireTemplate(roots.first()!!.tagName().substringAfterLast(':').equals(expectedRoot, ignoreCase = true),
                    BookExportEpubTemplateProblem.INVALID_RESOURCE)
            }
        }
        document.getAllElements().forEach { element ->
            checkActive()
            requireTemplate(!element.tagName().substringAfterLast(':').equals("script", ignoreCase = true),
                BookExportEpubTemplateProblem.SCRIPT_RESOURCE)
        }
        checkActive()
    }

    private fun fontMediaType(data: ByteArray, checkActive: () -> Unit): String? = when {
        data.size >= 12 && (data.magic(0, 0, 1, 0, 0) || data.ascii(0, "true")) ->
            "font/ttf".takeIf { validSfntDirectory(data, checkActive) }
        data.size >= 12 && data.ascii(0, "OTTO") -> "font/otf".takeIf { validSfntDirectory(data, checkActive) }
        data.size >= 44 && data.ascii(0, "wOFF") -> "font/woff".takeIf {
            data.uint32(8) == data.size.toLong() && data.uint16(12) > 0 &&
                44L + data.uint16(12) * 20L <= data.size && data.uint16(14) == 0
        }
        data.size >= 48 && data.ascii(0, "wOF2") -> "font/woff2".takeIf {
            data.uint32(8) == data.size.toLong() && data.uint16(12) > 0 && data.uint16(14) == 0 &&
                data.uint32(20) in 1..(data.size - 48).toLong()
        }
        else -> null
    }

    private fun validSfntDirectory(data: ByteArray, checkActive: () -> Unit): Boolean {
        val count = data.uint16(4)
        if (count == 0 || 12L + count * 16L > data.size) return false
        repeat(count) { index ->
            checkActive()
            val record = 12 + index * 16
            if (data.uint32(record + 8) + data.uint32(record + 12) > data.size) return false
        }
        return true
    }

    private fun audioMediaType(data: ByteArray): String? = when {
        data.size >= 10 && data.ascii(0, "ID3") -> "audio/mpeg"
        data.size >= 4 && data[0].toInt() and 255 == 255 && data[1].toInt() and 0xe0 == 0xe0 &&
            data[1].toInt() and 6 != 0 && data[2].toInt() and 0xf0 !in setOf(0, 0xf0) &&
            data[2].toInt() and 0x0c != 0x0c -> "audio/mpeg"
        data.size >= 12 && data.ascii(0, "RIFF") && data.ascii(8, "WAVE") -> "audio/wav"
        data.size >= 8 && data.ascii(0, "fLaC") -> "audio/flac"
        data.size >= 28 && data.ascii(0, "OggS") && data[4].toInt() == 0 -> {
            val body = 27 + (data[26].toInt() and 255)
            "audio/ogg".takeIf { data.ascii(body, "OpusHead") || data.magic(body, 1) && data.ascii(body + 1, "vorbis") }
        }
        data.size >= 16 && data.ascii(4, "ftyp") -> {
            val boxSize = data.uint32(0)
            if (boxSize !in 16..minOf(data.size, 4096).toLong() || boxSize % 4 != 0L) {
                null
            } else {
                var offset = 8
                var audioBrand = false
                while (offset + 4 <= boxSize) {
                    if (offset != 12 && (data.ascii(offset, "M4A ") || data.ascii(offset, "M4B "))) audioBrand = true
                    offset += 4
                }
                "audio/mp4".takeIf { audioBrand }
            }
        }
        else -> null
    }

    private fun extension(path: String): String = path.substringAfterLast('/').substringAfterLast('.', "").lowercase()

    private fun ByteArray.magic(offset: Int, vararg values: Int): Boolean =
        offset >= 0 && offset.toLong() + values.size <= size &&
            values.indices.all { this[offset + it].toInt() and 255 == values[it] }

    private fun ByteArray.ascii(offset: Int, value: String): Boolean =
        offset >= 0 && offset.toLong() + value.length <= size && value.indices.all { this[offset + it].toInt() == value[it].code }

    private fun ByteArray.uint16(offset: Int): Int = ((this[offset].toInt() and 255) shl 8) or (this[offset + 1].toInt() and 255)

    private fun ByteArray.uint32(offset: Int): Long = (0..3).fold(0L) { value, index ->
        (value shl 8) or (this[offset + index].toLong() and 255)
    }

    private fun invalidResource(): Nothing = throw BookExportEpubTemplateFailure(BookExportEpubTemplateProblem.INVALID_RESOURCE)
}
