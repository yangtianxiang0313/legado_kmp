package io.legado.kmp.shared.domain.localbook

import com.fleeksoft.ksoup.Ksoup
import com.fleeksoft.ksoup.nodes.Node
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter

/** Limits are cumulative, including repeated prefix formatting, not just the final plan size. */
internal class EpubReflowBudget(val checkActive: () -> Unit) {
    private var metadataUnits = 0L
    private var documentUnits = 0L
    private var documentNodes = 0L
    private var formatUnits = 0L
    private var formatNodes = 0L
    private var processedUnits = 0L
    private var canonicalUnits = 0L
    private var retainedOffsets = 0L
    private var formatCalls = 0
    private var processCalls = 0

    fun metadata(book: Book, chapters: List<BookChapter>) {
        require(chapters.size <= MAX_CHAPTERS) { "EPUB 重切章节数量超过 20000" }
        fun add(value: String?) {
            checkActive()
            metadataUnits += value?.length ?: 0
            require(metadataUnits <= 8L * 1024 * 1024) { "EPUB 重切目录元数据超过 8 Mi UTF-16 字符" }
        }
        listOf(book.bookUrl, book.tocUrl, book.origin, book.originName, book.name, book.author,
            book.charset, book.variable, book.config.toJson()).forEach(::add)
        chapters.forEach { chapter ->
            checkActive()
            listOf(chapter.url, chapter.title, chapter.baseUrl, chapter.bookUrl, chapter.resourceUrl,
                chapter.tag, chapter.wordCount, chapter.startFragmentId, chapter.endFragmentId,
                chapter.variable).forEach(::add)
        }
    }

    fun document(length: Int, nodes: Int) {
        checkActive()
        documentUnits += length
        documentNodes += nodes
        require(documentUnits <= 64L * 1024 * 1024 && documentNodes <= 2_000_000) {
            "EPUB 重切涉及的正文超过 64 Mi UTF-16 字符或 2000000 节点"
        }
    }

    fun format(document: EpubReflowDocument) {
        checkActive()
        formatUnits += document.length
        formatNodes += document.nodes
        require(++formatCalls <= 100_000 && formatUnits <= 512L * 1024 * 1024 && formatNodes <= 40_000_000) {
            "EPUB 重切 formatter 累计字符、节点或调用次数超过限额"
        }
    }

    fun beforeProcess(content: String) {
        checkActive()
        text(content)
        processedUnits += content.length
        require(++processCalls <= 100_000 && processedUnits <= 512L * 1024 * 1024) {
            "EPUB 重切正文处理累计字符或调用次数超过限额"
        }
    }

    fun afterProcess(result: EpubReflowText) {
        checkActive()
        text(result.content)
        processedUnits += result.content.length
        metadataUnits += result.displayTitle.length
        require(processedUnits <= 512L * 1024 * 1024 && metadataUnits <= 8L * 1024 * 1024) {
            "EPUB 重切正文处理结果或标题累计字符超过限额"
        }
    }

    fun text(content: String) {
        require(content.length <= MAX_TEXT_UNITS) { "EPUB 重切单次正文超过 32 Mi UTF-16 字符" }
    }

    fun canonical(count: Int) {
        canonicalUnits += count
        require(canonicalUnits <= 16L * 1024 * 1024) { "EPUB 重切 canonical 正文超过 16 Mi UTF-16 字符" }
    }

    fun retain(count: Int) {
        retainedOffsets += count
        require(retainedOffsets <= 32L * 1024 * 1024) { "EPUB 重切位置投影超过 32 Mi UTF-16 索引" }
    }

    companion object {
        const val MAX_CHAPTERS = 20_000
        const val MAX_TEXT_UNITS = 32 * 1024 * 1024
    }
}

internal class EpubReflowDocument(
    val path: String,
    val length: Int,
    val nodes: Int,
    val anchors: Map<String, Int>,
)

internal fun readEpubReflowDocument(
    archive: EpubArchive,
    path: String,
    fragments: Set<String>,
    budget: EpubReflowBudget,
): EpubReflowDocument {
    budget.checkActive()
    val html = requireNotNull(archive.readText(path)) { "EPUB 重切正文文件不存在：$path" }
    val body = Ksoup.parse(html).body()
    val pending = ArrayDeque<Pair<Node, Int>>()
    pending.addLast(body to 0)
    var nodes = 0
    while (pending.isNotEmpty()) {
        budget.checkActive()
        val (node, depth) = pending.removeLast()
        require(++nodes <= 100_000 && depth < 128) { "EPUB 重切正文节点超过 100000 或嵌套超过 128" }
        val children = node.childNodes()
        require(nodes + pending.size + children.size <= 100_000) { "EPUB 重切正文节点超过 100000" }
        children.asReversed().forEach { pending.addLast(it to depth + 1) }
    }
    budget.document(html.length, nodes)
    val positions = EpubDomRange.positions(body, budget.checkActive)
    val anchors = fragments.associateWith { fragment ->
        budget.checkActive()
        requireNotNull(positions[fragment]) { "EPUB 重切锚点不存在或不唯一：$path#$fragment" }
    }
    return EpubReflowDocument(path, html.length, nodes, anchors)
}

internal class EpubReflowCanonicalDocument(
    val content: CharArray,
    val boundaries: Map<Int, Int>,
)

internal suspend fun projectEpubReflowDocument(
    archive: EpubArchive,
    document: EpubReflowDocument,
    current: Book,
    replacement: Book,
    oldContext: BookChapter,
    newContext: BookChapter,
    budget: EpubReflowBudget,
    process: suspend (Book, BookChapter, String, Boolean) -> EpubReflowText,
): EpubReflowCanonicalDocument {
    val html = requireNotNull(archive.readText(document.path)) { "EPUB 重切正文文件不存在" }

    suspend fun project(book: Book, chapter: BookChapter, fragment: String?): CharArray {
        budget.format(document)
        val raw = EpubChapterContent.format(book, document.path, html, endFragmentId = fragment,
            checkActive = budget.checkActive)
        return epubReflowCanonical(epubReflowProcess(book, chapter, raw, false, budget, process).content, budget)
    }

    val full = project(current, oldContext, null)
    val nextFull = project(replacement, newContext, null)
    requireEpubReflowEqual(nextFull, full, 0, full.size, budget, "新旧整文件 canonical 正文不一致")
    budget.canonical(full.size)
    val prefixes = document.anchors.keys.associateWith { fragment ->
        val prefix = project(current, oldContext, fragment)
        requireEpubReflowEqual(prefix, full, 0, prefix.size, budget, "旧锚点 prefix 不是整文件精确前缀")
        val nextPrefix = project(replacement, newContext, fragment)
        requireEpubReflowEqual(nextPrefix, full, 0, prefix.size, budget, "新锚点 prefix 与旧锚点不一致")
        prefix.size
    }
    // DOM order must also be monotone in canonical space, including hidden/removed anchors.
    var last = 0
    document.anchors.entries.sortedBy { it.value }.forEach { (fragment, _) ->
        budget.checkActive()
        val position = prefixes.getValue(fragment)
        require(position >= last) { "EPUB 重切锚点投影不保持物理顺序" }
        last = position
    }
    val boundaries = mutableMapOf(0 to 0)
    document.anchors.forEach { (fragment, order) ->
        val position = prefixes.getValue(fragment)
        val previous = boundaries.put(order, position)
        require(previous == null || previous == position) { "EPUB 同一 DOM 边界的 canonical 投影不唯一" }
    }
    return EpubReflowCanonicalDocument(full, boundaries)
}

internal suspend fun epubReflowProcess(
    book: Book,
    chapter: BookChapter,
    raw: String,
    actual: Boolean,
    budget: EpubReflowBudget,
    process: suspend (Book, BookChapter, String, Boolean) -> EpubReflowText,
): EpubReflowText {
    budget.beforeProcess(raw)
    val result = process(book, chapter, raw, actual)
    budget.afterProcess(result)
    return result
}

internal fun epubReflowCanonical(content: String, budget: EpubReflowBudget): CharArray {
    val count = countEpubReflowCharacters(content, budget)
    val result = CharArray(count)
    var offset = 0
    content.forEachIndexed { index, char ->
        if (index and 2047 == 0) budget.checkActive()
        if (!char.isWhitespace()) result[offset++] = char
    }
    return result
}

internal fun countEpubReflowCharacters(content: String, budget: EpubReflowBudget): Int {
    budget.text(content)
    var count = 0
    content.forEachIndexed { index, char ->
        if (index and 2047 == 0) budget.checkActive()
        if (!char.isWhitespace()) count++
    }
    return count
}

internal fun requireEpubReflowEqual(
    actual: CharArray,
    expected: CharArray,
    start: Int,
    end: Int,
    budget: EpubReflowBudget,
    description: String,
) {
    require(start >= 0 && end >= start && end <= expected.size && actual.size == end - start) {
        "EPUB 重切无法证明：$description（字符数量不同）；已保留原目录与进度"
    }
    actual.indices.forEach { index ->
        if (index and 2047 == 0) budget.checkActive()
        require(actual[index] == expected[start + index]) {
            "EPUB 重切无法证明：$description（字符顺序不同）；已保留原目录与进度"
        }
    }
}

internal fun epubReflowOffsets(
    content: String,
    expected: CharArray,
    start: Int,
    end: Int,
    budget: EpubReflowBudget,
): EpubReflowProjection {
    val count = countEpubReflowCharacters(content, budget)
    require(count <= end - start) { "EPUB 重切实际正文增加了 canonical 字符" }
    val visibleStart = end - count
    budget.retain(count)
    val offsets = IntArray(count)
    var ordinal = 0
    content.forEachIndexed { index, char ->
        if (index and 2047 == 0) budget.checkActive()
        if (!char.isWhitespace()) {
            require(char == expected[visibleStart + ordinal]) {
                "EPUB 重切实际正文不是原范围的精确后缀，无法证明仅删除了重复标题"
            }
            offsets[ordinal++] = index
        }
    }
    return EpubReflowProjection(visibleStart, content.length, offsets)
}
