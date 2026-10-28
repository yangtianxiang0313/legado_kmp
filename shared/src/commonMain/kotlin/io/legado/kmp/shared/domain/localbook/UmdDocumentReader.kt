package io.legado.kmp.shared.domain.localbook

import okio.Buffer

internal data class UmdDocument(
    val metadata: Map<String, String>,
    val chapters: List<UmdChapter>,
    val textByteCount: Int,
    val coverBytes: ByteArray?,
    val coverMediaType: String?,
)

internal data class UmdChapter(val title: String, val start: Int, val end: Int, val content: String)

/** UmdReader's # section / $ additional-section state machine, without unchecked stream reads. */
internal class UmdDocumentReader(
    private val bytes: ByteArray,
    private val charset: String,
    private val checkActive: () -> Unit,
) {
    private val reader = UmdBinaryReader(bytes)
    private val metadata = linkedMapOf<String, String>()
    private val offsets = mutableListOf<Int>()
    private val titles = mutableListOf<String>()
    private val content = Buffer()
    private val contentKeys = mutableSetOf<Int>()
    private var contentIndex: List<Int>? = null
    private var additionalKey = 0
    private var declaredContentBytes: Int? = null
    private var sawHeader = false
    private var sawEnd = false
    private var sawOffsets = false
    private var sawTitles = false
    private var coverBytes: ByteArray? = null
    private var coverMediaType: String? = null
    private var sections = 0

    fun read(): UmdDocument {
        checkActive()
        require(bytes.size in 4..UmdLimits.MAX_FILE_BYTES) { "UMD 为空、损坏或超过 64 MiB" }
        require(reader.intLe() == 0xde9a9b89.toInt()) { "UMD 文件魔数无效" }
        var previousType = -1
        while (!reader.exhausted) {
            nextSection()
            require(reader.byte() == '#'.code) { "UMD 段标记无效，偏移 ${reader.position - 1}" }
            val type = reader.shortLe()
            val flags = reader.byte()
            val length = reader.byte()
            require(length >= 5) { "UMD 段长度小于段头" }
            if (flags !in 0..1) throw UnsupportedOperationException("UMD 不支持加密或扩展段标志：$flags")
            require(sawHeader || type == 1) { "UMD 缺少类型头" }
            val payload = reader.section(length - 5)
            readSection(type, payload)
            payload.requireExhausted("0x${type.toString(16)} 段")
            // Android retains the preceding additional-section type across CONTENT ID and licence separators.
            val effectiveType = if (type == 0xf1 || type == 0x0a) previousType else type
            while (!reader.exhausted && reader.peekByte() == '$'.code) {
                nextSection()
                require(!sawEnd && effectiveType >= 0) { "UMD 附加段位置无效" }
                reader.byte()
                val key = reader.intLe()
                val totalLength = reader.uintLe()
                require(totalLength in 9L..UmdLimits.MAX_FILE_BYTES.toLong()) { "UMD 附加段长度无效" }
                val additional = reader.section((totalLength - 9).toInt())
                readAdditional(effectiveType, key, additional)
                additional.requireExhausted("0x${effectiveType.toString(16)} 附加段")
            }
            previousType = effectiveType
            if (sawEnd) {
                reader.requireExhausted("结束标记之后")
                break
            }
        }
        return finish()
    }

    private fun nextSection() {
        checkActive()
        sections++
        require(sections <= UmdLimits.MAX_SECTIONS) { "UMD 段数量超过限额" }
    }

    private fun readSection(type: Int, payload: UmdBinaryReader) {
        when (type) {
            1 -> {
                require(!sawHeader) { "UMD 类型头重复" }
                payload.requireSize(3, "类型头")
                val bookType = payload.byte()
                if (bookType != 1) throw UnsupportedOperationException(
                    if (bookType == 2) "UMD 暂不支持图片类型，仅支持文本 UMD" else "UMD 不支持此书籍类型：$bookType"
                )
                payload.shortLe()
                metadata["umdType"] = bookType.toString()
                sawHeader = true
            }
            in 2..9 -> {
                val key = when (type) {
                    2 -> "title"
                    3 -> "author"
                    4 -> "year"
                    5 -> "month"
                    6 -> "day"
                    7 -> "kind"
                    8 -> "publisher"
                    else -> "retailer"
                }
                require(key !in metadata) { "UMD 元数据字段重复：$key" }
                val value = decodeUmdText(payload.bytes, payload.start, payload.end, charset, checkActive)
                require('\u0000' !in value) { "UMD 元数据包含无效空字符：$key" }
                metadata[key] = value
                payload.skipRemaining()
            }
            0x0b -> {
                require(declaredContentBytes == null) { "UMD 正文长度段重复" }
                payload.requireSize(4, "正文长度")
                val length = payload.uintLe()
                require(length in 1L..UmdLimits.MAX_TEXT_BYTES.toLong()) { "UMD 声明正文为空或超过 64 MiB" }
                declaredContentBytes = length.toInt()
            }
            0x0c -> {
                payload.requireSize(4, "文件结束")
                require(payload.uintLe() == bytes.size.toLong()) { "UMD 文件长度与结束段声明不一致" }
                sawEnd = true
            }
            0x81, 0x83, 0x84 -> {
                payload.requireSize(4, "附加段引用")
                additionalKey = payload.intLe()
            }
            0x82 -> {
                payload.requireSize(5, "封面引用")
                val format = payload.byte()
                if (format != 1) throw UnsupportedOperationException("UMD 不支持此封面类型：$format")
                additionalKey = payload.intLe()
            }
            0x87 -> {
                payload.requireSize(6, "页面偏移引用")
                payload.skipRemaining()
            }
            0xf0 -> throw UnsupportedOperationException("UMD 包含 CDS/DRM 密钥，不支持加密书籍")
            0xf1 -> {
                payload.requireSize(16, "许可证")
                repeat(16) {
                    if (payload.byte() != 0) throw UnsupportedOperationException("UMD 包含非空 DRM 许可证，不支持加密书籍")
                }
            }
            else -> payload.skipRemaining()
        }
    }

    private fun readAdditional(type: Int, key: Int, payload: UmdBinaryReader) {
        when (type) {
            0x81 -> {
                require(key == additionalKey) { "UMD 正文块索引引用不匹配" }
                require(contentIndex == null && payload.size % 4 == 0 &&
                    payload.size / 4 <= UmdLimits.MAX_CONTENT_BLOCKS) { "UMD 正文块索引损坏或重复" }
                contentIndex = List(payload.size / 4) {
                    checkActive()
                    payload.intLe()
                }
            }
            0x82 -> readCover(key, payload)
            0x83 -> readOffsets(key, payload)
            0x84 -> {
                if (key == additionalKey) {
                    readTitles(payload)
                } else {
                    val declared = declaredContentBytes ?: error("UMD 正文块之前缺少正文长度")
                    require(contentKeys.size < UmdLimits.MAX_CONTENT_BLOCKS && contentKeys.add(key)) {
                        "UMD 正文压缩块重复或超过 65536 块"
                    }
                    val remaining = declared.toLong() - content.size
                    require(remaining >= 0) { "UMD 实际正文超过声明长度" }
                    content.write(inflateUmdZlib(payload, minOf(UmdLimits.MAX_BLOCK_BYTES.toLong(), remaining).toInt(), checkActive))
                }
            }
            else -> payload.skipRemaining()
        }
    }

    private fun readOffsets(key: Int, payload: UmdBinaryReader) {
        require(key == additionalKey) { "UMD 章节偏移引用不匹配" }
        require(!sawOffsets && payload.size % 4 == 0 && payload.size / 4 in 1..UmdLimits.MAX_CHAPTERS) {
            "UMD 章节偏移表损坏、重复或超过 100000 章"
        }
        repeat(payload.size / 4) {
            checkActive()
            val offset = payload.uintLe()
            require(offset <= UmdLimits.MAX_TEXT_BYTES.toLong()) { "UMD 章节偏移超过 64 MiB" }
            offsets += offset.toInt()
        }
        sawOffsets = true
    }

    private fun readTitles(payload: UmdBinaryReader) {
        require(sawOffsets && !sawTitles) { "UMD 标题表重复或缺少章节偏移表" }
        repeat(offsets.size) {
            checkActive()
            val title = payload.section(payload.byte())
            titles += decodeUmdText(title.bytes, title.start, title.end, charset, checkActive).also {
                require('\u0000' !in it) { "UMD 章节标题包含无效空字符" }
            }
        }
        payload.requireExhausted("章节标题表")
        sawTitles = true
    }

    private fun readCover(key: Int, payload: UmdBinaryReader) {
        require(key == additionalKey && coverBytes == null) { "UMD 封面引用不匹配或封面重复" }
        require(payload.size in 3..UmdLimits.MAX_COVER_BYTES) { "UMD 封面损坏或超过 8 MiB" }
        val start = payload.start
        fun byte(index: Int) = payload.bytes[start + index].toInt() and 255
        coverMediaType = when {
            byte(0) == 255 && byte(1) == 216 && byte(2) == 255 -> "image/jpeg"
            payload.size >= 8 && byte(0) == 137 && byte(1) == 80 && byte(2) == 78 && byte(3) == 71 &&
                byte(4) == 13 && byte(5) == 10 && byte(6) == 26 && byte(7) == 10 -> "image/png"
            else -> throw UnsupportedOperationException("UMD 封面不是受支持的 JPEG/PNG 图片")
        }
        coverBytes = payload.copyBytes()
        payload.skipRemaining()
    }

    private fun finish(): UmdDocument {
        checkActive()
        require(sawHeader && sawEnd) { "UMD 文件缺少类型头或结束段" }
        require(sawOffsets && sawTitles && offsets.size == titles.size) { "UMD 章节偏移和标题表不完整" }
        val declared = declaredContentBytes ?: error("UMD 缺少正文长度")
        require(contentKeys.isNotEmpty() && content.size == declared.toLong()) { "UMD 实际正文长度与声明不一致" }
        contentIndex?.let { index ->
            require(index.size == contentKeys.size && index.toSet() == contentKeys) { "UMD 正文块索引与实际正文不一致" }
        }
        require(offsets.first() == 0) { "UMD 首章必须从正文偏移 0 开始" }
        val body = content.readByteArray()
        val encoding = umdTextEncoding(body, 0, body.size, charset)
        var charCount = 0L
        val chapters = offsets.mapIndexed { index, start ->
            checkActive()
            val end = offsets.getOrNull(index + 1) ?: body.size
            require(start >= 0 && end >= start && end <= body.size) { "UMD 章节偏移逆序或越界：$index" }
            require(end - start <= UmdLimits.MAX_CHAPTER_BYTES) { "UMD 单章正文超过 8 MiB：$index" }
            if (encoding.name == "UTF-16LE" || encoding.name == "UTF-16BE") {
                require(start and 1 == 0 && end and 1 == 0) { "UMD UTF-16 章节偏移必须为偶数：$index" }
            }
            require((start == 0 || start >= encoding.bomBytes) && (end == 0 || end >= encoding.bomBytes)) {
                "UMD 章节偏移截断编码标记：$index"
            }
            val from = if (start == 0) minOf(encoding.bomBytes, end) else start
            val text = decodeUmdText(body, from, end, encoding.name, checkActive, detectBom = false)
                .replace('\u2029', '\n')
            charCount += text.length
            require(charCount <= UmdLimits.MAX_TEXT_CHARS.toLong()) { "UMD 解码正文超过 32 Mi 字符" }
            UmdChapter(titles[index], start, end, text)
        }
        metadata["charset"] = charset
        metadata["contentCharset"] = encoding.name
        checkActive()
        return UmdDocument(metadata.toMap(), chapters, declared, coverBytes, coverMediaType)
    }
}
