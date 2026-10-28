package io.legado.kmp.shared.domain.localbook

import io.legado.kmp.shared.exception.EmptyFileException
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.TxtTocRule
import io.legado.kmp.shared.util.md5Hex
import kotlinx.datetime.Clock

data class ParsedTxtBook(
    val book: Book,
    val chapters: List<BookChapter>,
    val charsetName: String
)

class TxtBookParser(
    private val bufferSize: Int = 512000,
    private val maxLengthWithNoToc: Int = 10 * 1024,
    private val maxLengthWithToc: Int = 102400
) {
    private val padRegex = "^[\\n\\s]+".toRegex()

    init {
        require(bufferSize in 1..Int.MAX_VALUE - 12) { "TXT buffer size is out of range" }
        require(maxLengthWithNoToc > 0) { "TXT chapter length must be positive" }
    }

    fun parse(
        book: Book,
        bytes: ByteArray,
        tocRules: List<TxtTocRule>
    ): ParsedTxtBook = parse(book, bytes, tocRules) {}

    fun parse(
        book: Book,
        bytes: ByteArray,
        tocRules: List<TxtTocRule>,
        checkActive: () -> Unit
    ): ParsedTxtBook = parseSource(book, ByteArrayLocalBookByteSource(bytes), tocRules, checkActive)

    @Throws(Exception::class)
    fun parseSource(
        book: Book,
        source: LocalBookByteSource,
        tocRules: List<TxtTocRule>,
        checkActive: () -> Unit
    ): ParsedTxtBook {
        checkActive()
        if (source.size == 0L) throw EmptyFileException("Unexpected Empty Txt File")
        val charsetName = book.charset?.takeIf { it.isNotBlank() } ?: detectTxtCharset(source, checkActive)
        val reader = TxtWindowReader(source, charsetName, bufferSize, checkActive)
        val previewText = if (reader.startOffset < source.size) {
            reader.window(reader.startOffset).content
        } else {
            ""
        }
        val tocRegex = selectTocRule(previewText, tocRules, checkActive)
        val (chapters, wordCount) = if (tocRegex == null) {
            analyzeWithoutRule(reader, checkActive)
        } else {
            analyzeWithRule(reader, tocRegex, book.config.splitLongChapter, checkActive)
        }

        val normalized = chapters.mapIndexed { index, chapter ->
            checkActive()
            chapter.copy(
                index = index,
                bookUrl = book.bookUrl,
                url = (book.originName + index + chapter.title).md5Hex().substring(8, 24),
                title = chapter.title.ifBlank { "无标题章节" }
            )
        }
        val latest = normalized.lastOrNull()?.title
        val current = normalized.getOrNull(book.durChapterIndex)?.title ?: latest
        val now = Clock.System.now().toEpochMilliseconds()
        val updatedBook = book.copy(
            charset = charsetName,
            tocUrl = tocRegex?.pattern.orEmpty(),
            wordCount = wordCountFormat(wordCount),
            totalChapterNum = normalized.size,
            latestChapterTitle = latest,
            latestChapterTime = now,
            durChapterTitle = current
        )
        checkActive()
        return ParsedTxtBook(updatedBook, normalized, charsetName)
    }

    fun readContent(
        bytes: ByteArray,
        chapter: BookChapter,
        charsetName: String
    ): String = readSourceContent(ByteArrayLocalBookByteSource(bytes), chapter, charsetName) {}

    @Throws(Exception::class)
    fun readSourceContent(
        source: LocalBookByteSource,
        chapter: BookChapter,
        charsetName: String?,
        checkActive: () -> Unit
    ): String {
        checkActive()
        val start = chapter.start ?: return ""
        val end = chapter.end ?: return ""
        if (start !in 0L..source.size || end !in start..source.size || start == end) return ""
        val charset = charsetName?.takeIf { it.isNotBlank() } ?: detectTxtCharset(source, checkActive)
        val reader = TxtWindowReader(source, charset, bufferSize, checkActive)
        val content = buildString {
            var offset = start
            while (offset < end) {
                checkActive()
                val window = reader.window(offset, end)
                append(window.content)
                offset = window.end
            }
        }
        checkActive()
        return content.substringAfter(chapter.title).replace(padRegex, "　　")
    }

    private fun analyzeWithRule(
        reader: TxtWindowReader,
        pattern: Regex,
        splitLongChapter: Boolean,
        checkActive: () -> Unit
    ): Pair<ArrayList<BookChapter>, Long> {
        val toc = arrayListOf<BookChapter>()
        var bookWordCount = 0L
        var sourceOffset = reader.startOffset
        val initialOffset = sourceOffset
        var startsAtLineStart = true
        var lastChapterWordCount = 0L
        var lastChapterHasBody = false
        var preambleHasText = false
        var lastTitleEnd = sourceOffset

        while (sourceOffset < reader.size) {
            checkActive()
            val block = reader.window(sourceOffset, preferLineBreak = true)
            val end = block.end
            val blockContent = block.content
            bookWordCount += blockContent.length
            // A forced window inside an overlong line is body text, not a new logical line.
            val matchableStart = if (startsAtLineStart) 0 else {
                blockContent.indexOf('\n').takeIf { it >= 0 }?.plus(1) ?: blockContent.length
            }
            val matchableEnd = if (end == reader.size) blockContent.length else blockContent.lastIndexOf('\n') + 1
            var seekPos = 0
            var bodyTextStart = 0
            pattern.findAll(blockContent).forEach { match ->
                checkActive()
                val titleStart = match.range.first
                val titleEnd = match.range.last + 1
                if (titleStart < matchableStart || titleEnd > matchableEnd ||
                    (end < reader.size && titleStart >= matchableEnd)
                ) return@forEach
                val chapterStart = block.byteOffset(titleStart) ?: return@forEach
                val chapterTitleEnd = block.byteOffset(titleEnd) ?: return@forEach
                val chapterContent = blockContent.substring(seekPos, titleStart)
                lastChapterWordCount += chapterContent.length
                if (toc.isEmpty()) {
                    preambleHasText = preambleHasText || chapterContent.isNotBlank()
                    if (preambleHasText) {
                        toc += BookChapter(
                            title = "前言",
                            start = initialOffset,
                            end = chapterStart,
                            wordCount = wordCountFormat(lastChapterWordCount)
                        )
                    }
                } else {
                    lastChapterHasBody = lastChapterHasBody ||
                        blockContent.substring(maxOf(seekPos, bodyTextStart), titleStart).isNotBlank()
                    val last = toc.last()
                    toc[toc.lastIndex] = last.copy(
                        end = chapterStart,
                        isVolume = !lastChapterHasBody,
                        wordCount = wordCountFormat(lastChapterWordCount)
                    )
                    if (splitLongChapter && chapterStart - (last.start ?: chapterStart) > maxLengthWithToc) {
                        toc[toc.lastIndex] = toc.last().copy(end = last.start, tag = null)
                        val (chapters, _) = analyzeWithoutRule(reader, checkActive, lastTitleEnd, chapterStart)
                        chapters.forEachIndexed { index, chapter ->
                            toc += chapter.copy(title = "${last.title}(${index + 1})")
                        }
                    }
                }
                toc += BookChapter(title = match.value, start = chapterStart, end = chapterStart)
                lastTitleEnd = chapterTitleEnd
                lastChapterWordCount = 0L
                lastChapterHasBody = false
                seekPos = titleStart
                bodyTextStart = titleEnd
            }
            lastChapterWordCount += blockContent.length - seekPos
            if (toc.isEmpty()) {
                preambleHasText = preambleHasText || blockContent.substring(seekPos).isNotBlank()
            } else {
                lastChapterHasBody = lastChapterHasBody || blockContent.substring(maxOf(seekPos, bodyTextStart)).isNotBlank()
            }
            toc.lastOrNull()?.let { last ->
                toc[toc.lastIndex] = last.copy(end = end, wordCount = wordCountFormat(lastChapterWordCount))
            }
            if (blockContent.isNotEmpty()) startsAtLineStart = blockContent.endsWith('\n')
            sourceOffset = end
        }
        if (toc.isEmpty()) return analyzeWithoutRule(reader, checkActive)
        toc.lastOrNull()?.let { last ->
            val start = last.start ?: 0L
            val end = last.end ?: start
            if (splitLongChapter && end - start > maxLengthWithToc) {
                toc.removeAt(toc.lastIndex)
                val (chapters, _) = analyzeWithoutRule(
                    reader = reader,
                    checkActive = checkActive,
                    rangeStart = lastTitleEnd,
                    rangeEnd = end
                )
                chapters.forEachIndexed { index, chapter ->
                    toc += chapter.copy(title = "${last.title}(${index + 1})")
                }
            }
        }
        return toc to bookWordCount
    }

    private fun analyzeWithoutRule(
        reader: TxtWindowReader,
        checkActive: () -> Unit,
        rangeStart: Long = 0,
        rangeEnd: Long = reader.size
    ): Pair<ArrayList<BookChapter>, Long> {
        val toc = arrayListOf<BookChapter>()
        var bookWordCount = 0L
        var sourceOffset = if (rangeStart == 0L) reader.startOffset else rangeStart
        var blockPos = 0
        var chapterPos = 0
        var lastChapterWordCount = 0L

        while (sourceOffset < rangeEnd) {
            checkActive()
            val block = reader.window(sourceOffset, rangeEnd)
            val end = block.end
            blockPos++
            var chapterOffset = sourceOffset
            chapterPos = 0
            while (chapterOffset < end) {
                checkActive()
                chapterPos++
                if (end - chapterOffset > maxLengthWithNoToc || (chapterOffset == sourceOffset && end < rangeEnd)) {
                    val minimum = chapterOffset + minOf(maxLengthWithNoToc.toLong(), end - chapterOffset)
                    val chapterEnd = block.firstLineBreak(chapterOffset, minimum) ?: end
                    val content = block.decode(chapterOffset, chapterEnd)
                    bookWordCount += content.length
                    lastChapterWordCount = content.length.toLong()
                    toc += BookChapter(
                        title = "第${blockPos}章($chapterPos)",
                        start = chapterOffset,
                        end = chapterEnd,
                        wordCount = wordCountFormat(content.length.toLong())
                    )
                    chapterOffset = chapterEnd
                } else {
                    break
                }
            }
            // Retain only the small remainder by offset; a full window must be consumed even when below the chapter limit.
            check(chapterOffset > sourceOffset || end == rangeEnd) { "TXT chapter window did not advance at byte $sourceOffset" }
            sourceOffset = chapterOffset
            if (end == rangeEnd) break
        }

        val carrySize = rangeEnd - sourceOffset
        val tail = if (carrySize > 0) reader.window(sourceOffset, rangeEnd).content else ""
        bookWordCount += tail.length
        if (carrySize > 100 || toc.isEmpty()) {
            toc += BookChapter(
                title = "第${if (blockPos == 0) 1 else blockPos}章($chapterPos)",
                start = sourceOffset,
                end = rangeEnd,
                wordCount = wordCountFormat(tail.length.toLong())
            )
        } else {
            toc.lastOrNull()?.let { last ->
                toc[toc.lastIndex] = last.copy(
                    end = (last.end ?: 0L) + carrySize,
                    wordCount = wordCountFormat(lastChapterWordCount + tail.length)
                )
            }
        }
        return toc to bookWordCount
    }

    private fun selectTocRule(content: String, tocRules: List<TxtTocRule>, checkActive: () -> Unit): Regex? {
        var maxNum = 1
        var selected: Regex? = null
        tocRules.asReversed().filter { it.enable }.forEach { tocRule ->
            checkActive()
            val regex = runCatching { Regex(tocRule.rule, setOf(RegexOption.MULTILINE)) }.getOrNull() ?: return@forEach
            var start = 0
            var num = 0
            regex.findAll(content).forEach { match ->
                checkActive()
                if (start == 0 || match.range.first - start > 1000) {
                    num += 1
                    start = match.range.last + 1
                }
            }
            if (num >= maxNum) {
                maxNum = num
                selected = regex
            }
        }
        return selected
    }

    private fun wordCountFormat(words: Long): String {
        return when {
            words <= 0 -> ""
            words > 10000 -> "${(words / 100L) / 100.0}万字"
            else -> "${words}字"
        }
    }
}
