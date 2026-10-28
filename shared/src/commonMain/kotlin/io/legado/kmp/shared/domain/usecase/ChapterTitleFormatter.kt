package io.legado.kmp.shared.domain.usecase

import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter

internal suspend fun resolveDisplayChapterTitle(
    book: Book,
    chapter: BookChapter,
    applyReplaceRulesUseCase: ApplyReplaceRulesUseCase,
): String {
    val useReplaceRule = book.config.useReplaceRule ?: (!book.isImage && !book.isEpub)
    if (!useReplaceRule) {
        return chapter.getDisplayTitle()
    }
    val formatted = applyReplaceRulesUseCase.applyToTitle(chapter.title, book.origin, book.name)
    return chapter.copy(title = formatted).getDisplayTitle()
}
