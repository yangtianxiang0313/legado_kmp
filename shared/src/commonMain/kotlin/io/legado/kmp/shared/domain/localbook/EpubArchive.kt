package io.legado.kmp.shared.domain.localbook

import com.fleeksoft.ksoup.Ksoup
import com.fleeksoft.ksoup.nodes.Document
import com.fleeksoft.ksoup.nodes.Element
import com.fleeksoft.ksoup.parser.Parser
import io.legado.kmp.shared.platform.TextCodec

/** Selected, resource-bounded reads from a borrowed archive reader, without extracting files. */
internal class EpubArchive(
    private val archive: EpubArchiveReader,
    private val checkCancelled: () -> Unit,
) {
    private val entries = validatedEntries()
    private val encryptedPaths: Set<String> by lazy {
        readText("META-INF/encryption.xml", MAX_PACKAGE_BYTES)?.let { xml ->
            parseEpubXml(xml).getAllElements().filter { it.epubName() == "cipherreference" }
                .mapNotNull { EpubResourcePaths.resolve("", it.attr("URI").ifBlank { it.attr("uri") }) }
                .toSet()
        }.orEmpty()
    }

    fun entries(): List<String> {
        checkCancelled()
        return entries.keys.toList()
    }

    fun contains(path: String): Boolean {
        checkCancelled()
        return entries.containsKey(path)
    }

    fun read(path: String, maximumBytes: Int = MAX_IMAGE_BYTES): ByteArray? {
        checkCancelled()
        require(maximumBytes >= 0) { "EPUB 资源读取限额无效" }
        val limit = minOf(maximumBytes, MAX_IMAGE_BYTES)
        val entry = entries[path] ?: return null
        require(entry.size <= limit.toLong()) { "EPUB 资源超过读取限额：$path" }
        val packed = entry.packedSize
        require(entry.size <= MAX_PACKAGE_BYTES.toLong() || packed == null || packed >= (entry.size + 999L) / 1000L) {
            "EPUB 资源压缩比过高：$path"
        }
        if (path != "META-INF/encryption.xml") {
            require(path !in encryptedPaths) { "不支持 DRM 加密的 EPUB 资源：$path" }
        }
        val data = archive.read(path, limit)
        checkCancelled()
        require(data.size <= limit && data.size.toLong() == entry.size) { "EPUB 资源实际长度与目录不一致：$path" }
        return data
    }

    fun readText(path: String, maximumBytes: Int = MAX_DOCUMENT_BYTES): String? {
        val data = read(path, minOf(maximumBytes, MAX_DOCUMENT_BYTES)) ?: return null
        return decodeEpubText(data).also { checkCancelled() }
    }

    private fun validatedEntries(): Map<String, EpubArchiveEntry> {
        checkCancelled()
        val listed = archive.entries()
        require(listed.size <= EpubArchiveReadLimits.ENTRIES) { "EPUB 归档项目超过读取限额" }
        val result = linkedMapOf<String, EpubArchiveEntry>()
        val names = mutableSetOf<String>()
        var declared = 0L
        for (entry in listed) {
            checkCancelled()
            BookArchiveZipReader.validatePath(entry.path)
            require(names.add(entry.path.removeSuffix("/").lowercase())) {
                "EPUB 包含重名或大小写冲突的路径：${entry.path}"
            }
            require(entry.size in 0L..(EpubArchiveReadLimits.DECLARED_BYTES - declared)) {
                "EPUB 资源声明长度无效或总量超过读取限额：${entry.path}"
            }
            require(entry.packedSize == null || entry.packedSize >= 0L) { "EPUB 资源压缩长度无效：${entry.path}" }
            declared += entry.size
            if (entry.path.endsWith('/')) {
                require(entry.size == 0L) { "EPUB 目录包含文件数据：${entry.path}" }
            } else {
                result[entry.path] = entry
            }
        }
        checkCancelled()
        return result
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
