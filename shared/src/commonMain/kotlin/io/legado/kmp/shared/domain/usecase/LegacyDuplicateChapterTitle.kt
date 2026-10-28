package io.legado.kmp.shared.domain.usecase

internal object LegacyDuplicateChapterTitle {
    // Android's ICU \s includes Unicode separators and NEL; Native's default \s does not.
    private const val whitespaceClass = "[\\s\\p{Z}\\u0085]"
    // Native 2.1 does not resolve the N aggregate; use its three equivalent categories.
    private const val unicodeWordClass = "[\\p{L}\\p{M}\\p{Nd}\\p{Nl}\\p{No}_]"
    private val whitespace = Regex("$whitespaceClass+")
    private val whitespaceOrPunctuation = Regex("(?:$whitespaceClass|\\p{P})*")
    private val unicodeWordEnd = Regex("$unicodeWordClass\\z")

    fun remove(
        content: String,
        bookName: String,
        chapterTitle: String,
        displayTitle: String?,
        useReplace: Boolean,
    ): Pair<String, Boolean> {
        if (chapterTitle.isBlank()) return content to false

        // Redundant literals such as "_" would introduce ambiguous prefix repetitions.
        val prefix = if (whitespaceOrPunctuation.matches(bookName)) {
            "(?:$whitespaceClass|\\p{P})*"
        } else {
            "(?:$whitespaceClass|\\p{P}|${Regex.escape(bookName)})*"
        }
        val flexibleTitle = whitespace.split(chapterTitle).joinToString("$whitespaceClass*") {
            Regex.escape(it)
        }
        removePrefix(
            content,
            prefix,
            flexibleTitle,
            bookTitleBoundary(chapterTitle, bookName, flexibleWhitespace = true),
        )?.let { return it to true }

        if (useReplace && !displayTitle.isNullOrBlank() && displayTitle != chapterTitle &&
            displayTitle.none { it == '\r' || it == '\n' }
        ) {
            removePrefix(
                content,
                prefix,
                Regex.escape(displayTitle),
                bookTitleBoundary(displayTitle, bookName, flexibleWhitespace = false),
            )?.let {
                return it to true
            }
        }

        return content to false
    }

    private fun removePrefix(
        content: String,
        prefix: String,
        title: String,
        titleBoundary: String,
    ): String? {
        return try {
            // Keep the boundary in the regex so a greedy prefix can backtrack to a title line.
            val match = Regex("^($prefix$title)$titleBoundary$whitespaceClass*")
                .find(content) ?: return null
            // The anchored capture ends at the title, before trailing whitespace.
            val titleEnd = match.groupValues[1].length
            if (isAsciiWord(content.getOrNull(titleEnd - 1)) &&
                isAsciiWord(content.getOrNull(titleEnd))
            ) {
                return null
            }
            content.substring(match.range.last + 1)
        } catch (_: Exception) {
            null
        }
    }

    private fun bookTitleBoundary(
        title: String,
        bookName: String,
        flexibleWhitespace: Boolean,
    ): String {
        val compactTitle = whitespace.replace(title, "")
        if (compactTitle != whitespace.replace(bookName, "")) return ""
        // Literal display titles retain trailing whitespace as a separator.
        val boundaryTitle = if (flexibleWhitespace) compactTitle else title
        return if (unicodeWordEnd.containsMatchIn(boundaryTitle)) "(?!$unicodeWordClass)" else ""
    }

    private fun isAsciiWord(character: Char?): Boolean {
        return character != null && (
            character in 'a'..'z' || character in 'A'..'Z' ||
                character in '0'..'9' || character == '_'
            )
    }
}
