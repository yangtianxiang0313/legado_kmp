package io.legado.kmp.shared.domain.localbook

import com.fleeksoft.ksoup.Ksoup
import com.fleeksoft.ksoup.nodes.Document
import com.fleeksoft.ksoup.nodes.Element
import com.fleeksoft.ksoup.parser.Parser
import io.legado.kmp.shared.platform.TextCodec

/** Reuses the archive importer's bounded ZIP/header/CRC validation without extracting files. */
internal class EpubArchive(bytes: ByteArray, private val checkCancelled: () -> Unit) {
    private val archive = BookArchiveZipReader(bytes, checkCancelled)
    private val entries = archive.entries().associateBy { it.path }
    private val encryptedPaths: Set<String> by lazy {
        readText("META-INF/encryption.xml", MAX_PACKAGE_BYTES)?.let { xml ->
            parseEpubXml(xml).getAllElements().filter { it.epubName() == "cipherreference" }
                .mapNotNull { EpubResourcePaths.resolve("", it.attr("URI").ifBlank { it.attr("uri") }) }
                .toSet()
        }.orEmpty()
    }

    fun entries(): List<String> = entries.keys.toList()

    fun contains(path: String): Boolean = entries.containsKey(path)

    fun read(path: String, maximumBytes: Int = MAX_IMAGE_BYTES): ByteArray? {
        checkCancelled()
        val entry = entries[path] ?: return null
        require(entry.size <= maximumBytes) { "EPUB 资源超过读取限额：$path" }
        require(entry.size <= 1024 * 1024 || entry.size.toLong() <= entry.packed.toLong() * 1000) {
            "EPUB 资源压缩比过高：$path"
        }
        if (path != "META-INF/encryption.xml") {
            require(path !in encryptedPaths) { "不支持 DRM 加密的 EPUB 资源：$path" }
        }
        return archive.read(path)
    }

    fun readText(path: String, maximumBytes: Int = MAX_DOCUMENT_BYTES): String? {
        val data = read(path, maximumBytes) ?: return null
        return decodeEpubText(data)
    }

    companion object {
        const val MAX_PACKAGE_BYTES = 1024 * 1024
        const val MAX_DOCUMENT_BYTES = 8 * 1024 * 1024
        const val MAX_IMAGE_BYTES = 32 * 1024 * 1024
    }
}

private val epubXmlEncoding = Regex("""<\?xml\b[^>]*\bencoding\s*=\s*['"]([^'"]+)['"]""", RegexOption.IGNORE_CASE)

internal fun decodeEpubText(data: ByteArray): String {
    val encoding = when {
        data.size >= 2 && data[0] == 0xff.toByte() && data[1] == 0xfe.toByte() -> "UTF-16LE"
        data.size >= 2 && data[0] == 0xfe.toByte() && data[1] == 0xff.toByte() -> "UTF-16BE"
        data.size >= 2 && data[0] == 0.toByte() && data[1] == '<'.code.toByte() -> "UTF-16BE"
        data.size >= 2 && data[0] == '<'.code.toByte() && data[1] == 0.toByte() -> "UTF-16LE"
        else -> epubXmlEncoding.find(data.decodeToString(0, minOf(data.size, 256)))?.groupValues?.get(1) ?: "UTF-8"
    }
    return TextCodec.decode(data, encoding).removePrefix("\uFEFF")
}

internal fun parseEpubXml(xml: String): Document {
    // EPUBs often have an external XHTML DTD. Ksoup never fetches it; custom entities are rejected.
    require(!xml.contains(Regex("<!ENTITY\\b|<!DOCTYPE[^>]*\\[", RegexOption.IGNORE_CASE))) {
        "EPUB XML 不支持自定义实体"
    }
    val parser = Parser.xmlParser().setTrackErrors(1)
    val document = Ksoup.parse(html = xml, parser = parser)
    require(parser.getErrors().isEmpty() && document.childrenSize() == 1) { "EPUB XML 文档损坏" }
    require(document.textNodes().all { it.getWholeText().isBlank() }) { "EPUB XML 根节点之外存在正文" }
    return document
}

internal fun Element.epubName(): String = tagName().substringAfter(':').lowercase()

internal fun Element.epubChild(name: String): Element? = children().firstOrNull { it.epubName() == name }
