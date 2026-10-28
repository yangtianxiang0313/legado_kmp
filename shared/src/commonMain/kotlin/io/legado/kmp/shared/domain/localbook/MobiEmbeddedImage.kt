package io.legado.kmp.shared.domain.localbook

import com.fleeksoft.ksoup.nodes.Element

/** Resource identities are always relative to this book's PDB resource section. */
internal object MobiEmbeddedImage {
    fun toUrl(index: Int): String {
        require(index >= 0) { "MOBI 图片索引无效" }
        return MobiImageResource(index, false, null).url
    }

    fun reference(value: String): String? = MobiFlowResources.resource(value)?.url

    fun formatImages(root: Element, flows: MobiFlowResources? = null, checkActive: () -> Unit = {}) {
        val budget = MobiFlowResources.Budget(checkActive)
        val pending = ArrayDeque<Element>()
        pending.addLast(root)
        while (pending.isNotEmpty()) {
            checkActive()
            val element = pending.removeLast()
            if (MobiHtmlSupport.isHidden(element)) {
                element.remove()
                continue
            }
            val name = element.epubName()
            val sources = when (name) {
                "svg" -> listOf(LocalBookSvg.toDataUrl(LocalBookSvg.serialize(element).encodeToByteArray()))
                "img", "image", "object" -> {
                    val raw = if (element.hasAttr("recindex")) "recindex:" + element.attr("recindex")
                        else EpubEmbeddedImage.reference(element)
                    val resource = MobiFlowResources.resource(raw)
                    val dataType = MobiFlowResources.dataMime(raw)
                    if (resource == null && !MobiFlowResources.isImageMime(dataType)) {
                        // Unsupported URLs/empty src must not make an otherwise readable chapter fail.
                        if (name == "object") null else emptyList()
                    } else {
                        val declared = element.attr("type").takeIf { it.isNotBlank() }?.let { MobiFlowResources.mime(it) }
                        val type = MobiFlowResources.combineMime(resource?.mime ?: dataType, declared)
                        if (name == "object" && type?.startsWith("image/") == false) {
                            // Keep fallback children, but never insert CSS/JS flow bytes as prose.
                            null
                        } else MobiFlowResources.imageSources(raw, flows, checkActive, budget, declared)
                    }
                }
                else -> null
            }
            if (sources == null) {
                element.children().reversed().forEach(pending::addLast)
            } else {
                val alt = element.attr("alt").takeIf { it.isNotBlank() }
                sources.forEach { source ->
                    val image = Element("img").attr("src", source)
                    alt?.let { image.attr("alt", it) }
                    element.before(image)
                }
                element.remove()
            }
        }
    }

    fun read(
        records: MobiRecordReader,
        header: MobiHeader,
        imageUrl: String,
        checkActive: () -> Unit,
        flows: MobiFlowResources? = null,
        visited: Set<String> = emptySet(),
        budget: MobiFlowResources.Budget = MobiFlowResources.Budget(checkActive),
    ): ByteArray? {
        checkActive()
        val input = imageUrl.trim()
        val resource = MobiFlowResources.resource(input)
        val type = resource?.mime ?: MobiFlowResources.dataMime(input)
        if (resource == null && !MobiFlowResources.isImageMime(type)) return null
        MobiFlowResources.requireImageMime(type)
        val identity = resource?.identity ?: input
        budget.visit(identity, visited)
        val bytes = when {
            resource == null -> MobiFlowResources.readData(input, checkActive)
            resource.isFlow -> requireNotNull(flows) { "KF8 图片缺少辅助流数据" }.read(resource.index)
            else -> {
                val base = requireNotNull(header.resourceRecord) { "MOBI 图片缺少资源记录区" }
                val absolute = base.toLong() + resource.index
                require(base > 0 && absolute < records.recordCount &&
                    absolute !in header.recordIndex.toLong()..(header.recordIndex + header.textRecordCount).toLong()) {
                    "MOBI 图片记录越界"
                }
                records.record(absolute.toInt(), MobiFlowResources.MAX_IMAGE_BYTES)
            }
        }
        budget.consume(bytes.size)
        if (!MobiFlowResources.isSvg(bytes, type)) return bytes.also { checkActive() }
        val encoding = if (resource?.isFlow == true) requireNotNull(flows).encoding else MobiTextEncoding.UTF8
        require(bytes.size <= MobiFlowResources.MAX_SVG_BYTES) { "MOBI SVG 超过 8 MiB" }
        return LocalBookSvg.prepare(
            xml = encoding.decode(bytes),
            resolveImage = { source ->
                read(records, header, source, checkActive, flows, visited + identity, budget)
            },
            checkActive = checkActive,
        )
    }
}
