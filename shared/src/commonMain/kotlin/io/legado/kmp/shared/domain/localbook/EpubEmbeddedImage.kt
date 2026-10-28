package io.legado.kmp.shared.domain.localbook

import com.fleeksoft.ksoup.nodes.Element
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi

internal object EpubEmbeddedImage {
    private val bitmapTypes = setOf("image/png", "image/jpeg", "image/jpg", "image/gif", "image/webp", "image/bmp", "image/heic", "image/avif")
    private const val MAX_DATA_IMAGE_BYTES = 8 * 1024 * 1024

    fun isImagePath(path: String): Boolean = path.substringBefore('#').substringBefore('?').substringAfterLast('.').lowercase() in
        setOf("png", "jpg", "jpeg", "gif", "webp", "bmp", "heic", "avif", "svg")

    fun reference(element: Element): String = when (element.epubName()) {
        "image" -> element.attr("xlink:href").ifBlank { element.attr("href") }
        "object" -> element.attr("data")
        else -> element.attr("src").ifBlank { element.attr("data-src") }
    }.trim()

    fun read(
        archive: EpubArchive,
        path: String,
        visited: Set<String> = emptySet(),
        checkActive: () -> Unit = {},
    ): ByteArray? = read(archive, path, visited, checkActive, ResourceBudget())

    fun prepareSvg(
        archive: EpubArchive,
        path: String,
        xml: String,
        checkActive: () -> Unit = {},
    ): ByteArray = prepareSvg(archive, path, xml, setOf(path), checkActive, ResourceBudget())

    private fun read(
        archive: EpubArchive,
        path: String,
        visited: Set<String>,
        checkActive: () -> Unit,
        budget: ResourceBudget,
    ): ByteArray? {
        checkActive()
        require(path !in visited && visited.size < 8) { "EPUB 图片存在循环引用或包装层级过深" }
        require(++budget.references <= 4096) { "EPUB SVG 图片引用超过 4096 项" }
        val bytes = archive.read(path, if (path.endsWith(".svg", true)) EpubArchive.MAX_DOCUMENT_BYTES
            else EpubArchive.MAX_IMAGE_BYTES) ?: return null
        budget.bytes += bytes.size
        require(budget.bytes <= 64L * 1024 * 1024) { "EPUB SVG 图片读取总量超过 64 MiB" }
        if (!path.endsWith(".svg", true) && !LocalBookSvg.isSvg(bytes)) return bytes
        require(bytes.size <= EpubArchive.MAX_DOCUMENT_BYTES) { "EPUB SVG 文档超过 8 MiB" }
        return prepareSvg(archive, path, decodeEpubText(bytes), visited + path, checkActive, budget)
    }

    private fun prepareSvg(
        archive: EpubArchive,
        path: String,
        xml: String,
        visited: Set<String>,
        checkActive: () -> Unit,
        budget: ResourceBudget,
    ): ByteArray = LocalBookSvg.prepare(
        xml,
        resolveImage = { reference ->
            checkActive()
            val target = EpubResourcePaths.resolve(path.substringBeforeLast('/', ""), reference)
                ?: error("EPUB SVG 图片不是本地归档资源：$reference")
            read(archive, target, visited, checkActive, budget)
        },
        checkActive = checkActive,
    )

    private class ResourceBudget(var references: Int = 0, var bytes: Long = 0)

    fun isSvgDataUrl(reference: String): Boolean = reference.startsWith("data:", true) &&
        reference.substringBefore(',').substringBefore(';').equals("data:image/svg+xml", true)

    fun prepareDataImage(reference: String, checkActive: () -> Unit = {}): ByteArray? {
        val bytes = readDataUrl(reference, checkActive) ?: return null
        if (!isSvgDataUrl(reference) && !LocalBookSvg.isSvg(bytes)) return bytes
        // Generated inline SVG data is self-contained; unresolved relative resources must fail as images.
        return LocalBookSvg.prepare(decodeEpubText(bytes), resolveImage = { null }, checkActive = checkActive)
    }

    @OptIn(ExperimentalEncodingApi::class)
    fun readDataUrl(reference: String, checkActive: () -> Unit = {}): ByteArray? {
        if (!reference.startsWith("data:", true)) return null
        if (isSvgDataUrl(reference)) return LocalBookSvg.readDataUrl(reference, checkActive)
        val comma = reference.indexOf(',')
        require(comma in 1..256) { "EPUB 内嵌图片数据头无效" }
        val header = reference.substring(5, comma).lowercase()
        val parts = header.split(';')
        if (parts.first() !in bitmapTypes || parts.drop(1) != listOf("base64")) return null
        val content = reference.substring(comma + 1)
        require(content.length <= (MAX_DATA_IMAGE_BYTES.toLong() + 2) / 3 * 4) { "EPUB 内嵌图片超过 8 MiB" }
        val encoded = buildString(content.length) {
            content.forEachIndexed { index, char ->
                if (index and 0x3fff == 0) checkActive()
                if (char !in " \r\n\t") append(char)
            }
        }
        return Base64.decode(encoded).also {
            checkActive()
            require(it.isNotEmpty() && it.size <= MAX_DATA_IMAGE_BYTES) { "EPUB 内嵌图片为空或超过 8 MiB" }
        }
    }
}
