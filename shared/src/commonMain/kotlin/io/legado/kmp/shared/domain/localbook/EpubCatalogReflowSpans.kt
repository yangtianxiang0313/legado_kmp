package io.legado.kmp.shared.domain.localbook

import io.legado.kmp.shared.model.BookChapter

/** Cheap identity gate: display order and labels are not reading boundaries. */
internal fun needsEpubCatalogReflow(previous: List<BookChapter>, chapters: List<BookChapter>): Boolean {
    require(previous.size <= EpubReflowBudget.MAX_CHAPTERS && chapters.size <= EpubReflowBudget.MAX_CHAPTERS) {
        "EPUB 重切章节数量超过 20000"
    }
    val counts = mutableMapOf<EpubReflowSpan, Int>()
    chapters.filterNot { it.isVolume }.forEach { chapter ->
        val span = epubReflowSpan(chapter)
        counts[span] = (counts[span] ?: 0) + 1
    }
    return previous.any { !it.isVolume && counts[epubReflowSpan(it)] != 1 }
}

/** A file-end is distinct from an unknown spine-end until an archive has been opened. */
internal data class EpubReflowSpan(
    val path: String,
    val fragment: String?,
    val endPath: String?,
    val endFragment: String?,
    val fileEnd: Boolean,
)

internal fun epubReflowSpan(chapter: BookChapter): EpubReflowSpan {
    val path = EpubResourcePaths.resolve("", chapter.url) ?: error("EPUB 重切章节路径无效")
    val fragment = chapter.startFragmentId ?: chapter.url.substringAfter('#', "").takeIf { it.isNotEmpty() }
        ?.let { encoded ->
            requireNotNull(EpubNavigationUris.resolve("placeholder", "#$encoded")) {
                "EPUB 重切章节锚点编码无效"
            }.fragment
        }
    val variables = chapter.variableMap
    if (variables["epub.range.v1"] != "1" || variables["epub.singleFile"] == "true") {
        return EpubReflowSpan(path, fragment, path, chapter.endFragmentId, chapter.endFragmentId == null)
    }
    val end = variables["nextUrl"]?.let { reference ->
        requireNotNull(EpubNavigationUris.resolve("", reference.removePrefix("epub-resource:///"))) {
            "EPUB 重切章节结束地址无效"
        }
    }
    if (variables["epub.standalone"] == "true") {
        require(end == null || end.path == path) { "EPUB 独立章节的结束边界跨越文件" }
        return EpubReflowSpan(path, fragment, path, end?.fragment, end == null)
    }
    return EpubReflowSpan(path, fragment, end?.path, end?.fragment, false)
}

internal data class EpubReflowPoint(val file: Int, val order: Int) : Comparable<EpubReflowPoint> {
    override fun compareTo(other: EpubReflowPoint): Int =
        if (file == other.file) order.compareTo(other.order) else file.compareTo(other.file)
}

internal class EpubReflowPhysicalSpan(
    val chapter: BookChapter,
    val key: EpubReflowSpan,
    val startFile: Int,
    val endFile: Int,
    val endFragment: String?,
) {
    fun touches(first: Int, end: Int): Boolean = startFile < end &&
        (endFile > first || endFile == first && endFragment != null)

    fun files(): IntRange = startFile..maxOf(startFile, if (endFragment == null) endFile - 1 else endFile)
}

internal fun EpubReflowSpan.physical(
    chapter: BookChapter,
    spine: Map<String, Int>,
    fileCount: Int,
): EpubReflowPhysicalSpan {
    val start = requireNotNull(spine[path]) { "EPUB 重切章节不在真实 spine 中：$path" }
    val end = if (endPath == null) fileCount else {
        requireNotNull(spine[endPath]) { "EPUB 重切结束文件不在真实 spine 中：$endPath" } + if (fileEnd) 1 else 0
    }
    require(end >= start && end <= fileCount) { "EPUB 重切章节结束边界倒退或越界" }
    return EpubReflowPhysicalSpan(chapter, this, start, end, endFragment)
}
