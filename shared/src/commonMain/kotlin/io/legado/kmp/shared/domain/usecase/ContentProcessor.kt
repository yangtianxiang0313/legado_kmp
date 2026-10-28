package io.legado.kmp.shared.domain.usecase

import io.legado.kmp.shared.content.ContentHelp
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.util.ChineseConverter

class ContentProcessor(
    private val applyReplaceRulesUseCase: ApplyReplaceRulesUseCase,
) {
    data class Result(
        val content: String,
        val sameTitleRemoved: Boolean = false,
    )

    /**
     * Process chapter content in the same order as legacy Legado:
     * remove duplicate title, reSegment, Chinese conversion, trim lines,
     * then apply replace rules.
     *
     * @param chineseConvert 0 = no conversion, 1 = traditional to simplified, 2 = simplified to traditional
     * @param shouldRemoveSameTitle whether this chapter should have duplicate title removed (per-chapter control)
     */
    suspend fun process(
        book: Book,
        chapter: BookChapter,
        content: String,
        displayTitle: String,
        useReplace: Boolean = true,
        chineseConvert: Int = 0,
        shouldRemoveSameTitle: Boolean = true,
    ): Result {
        if (content.isEmpty() || content == "null") {
            return Result(content = content)
        }

        var processed = content
        var titleRemoved = false

        // Remove duplicate title (respecting per-chapter control)
        if (shouldRemoveSameTitle) {
            val (afterTitle, removed) = removeDuplicateTitle(
                content = processed,
                bookName = book.name,
                chapterTitle = chapter.title,
                displayTitle = displayTitle,
                useReplace = useReplace,
            )
            processed = afterTitle
            titleRemoved = removed
        }

        // Apply reSegment when enabled in book config
        if (book.config.reSegment) {
            processed = ContentHelp.reSegment(processed, chapter.title)
        }

        // Apply simplified/traditional Chinese conversion
        if (chineseConvert == 1) {
            processed = ChineseConverter.t2s(processed)
        } else if (chineseConvert == 2) {
            processed = ChineseConverter.s2t(processed)
        }

        // Apply replace rules with bookName + origin scope filtering
        if (useReplace) {
            processed = applyReplaceRulesUseCase.applyToContent(
                processed.lines().joinToString("\n") { it.trim() },
                book.origin,
                book.name,
            )
        }

        return Result(content = processed, sameTitleRemoved = titleRemoved)
    }

    companion object {
        /**
         * Follow Android's title-prefix semantics without requiring a complete title line,
         * preserving ASCII word/number boundaries and ordinary Chinese inline titles.
         * Titles equal to the book name after whitespace normalization also respect Unicode
         * word boundaries, while standalone repeated titles remain removable by backtracking.
         */
        fun removeDuplicateTitle(
            content: String,
            bookName: String,
            chapterTitle: String,
            displayTitle: String?,
            useReplace: Boolean,
        ): Pair<String, Boolean> = LegacyDuplicateChapterTitle.remove(
            content = content,
            bookName = bookName,
            chapterTitle = chapterTitle,
            displayTitle = displayTitle,
            useReplace = useReplace,
        )
    }
}
