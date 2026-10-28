package io.legado.kmp.shared.analyze

import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter

/**
 * Local Book Parser
 * Parses local book files into chapters
 *
 * Supported formats:
 * - TXT (text files)
 */
class LocalBookParser {

    /**
     * Get chapter list from a local book
     *
     * @param book Book with local file path
     * @param content Book file content (for text-based formats)
     * @return List of chapters
     */
    fun getChapterList(book: Book, content: String): List<BookChapter> {
        return when {
            book.bookUrl.endsWith(".txt", ignoreCase = true) -> parseTxtChapters(book.bookUrl, content)
            else -> parseTxtChapters(book.bookUrl, content) // Default to text parsing
        }
    }

    /**
     * Get content for a specific chapter
     *
     * @param book Book containing the chapter
     * @param chapter Chapter to get content for
     * @param fullContent Full book content
     * @return Chapter content text
     *
     * Note: For local books, chapter URL contains start/end positions
     * Format: "local://start=0;end=1000"
     */
    fun getChapterContent(book: Book, chapter: BookChapter, fullContent: String): String {
        // Parse position from URL
        val positions = parseChapterPositions(chapter.url)
        val start = positions.first
        val end = if (positions.second == -1) fullContent.length else positions.second

        if (end > fullContent.length) {
            return fullContent.substring(start.coerceIn(0, fullContent.length)).trim()
        }

        return fullContent.substring(start, end)
            .substringAfter(chapter.title)
            .trim()
    }

    /**
     * Parse chapter positions from URL
     * Format: "local://start=0;end=1000"
     */
    private fun parseChapterPositions(url: String): Pair<Int, Int> {
        return try {
            val startMatch = Regex("start=(\\d+)").find(url)
            val endMatch = Regex("end=(\\d+)").find(url)
            val start = startMatch?.groupValues?.get(1)?.toIntOrNull() ?: 0
            val end = endMatch?.groupValues?.get(1)?.toIntOrNull() ?: -1
            Pair(start, end)
        } catch (e: Exception) {
            Pair(0, -1)
        }
    }

    /**
     * Create chapter URL with position information
     */
    private fun createChapterUrl(start: Int, end: Int): String {
        return "local://start=$start;end=$end"
    }

    /**
     * Parse TXT file into chapters using regex patterns
     */
    private fun parseTxtChapters(bookUrl: String, content: String): List<BookChapter> {
        val chapters = mutableListOf<BookChapter>()

        // Common chapter title patterns
        val patterns = listOf(
            Regex("^第[一二三四五六七八九十百千零\\d]+[章回篇节].*", RegexOption.MULTILINE),
            Regex("^Chapter\\s*\\d+.*", RegexOption.MULTILINE),
            Regex("^\\d+\\..*", RegexOption.MULTILINE),
            Regex("^[\\u4e00-\\u9fa5]{2,8}\\s*[章节篇].*", RegexOption.MULTILINE)
        )

        // Find the best matching pattern
        val bestPattern = findBestPattern(content, patterns)

        if (bestPattern != null) {
            val matches = bestPattern.findAll(content).toList()

            for ((index, match) in matches.withIndex()) {
                val title = match.value.trim()
                val startPos = match.range.first

                // Determine end position
                val endPos = if (index < matches.size - 1) {
                    matches[index + 1].range.first
                } else {
                    content.length
                }

                // Create chapter
                val chapter = BookChapter(
                    bookUrl = bookUrl,
                    index = index,
                    title = title,
                    url = createChapterUrl(startPos, endPos),
                    baseUrl = bookUrl,
                    start = startPos.toLong(),
                    end = endPos.toLong()
                )
                chapters.add(chapter)
            }
        }

        // If no chapters found, create chapters by size
        if (chapters.isEmpty()) {
            return createChaptersBySize(bookUrl, content)
        }

        return chapters
    }

    /**
     * Find the best matching pattern for chapter detection
     */
    private fun findBestPattern(content: String, patterns: List<Regex>): Regex? {
        var bestPattern: Regex? = null
        var maxMatches = 0

        for (pattern in patterns) {
            val count = pattern.findAll(content).count()
            if (count > maxMatches) {
                maxMatches = count
                bestPattern = pattern
            }
        }

        return if (maxMatches >= 3) bestPattern else null
    }

    /**
     * Create chapters by fixed size (for unstructured text)
     */
    private fun createChaptersBySize(bookUrl: String, content: String): List<BookChapter> {
        val chapters = mutableListOf<BookChapter>()
        val chapterSize = 10000 // Characters per chapter
        var position = 0
        var chapterIndex = 0

        while (position < content.length) {
            val end = minOf(position + chapterSize, content.length)

            // Try to find a good break point (newline)
            val breakPoint = if (end < content.length) {
                val lastNewline = content.lastIndexOf('\n', end)
                if (lastNewline > position + chapterSize / 2) lastNewline else end
            } else {
                end
            }

            chapters.add(
                BookChapter(
                    bookUrl = bookUrl,
                    index = chapterIndex,
                    title = "第${chapterIndex + 1}章",
                    url = createChapterUrl(position, breakPoint),
                    baseUrl = bookUrl,
                    start = position.toLong(),
                    end = breakPoint.toLong()
                )
            )

            position = breakPoint
            chapterIndex++
        }

        return chapters
    }

    /**
     * Detect file encoding and convert to string
     * (Current KMP implementation decodes as UTF-8 for iOS compatibility)
     */
    fun decodeContent(bytes: ByteArray, charsetName: String? = null): String {
        charsetName
        return bytes.decodeToString()
    }

    companion object {
        /**
         * Parse local book content
         */
        fun parse(book: Book, content: String): List<BookChapter> {
            return LocalBookParser().getChapterList(book, content)
        }
    }
}
