package io.legado.kmp.shared.facade

import io.legado.kmp.shared.domain.usecase.ApplyReplaceRulesUseCase
import io.legado.kmp.shared.domain.usecase.ContentProcessor
import io.legado.kmp.shared.domain.usecase.resolveDisplayChapterTitle
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

internal data class BookExportTransformedChapter(
    val chapter: BookChapter,
    val body: String,
)

/** Replacement only; the returned body must still pass through BookExportDocument. */
internal class BookExportContentTransform(private val rules: ApplyReplaceRulesUseCase) {
    private val processor = ContentProcessor(rules)

    suspend fun transform(
        book: Book,
        chapter: BookChapter,
        raw: String,
        useReplaceRules: Boolean,
    ): BookExportTransformedChapter {
        val context = currentCoroutineContext()
        val budget = BookExportBudget { context.ensureActive() }
        fun checked(value: String, label: String): String {
            context.ensureActive()
            budget.textBytes(value, BookExportLimits.CHAPTER_BODY_BYTES, "${label}超过 16 MiB 导出限制")
            context.ensureActive()
            return value
        }

        checked(raw, "原始正文")
        checked(chapter.title, "原始标题")
        val config = book.config.copy()
        val useReplace = useReplaceRules && (config.useReplaceRule ?: (!book.isImage && !book.isEpub))
        val snapshot = book.copy(readConfig = config.copy(useReplaceRule = useReplace, reSegment = false))

        context.ensureActive()
        val title = checked(resolveDisplayChapterTitle(snapshot, chapter, rules), "处理后标题")

        // Android tries the original title first, then a title transformed by CONTENT rules.
        // That fallback is distinct from the title-only rules used for the exported heading.
        val duplicateTitle = if (useReplace && raw.isNotEmpty() && raw != "null") {
            context.ensureActive()
            val original = ContentProcessor.removeDuplicateTitle(
                content = raw,
                bookName = snapshot.name,
                chapterTitle = chapter.title,
                displayTitle = null,
                useReplace = false,
            )
            checked(original.first, "去重正文")
            if (original.second) "" else {
                val originalTitle = checked(chapter.getDisplayTitle(), "去重标题")
                context.ensureActive()
                checked(rules.applyToContent(originalTitle, snapshot.origin, snapshot.name), "处理后去重标题")
            }
        } else ""

        context.ensureActive()
        // Preserve markup/image references for the document sanitizer and resource collector.
        // Do not flatten HTML, pre-escape it, or apply reader-only conversion/re-segmentation.
        val body = checked(
            processor.process(
                book = snapshot,
                chapter = chapter,
                content = raw,
                displayTitle = duplicateTitle,
                useReplace = useReplace,
                chineseConvert = 0,
                shouldRemoveSameTitle = true,
            ).content,
            "处理后正文",
        )
        context.ensureActive()
        return BookExportTransformedChapter(chapter.copy(title = title, isVip = false), body)
    }
}
