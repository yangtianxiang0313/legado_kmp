package io.legado.kmp.shared.domain.localbook

import com.fleeksoft.ksoup.Ksoup
import io.ktor.http.encodeURLPathPart
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.serializeVariableMap

/** Navigation labels are display order; content boundaries are always physical spine order. */
internal class EpubChapterCatalog(
    private val archive: EpubArchive,
    private val publication: EpubPackage,
    private val checkActive: () -> Unit,
) {
    private data class Target(val path: String, val fragment: String?, val order: Int)
    private data class DocumentInfo(val title: String, val positions: Map<String, Int>)
    private val documents = mutableMapOf<String, DocumentInfo>()
    private val spine by lazy { publication.spinePaths() }
    private val spineSet by lazy { spine.toSet() }

    fun chapters(book: Book): List<BookChapter> {
        val spineIndices = spine.withIndex().associate { it.value to it.index }
        val entries = publication.navigationEntries()
        val canonical = mutableMapOf<Pair<String, Int>, Target>()
        val targets = entries.map { entry ->
            checkActive()
            entry.path?.let { path ->
                val fragment = entry.fragment
                val order = if (fragment == null) -1 else info(path).positions[fragment]
                order?.let {
                    val normalizedOrder = if (order == 0) -1 else order
                    canonical.getOrPut(path to normalizedOrder) { Target(path, fragment.takeUnless { order == 0 }, normalizedOrder) }
                }
            }
        }
        val physical = targets.filterNotNull().filter { it.path in spineIndices }.distinct()
            .sortedWith(compareBy({ spineIndices.getValue(it.path) }, { it.order }))
        if (physical.isEmpty()) return spine.mapIndexed { index, path ->
            chapter(book, Target(path, null, -1), null, info(path).title, index, 0, singleFile = true)
        }

        val first = physical.first()
        val prefix = spine.take(spineIndices.getValue(first.path)).map { Target(it, null, -1) }.toMutableList()
        if (first.fragment != null) {
            val html = requireNotNull(archive.readText(first.path)) { "EPUB 起始章节文件不存在" }
            if (EpubChapterContent.format(book, first.path, html, endFragmentId = first.fragment,
                    checkActive = checkActive).isNotBlank()) {
                prefix.add(Target(first.path, null, -1))
            }
        }
        val boundaries = (prefix + physical).distinct()
            .sortedWith(compareBy({ spineIndices.getValue(it.path) }, { it.order }))
        val ends = boundaries.withIndex().associate { (index, target) -> target to boundaries.getOrNull(index + 1) }
        val emitted = mutableSetOf<Target>()
        val result = mutableListOf<BookChapter>()
        fun append(target: Target, title: String, depth: Int) {
            checkActive()
            if (!emitted.add(target)) return
            val next = if (target.path in spineIndices) ends[target] else {
                targets.filterNotNull().filter { it.path == target.path && it.order > target.order }.minByOrNull { it.order }
            }
            val singleFile = target.fragment == null && if (target.path !in spineIndices) next == null else {
                val position = spineIndices.getValue(target.path)
                next == null && position == spine.lastIndex || next?.fragment == null &&
                    next?.path == spine.getOrNull(position + 1)
            }
            result.add(chapter(book, target, next, title, result.size, depth, singleFile))
        }
        prefix.forEach { append(it, info(it.path).title, 0) }
        entries.forEachIndexed { index, entry ->
            checkActive()
            val target = targets[index]
            val childTargetsSame = entry.hasChildren && targets.indices.drop(index + 1)
                .takeWhile { entries[it].depth > entry.depth }.any { targets[it] == target && target != null }
            if (entry.hasChildren && (target == null || childTargetsSame)) {
                result.add(BookChapter(
                    bookUrl = book.bookUrl, index = result.size, title = entry.title, isVolume = true,
                    url = "epub-volume:///$index", variable = serializeVariableMap(mapOf("epub.depth" to entry.depth.toString())),
                ))
            } else if (target != null) {
                append(target, entry.title, entry.depth)
            }
            require(result.size <= 20000) { "EPUB 章节数量超过限制" }
        }
        return result
    }

    private fun chapter(
        book: Book, target: Target, next: Target?, title: String, index: Int, depth: Int, singleFile: Boolean,
    ): BookChapter {
        val variables = mutableMapOf("epub.range.v1" to "1", "epub.depth" to depth.toString())
        next?.let { variables["nextUrl"] = url(it) }
        if (singleFile) variables["epub.singleFile"] = "true"
        if (target.path !in spineSet) variables["epub.standalone"] = "true"
        return BookChapter(
            bookUrl = book.bookUrl, index = index, title = title.ifBlank { "第${index + 1}章" },
            url = if (target.fragment == null) target.path else url(target),
            baseUrl = target.path.substringBeforeLast('/', ""), startFragmentId = target.fragment,
            endFragmentId = next?.fragment, variable = serializeVariableMap(variables),
        )
    }

    private fun url(target: Target): String = EpubResourcePaths.toUrl(target.path) +
        (target.fragment?.let { "#${it.encodeURLPathPart()}" } ?: "")

    private fun info(path: String): DocumentInfo = documents.getOrPut(path) {
        checkActive()
        val html = requireNotNull(archive.readText(path)) { "EPUB 章节文件不存在：$path" }
        val document = Ksoup.parse(html)
        val title = document.title().takeIf { it.isNotBlank() }
            ?: document.selectFirst("h1")?.text()?.takeIf { it.isNotBlank() }
            ?: path.substringAfterLast('/').substringBeforeLast('.')
        DocumentInfo(title, EpubDomRange.positions(document.body(), checkActive))
    }
}

internal object EpubChapterContentLoading {
    fun read(archive: EpubArchive, book: Book, chapter: BookChapter, checkActive: () -> Unit): String {
        checkActive()
        if (chapter.isVolume) return ""
        val startPath = chapter.url.takeIf(archive::contains) ?: EpubResourcePaths.resolve("", chapter.url)
            ?: error("EPUB 章节路径无效")
        val startFragment = chapter.startFragmentId ?: chapter.url.substringAfter('#', "").takeIf { it.isNotEmpty() }
            ?.let { EpubNavigationUris.resolve("placeholder", "#$it")?.fragment }
        val isRange = chapter.variableMap["epub.range.v1"] == "1"
        if (!isRange || chapter.variableMap["epub.singleFile"] == "true") {
            val html = requireNotNull(archive.readText(startPath)) { "EPUB 章节文件不存在：$startPath" }
            return EpubChapterContent.format(book, startPath, html, startFragment, chapter.endFragmentId, checkActive)
        }
        val end = chapter.variableMap["nextUrl"]?.let { EpubNavigationUris.resolve("", it.removePrefix("epub-resource:///")) }
        val spine = if (chapter.variableMap["epub.standalone"] == "true") listOf(startPath) else EpubPackage(archive).spinePaths()
        val startIndex = spine.indexOf(startPath)
        require(startIndex >= 0) { "EPUB 章节不在阅读顺序中" }
        val endIndex = end?.let { spine.indexOf(it.path).also { position ->
            require(position >= startIndex) { "EPUB 章节结束边界不在后续阅读顺序中" }
        } } ?: spine.lastIndex
        return buildString {
            for (index in startIndex..endIndex) {
                checkActive()
                if (end != null && index == endIndex && end.fragment == null) break
                val path = spine[index]
                val html = requireNotNull(archive.readText(path)) { "EPUB 章节文件不存在：$path" }
                val body = EpubChapterContent.format(
                    book, path, html, if (index == startIndex) startFragment else null,
                    if (end != null && index == endIndex) end.fragment else null, checkActive,
                )
                if (isNotEmpty() && body.isNotEmpty()) append('\n')
                append(body)
                require(length <= 32 * 1024 * 1024) { "EPUB 章节展开内容超过 32 MiB" }
            }
        }
    }
}
