package io.legado.kmp.shared.domain.localbook

import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi

/** FDST indices are identities, not positions in a filtered list of image flows. */
internal class MobiFlowResources(
    flows: List<MobiKf8Flow>,
    val encoding: MobiTextEncoding,
    checkActive: () -> Unit,
) {
    private val byIndex: Map<Int, ByteArray> = buildMap {
        require(flows.size < 4096) { "KF8 辅助流数量超过限制" }
        var total = 0L
        flows.forEach { flow ->
            checkActive()
            require(flow.index in 1 until 4096 && !containsKey(flow.index)) { "KF8 辅助流编号无效或重复" }
            total += flow.bytes.size
            require(total <= MAX_TEXT_BYTES) { "KF8 辅助流总量超过 64 MiB" }
            put(flow.index, flow.bytes)
        }
    }

    fun read(index: Int): ByteArray = requireNotNull(byIndex[index]) { "KF8 图片引用了不存在的辅助流：$index" }

    class Budget(private val checkActive: () -> Unit) {
        private var references = 0
        private var bytes = 0L

        fun visit(identity: String, visited: Set<String>) {
            checkActive()
            require(identity !in visited && visited.size < 8) { "MOBI 图片包装存在循环或层级过深" }
            require(++references <= 4096) { "MOBI 图片引用展开超过 4096 项" }
        }

        fun consume(size: Int) {
            checkActive()
            bytes += size
            require(bytes <= MAX_TEXT_BYTES) { "MOBI 图片包装展开总量超过 64 MiB" }
        }
    }

    companion object {
        const val RESOURCE_PREFIX = "mobi-resource:///"
        const val MAX_IMAGE_BYTES = 16 * 1024 * 1024
        const val MAX_SVG_BYTES = 8 * 1024 * 1024
        private const val MAX_DATA_BYTES = 8 * 1024 * 1024
        private val kindle = Regex(
            "kindle:(flow|embed):([0-9a-v]+)(?:\\?mime=([a-z0-9.+-]+/[a-z0-9.+-]+))?",
            RegexOption.IGNORE_CASE,
        )
        private val local = Regex("mobi-resource:///([0-9]+)(?:\\?mime=([a-z0-9.+-]+/[a-z0-9.+-]+))?", RegexOption.IGNORE_CASE)
        private val recindex = Regex("recindex:([0-9]+)", RegexOption.IGNORE_CASE)
        private val mimePattern = Regex("[a-z0-9.+-]+/[a-z0-9.+-]+")
        private val bitmapTypes = setOf(
            "image/png", "image/jpeg", "image/gif", "image/webp", "image/bmp", "image/heic", "image/heif",
            "image/avif", "image/tiff", "image/x-icon",
        )

        fun mime(value: String): String = when (val type = value.trim().lowercase()) {
            "image/jpg", "image/pjpeg" -> "image/jpeg"
            "image/x-png" -> "image/png"
            "image/x-ms-bmp" -> "image/bmp"
            "image/vnd.microsoft.icon" -> "image/x-icon"
            else -> type.also { require(mimePattern.matches(it)) { "MOBI 资源 MIME 无效" } }
        }

        fun isImageMime(type: String?): Boolean = type != null && (type == "image/svg+xml" || type in bitmapTypes)

        fun requireImageMime(type: String?) {
            require(type == null || isImageMime(type)) {
                "MOBI 图片引用了非图片或不支持的 MIME：$type"
            }
        }

        fun combineMime(first: String?, second: String?): String? {
            require(first == null || second == null || first == second) { "MOBI 图片声明的 MIME 不一致" }
            return first ?: second
        }

        fun resource(value: String): MobiImageResource? {
            val input = value.trim()
            if (!input.startsWith(RESOURCE_PREFIX, true) && !input.startsWith("recindex:", true) &&
                !input.startsWith("kindle:flow:", true) && !input.startsWith("kindle:embed:", true)) return null
            require(input.length <= 256) { "MOBI 图片引用过长" }
            local.matchEntire(input)?.let { match ->
                val index = requireNotNull(match.groupValues[1].toIntOrNull()) { "MOBI 图片索引越界" }
                return MobiImageResource(index, false, match.groupValues[2].takeIf { it.isNotEmpty() }?.let(::mime))
            }
            recindex.matchEntire(input)?.let { match ->
                val index = requireNotNull(match.groupValues[1].toIntOrNull()) { "MOBI 图片索引越界" }
                require(index > 0) { "MOBI 图片索引无效" }
                return MobiImageResource(index - 1, false, null)
            }
            val match = requireNotNull(kindle.matchEntire(input)) { "MOBI 图片资源引用无效" }
            val index = requireNotNull(match.groupValues[2].toIntOrNull(32)) { "MOBI 图片索引越界" }
            require(index > 0) { "MOBI 图片索引无效" }
            val isFlow = match.groupValues[1].equals("flow", true)
            return MobiImageResource(
                if (isFlow) index else index - 1,
                isFlow,
                match.groupValues[3].takeIf { it.isNotEmpty() }?.let(::mime),
            )
        }

        fun dataMime(value: String): String? {
            if (!value.startsWith("data:", true)) return null
            val comma = value.indexOf(',')
            require(comma in 5..256) { "MOBI 内嵌图片数据头无效" }
            val type = value.substring(5, comma).substringBefore(';').trim().lowercase()
            if (!mimePattern.matches(type)) return null
            return mime(type)
        }

        @OptIn(ExperimentalEncodingApi::class)
        fun readData(value: String, checkActive: () -> Unit): ByteArray {
            val type = requireNotNull(dataMime(value)) { "MOBI 内嵌图片地址无效" }
            requireImageMime(type)
            val comma = value.indexOf(',')
            val options = value.substring(5, comma).lowercase().split(';').drop(1)
            val base64 = options.lastOrNull() == "base64"
            require(options.filterNot { it == "base64" }.let {
                it.isEmpty() || type == "image/svg+xml" && it == listOf("charset=utf-8")
            } && options.count { it == "base64" } <= 1 && ("base64" !in options || base64)) {
                "MOBI 内嵌图片数据参数不支持"
            }
            checkActive()
            val length = value.length - comma - 1
            val bytes = if (base64) {
                require(length <= (MAX_DATA_BYTES.toLong() + 2) / 3 * 4) { "MOBI 内嵌图片超过 8 MiB" }
                val content = buildString(length) {
                    for (index in comma + 1 until value.length) {
                        if (index and 0x3fff == 0) checkActive()
                        val char = value[index]
                        if (char !in " \t\r\n") append(char)
                    }
                }
                Base64.decode(content)
            } else {
                require(type == "image/svg+xml") { "MOBI 位图 data 地址必须使用 base64" }
                require(length <= MAX_DATA_BYTES * 3) { "MOBI 内嵌 SVG 超过 8 MiB" }
                val output = ByteArray(minOf(length.toLong() * 3, MAX_DATA_BYTES.toLong()).toInt())
                var written = 0
                var cursor = comma + 1
                while (cursor < value.length) {
                    checkActive()
                    if (value[cursor] == '%') {
                        require(cursor + 2 < value.length && written < output.size) { "MOBI SVG data 编码无效或过大" }
                        val high = value[cursor + 1].digitToIntOrNull(16)
                        val low = value[cursor + 2].digitToIntOrNull(16)
                        require(high != null && low != null) { "MOBI SVG data 百分号编码无效" }
                        output[written++] = ((high shl 4) or low).toByte()
                        cursor += 3
                    } else {
                        val end = value.indexOf('%', cursor).takeIf { it >= 0 } ?: value.length
                        val part = value.substring(cursor, end).encodeToByteArray()
                        require(part.size <= output.size - written) { "MOBI 内嵌 SVG 超过 8 MiB" }
                        part.copyInto(output, written)
                        written += part.size
                        cursor = end
                    }
                }
                output.copyOf(written)
            }
            checkActive()
            require(bytes.isNotEmpty() && bytes.size <= MAX_DATA_BYTES) { "MOBI 内嵌图片为空或超过 8 MiB" }
            return bytes
        }

        fun isSvg(bytes: ByteArray, declaredMime: String?): Boolean {
            requireImageMime(declaredMime)
            require(bytes.isNotEmpty() && bytes.size <= MAX_IMAGE_BYTES) { "MOBI 图片为空或超过 16 MiB" }
            val actual = bitmapMime(bytes)
            if (actual == null) {
                require(declaredMime == null || declaredMime == "image/svg+xml") { "MOBI 位图数据与 MIME 不符" }
                require(bytes.size <= MAX_SVG_BYTES) { "MOBI SVG 包装超过 8 MiB" }
                return true
            }
            require(declaredMime == null || declaredMime == actual ||
                declaredMime in setOf("image/heic", "image/heif") && actual == "image/heic") {
                "MOBI 图片数据与 MIME 不符：$declaredMime / $actual"
            }
            return false
        }

        fun imageSources(
            value: String,
            flows: MobiFlowResources?,
            checkActive: () -> Unit,
            budget: Budget,
            declaredMime: String? = null,
            visited: Set<String> = emptySet(),
        ): List<String> {
            val input = value.trim()
            val resource = resource(input)
            val dataType = dataMime(input)
            if (resource == null && !isImageMime(dataType)) return emptyList()
            val type = combineMime(resource?.mime ?: dataType, declaredMime)
            requireImageMime(type)
            val identity = resource?.identity ?: input
            budget.visit(identity, visited)
            if (resource != null && (!resource.isFlow || flows == null)) return listOf(resource.copy(mime = type).url)
            val bytes = if (resource != null) requireNotNull(flows).read(resource.index) else readData(input, checkActive)
            budget.consume(bytes.size)
            // Composite SVGs remain one image; resolving all resources happens with the record reader.
            isSvg(bytes, type)
            return listOf(resource?.copy(mime = type)?.url ?: input)
        }

        private fun bitmapMime(bytes: ByteArray): String? {
            fun matches(vararg magic: Int): Boolean = bytes.size >= magic.size &&
                magic.indices.all { (bytes[it].toInt() and 0xff) == magic[it] }
            return when {
                matches(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a) -> "image/png"
                matches(0xff, 0xd8, 0xff) -> "image/jpeg"
                bytes.size >= 6 && bytes.mobiAscii(0, 6) in setOf("GIF87a", "GIF89a") -> "image/gif"
                bytes.size >= 12 && bytes.mobiAscii(0, 4) == "RIFF" && bytes.mobiAscii(8, 4) == "WEBP" -> "image/webp"
                matches(0x42, 0x4d) -> "image/bmp"
                matches(0x49, 0x49, 0x2a, 0) || matches(0x4d, 0x4d, 0, 0x2a) -> "image/tiff"
                matches(0, 0, 1, 0) -> "image/x-icon"
                bytes.size >= 12 && bytes.mobiAscii(4, 4) == "ftyp" -> when (bytes.mobiAscii(8, 4)) {
                    "avif", "avis" -> "image/avif"
                    "heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1" -> "image/heic"
                    else -> null
                }
                else -> null
            }
        }
    }
}

internal data class MobiImageResource(val index: Int, val isFlow: Boolean, val mime: String?) {
    val identity: String get() = if (isFlow) "flow:$index" else "embed:$index"
    val url: String get() = (if (isFlow) "kindle:flow:${index.toString(32)}" else MobiFlowResources.RESOURCE_PREFIX + index) +
        (mime?.let { "?mime=$it" } ?: "")
}
