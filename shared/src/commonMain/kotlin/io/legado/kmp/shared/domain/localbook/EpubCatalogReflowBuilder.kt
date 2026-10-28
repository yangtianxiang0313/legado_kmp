package io.legado.kmp.shared.domain.localbook

import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter

/** Builds proofs only for spine files touched by a changed reading span. */
internal class EpubCatalogReflowBuilder(
    private val archive: EpubArchive,
    private val checkActive: () -> Unit,
) {
    private class Entry(val chapter: BookChapter, val span: EpubReflowSpan)

    private class RegionSpan(
        val physical: EpubReflowPhysicalSpan,
        val start: EpubReflowPoint,
        val end: EpubReflowPoint,
    )

    private class RegionText(
        val firstFile: Int,
        val documents: List<EpubReflowCanonicalDocument>,
        val fileOffsets: IntArray,
        val content: CharArray,
    ) {
        fun coordinate(point: EpubReflowPoint): Int {
            val file = point.file - firstFile
            if (file == documents.size) return content.size
            return fileOffsets[file] + requireNotNull(documents[file].boundaries[point.order]) {
                "EPUB 重切缺少 DOM 边界的 canonical 投影"
            }
        }
    }

    suspend fun build(
        current: Book,
        replacement: Book,
        previous: List<BookChapter>,
        chapters: List<BookChapter>,
        process: suspend (Book, BookChapter, String, Boolean) -> EpubReflowText,
    ): EpubCatalogReflowPlan? {
        checkActive()
        if (!needsEpubCatalogReflow(previous, chapters)) return null
        require(current.bookUrl == replacement.bookUrl && current.isEpub && replacement.isEpub) {
            "EPUB 重切必须使用同一本 EPUB 的目录快照"
        }
        val budget = EpubReflowBudget(checkActive)
        budget.metadata(current, previous)
        budget.metadata(replacement, chapters)
        val signature = EpubReflowSignature(current, replacement, previous, chapters)
        val oldBook = current.copy(readConfig = current.readConfig?.copy())
        val newBook = replacement.copy(readConfig = replacement.readConfig?.copy())
        val oldEntries = entries(oldBook, previous)
        val newEntries = entries(newBook, chapters)
        val oldCounts = oldEntries.groupingBy { it.span }.eachCount()
        require(oldCounts.values.all { it == 1 }) { "EPUB 原目录有重复阅读范围，无法证明重切映射" }
        val newBySpan = newEntries.groupBy { it.span }
        val identities = oldEntries.mapNotNull { old ->
            newBySpan[old.span]?.singleOrNull()?.let { old.chapter.index to it.chapter }
        }.toMap()
        val unchangedNew = identities.values.map { it.index }.toSet()
        val changedOld = oldEntries.filter { it.chapter.index !in identities }
        val changedNew = newEntries.filter { it.chapter.index !in unchangedNew }

        val spine = EpubPackage(archive).spinePaths()
        require(spine.size <= 10_000) { "EPUB 重切 spine 文件数量超过 10000" }
        val indices = spine.withIndex().associate { it.value to it.index }
        fun physical(entries: List<Entry>, unchanged: Set<Int>): List<EpubReflowPhysicalSpan> = entries.mapNotNull { entry ->
            checkActive()
            if (entry.span.path !in indices && entry.chapter.index in unchanged) null else {
                val actualPath = entry.chapter.url.takeIf(archive::contains)
                    ?: EpubResourcePaths.resolve("", entry.chapter.url)
                require(actualPath == entry.span.path) { "EPUB 重切路径存在 URI 与归档文件名歧义" }
                entry.span.physical(entry.chapter, indices, spine.size)
            }
        }
        val oldPhysical = physical(oldEntries, identities.keys)
        val newPhysical = physical(newEntries, unchangedNew)
        val affected = BooleanArray(spine.size)
        (oldPhysical.filter { it.chapter.index !in identities } +
            newPhysical.filter { it.chapter.index !in unchangedNew }).forEach { span ->
            span.files().forEach { file ->
                checkActive()
                require(file in spine.indices) { "EPUB 重切范围超出真实 spine" }
                affected[file] = true
            }
        }
        val fragments = Array(spine.size) { mutableSetOf<String>() }
        (oldPhysical + newPhysical).forEach { span ->
            checkActive()
            if (affected[span.startFile]) span.key.fragment?.let { fragments[span.startFile].add(it) }
            if (span.endFile in spine.indices && affected[span.endFile]) {
                span.endFragment?.let { fragments[span.endFile].add(it) }
            }
        }
        val documents = arrayOfNulls<EpubReflowDocument>(spine.size)
        spine.indices.filter { affected[it] }.forEach { file ->
            checkActive()
            documents[file] = readEpubReflowDocument(archive, spine[file], fragments[file], budget)
        }

        fun point(file: Int, fragment: String?): EpubReflowPoint = EpubReflowPoint(file,
            if (fragment == null) 0 else requireNotNull(documents[file]?.anchors?.get(fragment)) {
                "EPUB 重切物理边界缺少锚点"
            })
        fun spanKey(span: EpubReflowPhysicalSpan): Pair<EpubReflowPoint, EpubReflowPoint> =
            point(span.startFile, span.key.fragment) to point(span.endFile, span.endFragment)

        // Distinct fragment aliases may still describe exactly the same DOM ranges.
        val changedOldPhysical = oldPhysical.filter { it.chapter.index !in identities }
        val changedNewPhysical = newPhysical.filter { it.chapter.index !in unchangedNew }
        val newPhysicalCounts = changedNewPhysical.groupingBy(::spanKey).eachCount()
        if (changedOldPhysical.size == changedNewPhysical.size &&
            changedOldPhysical.all { newPhysicalCounts[spanKey(it)] == 1 }) return null

        val sources = mutableMapOf<Int, EpubReflowSource>()
        val identityLocations = mutableMapOf<Int, EpubReflowLocation>()
        identities.forEach { (oldIndex, chapter) ->
            checkActive()
            val title = identityLocations.getOrPut(chapter.index) {
                // The callback supplies the real display title without loading unchanged chapter text.
                val result = epubReflowProcess(newBook, chapter, "", true, budget, process)
                EpubReflowLocation(chapter.index, 0, result.displayTitle)
            }
            sources[oldIndex] = EpubReflowSource(identity = title)
        }
        val regions = mutableListOf<EpubReflowRegion>()
        var first = 0
        while (first < spine.size) {
            checkActive()
            if (!affected[first]) {
                first++
                continue
            }
            var end = first + 1
            while (end < spine.size && affected[end]) end++
            val oldSpans = clipped(oldPhysical, first, end, ::point)
            val newSpans = clipped(newPhysical, first, end, ::point)
            val text = regionText(first, end, documents, oldSpans, newSpans, oldBook, newBook, budget, process)
            val orderedOld = covered(oldSpans, first, end, text)
            val orderedNew = covered(newSpans, first, end, text)
            val regionIndex = regions.size
            orderedOld.filter { it.physical.chapter.index !in identities }.forEach { span ->
                checkActive()
                val chapter = span.physical.chapter
                val (_, projection) = projectChapter(oldBook, span, documents, text, budget, process)
                require(chapter.index !in sources) { "EPUB 重切旧章节跨越了不连续的证明区间" }
                sources[chapter.index] = EpubReflowSource(region = regionIndex, projection = projection)
            }
            val targets = orderedNew.map { span ->
                checkActive()
                val chapter = span.physical.chapter
                val start = text.coordinate(span.start)
                val finish = text.coordinate(span.end)
                val identity = identityLocations[chapter.index]
                if (identity != null) {
                    EpubReflowTarget(start, finish, chapter.index, identity.chapterTitle, identity = identity)
                } else {
                    val (displayTitle, projection) = projectChapter(newBook, span, documents, text, budget, process)
                    EpubReflowTarget(start, finish, chapter.index, displayTitle, projection = projection)
                }
            }.toMutableList()
            // A file-end location belongs to the following readable chapter when its start is proven.
            newPhysical.singleOrNull {
                it.startFile == end && it.key.fragment == null && it.chapter.index in unchangedNew
            }?.let { next ->
                val identity = identityLocations.getValue(next.chapter.index)
                targets.add(EpubReflowTarget(text.content.size, text.content.size, next.chapter.index,
                    identity.chapterTitle, identity = identity))
            }
            regions.add(EpubReflowRegion(targets))
            first = end
        }
        require(changedOld.size == sources.size - identities.size && sources.size == oldEntries.size &&
            changedNew.size == regions.sumOf { region -> region.targets.count { it.identity == null } }) {
            "EPUB 重切有章节未包含在完整的物理投影中"
        }
        checkActive()
        check(signature.matches(current, replacement, previous, chapters)) {
            "EPUB 重切准备期间书籍配置或目录发生变化；已保留原目录与进度"
        }
        return EpubCatalogReflowPlan(signature, sources.toMap(), regions.toList())
    }

    private fun entries(book: Book, chapters: List<BookChapter>): List<Entry> {
        val seen = mutableSetOf<Int>()
        return chapters.mapNotNull { chapter ->
            checkActive()
            require(chapter.index >= 0 && seen.add(chapter.index) && chapter.bookUrl == book.bookUrl) {
                "EPUB 重切章节 index 重复、为负数或不属于当前书籍"
            }
            if (chapter.isVolume) null else Entry(chapter.copy(), epubReflowSpan(chapter))
        }
    }

    private fun clipped(
        spans: List<EpubReflowPhysicalSpan>,
        first: Int,
        end: Int,
        point: (Int, String?) -> EpubReflowPoint,
    ): List<RegionSpan> = spans.filter { it.touches(first, end) }.map { span ->
        checkActive()
        val start = if (span.startFile < first) EpubReflowPoint(first, 0) else point(span.startFile, span.key.fragment)
        val finish = if (span.endFile >= end) EpubReflowPoint(end, 0) else point(span.endFile, span.endFragment)
        require(start <= finish) { "EPUB 重切 DOM 结束锚点位于开始锚点之前" }
        RegionSpan(span, start, finish)
    }

    private suspend fun regionText(
        first: Int,
        end: Int,
        documents: Array<EpubReflowDocument?>,
        oldSpans: List<RegionSpan>,
        newSpans: List<RegionSpan>,
        current: Book,
        replacement: Book,
        budget: EpubReflowBudget,
        process: suspend (Book, BookChapter, String, Boolean) -> EpubReflowText,
    ): RegionText {
        val canonical = (first until end).map { file ->
            checkActive()
            val oldContext = requireNotNull(oldSpans.firstOrNull { it.physical.touches(file, file + 1) }) {
                "EPUB 原目录未覆盖重切正文文件"
            }.physical.chapter
            val newContext = requireNotNull(newSpans.firstOrNull { it.physical.touches(file, file + 1) }) {
                "EPUB 新目录未覆盖重切正文文件"
            }.physical.chapter
            projectEpubReflowDocument(archive, requireNotNull(documents[file]), current, replacement,
                oldContext, newContext, budget, process)
        }
        val offsets = IntArray(canonical.size + 1)
        canonical.forEachIndexed { index, document ->
            checkActive()
            offsets[index + 1] = offsets[index] + document.content.size
        }
        val content = CharArray(offsets.last())
        canonical.forEachIndexed { index, document ->
            var position = 0
            while (position < document.content.size) {
                checkActive()
                val finish = minOf(position + 8192, document.content.size)
                document.content.copyInto(content, offsets[index] + position, position, finish)
                position = finish
            }
        }
        return RegionText(first, canonical, offsets, content)
    }

    private fun covered(
        spans: List<RegionSpan>,
        first: Int,
        end: Int,
        text: RegionText,
    ): List<RegionSpan> {
        val ordered = spans.sortedWith(compareBy({ it.start }, { it.end }))
        var physicalEnd = EpubReflowPoint(first, 0)
        var canonicalEnd = 0
        var previous: RegionSpan? = null
        ordered.forEach { span ->
            checkActive()
            require(span.start >= physicalEnd && !(previous?.start == span.start && previous?.end == span.end)) {
                "EPUB 重切阅读范围重叠或重复；已保留原目录与进度"
            }
            val start = text.coordinate(span.start)
            val finish = text.coordinate(span.end)
            require(start == canonicalEnd && finish >= start) {
                "EPUB 重切阅读范围有 canonical 字符缺口或倒退；已保留原目录与进度"
            }
            canonicalEnd = finish
            physicalEnd = span.end
            previous = span
        }
        require(physicalEnd <= EpubReflowPoint(end, 0) && canonicalEnd == text.content.size) {
            "EPUB 重切目录未覆盖全部 canonical 正文；已保留原目录与进度"
        }
        return ordered
    }

    private suspend fun projectChapter(
        book: Book,
        span: RegionSpan,
        documents: Array<EpubReflowDocument?>,
        text: RegionText,
        budget: EpubReflowBudget,
        process: suspend (Book, BookChapter, String, Boolean) -> EpubReflowText,
    ): Pair<String, EpubReflowProjection> {
        val physical = span.physical
        // Reserve all formatter work before the existing reader starts assembling a cross-file range.
        physical.files().forEach { file ->
            checkActive()
            if (file != physical.endFile || physical.endFragment != null) {
                budget.format(requireNotNull(documents[file]))
            }
        }
        val raw = EpubChapterContentLoading.read(archive, book, physical.chapter, checkActive)
        val start = text.coordinate(span.start)
        val end = text.coordinate(span.end)
        val untrimmed = epubReflowProcess(book, physical.chapter, raw, false, budget, process)
        requireEpubReflowEqual(epubReflowCanonical(untrimmed.content, budget), text.content, start, end, budget,
            "章节 raw 范围与 spine 全局区间不一致")
        val actual = epubReflowProcess(book, physical.chapter, raw, true, budget, process)
        return actual.displayTitle to epubReflowOffsets(actual.content, text.content, start, end, budget)
    }
}
