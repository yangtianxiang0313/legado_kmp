package io.legado.kmp.shared.domain.usecase

import io.legado.kmp.shared.domain.localbook.LocalBookByteSource
import io.legado.kmp.shared.domain.localbook.LocalBookFileResolver
import io.legado.kmp.shared.domain.localbook.ParsedTxtBook
import io.legado.kmp.shared.domain.localbook.TxtBookParser
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

class ParseTxtBookUseCase(
    private val parser: TxtBookParser,
    private val getTxtTocRules: GetTxtTocRulesUseCase
) {
    suspend operator fun invoke(book: Book, bytes: ByteArray): ParsedTxtBook {
        val rules = getTxtTocRules.getEnabled()
        return withContext(Dispatchers.Default) {
            val context = currentCoroutineContext()
            parser.parse(book, bytes, rules) { context.ensureActive() }
        }
    }

    suspend fun parseSource(book: Book, source: LocalBookByteSource): ParsedTxtBook {
        val rules = getTxtTocRules.getEnabled()
        return withContext(Dispatchers.Default) {
            val context = currentCoroutineContext()
            parser.parseSource(book, source, rules) { context.ensureActive() }
        }
    }
}

class LoadTxtChapterContentUseCase(
    private val parser: TxtBookParser
) {
    operator fun invoke(bytes: ByteArray, chapter: BookChapter, charsetName: String): String {
        return parser.readContent(bytes, chapter, charsetName)
    }
}

class ParseTxtLocalFileUseCase(
    private val localBookFileResolver: LocalBookFileResolver,
    private val parseTxtBook: ParseTxtBookUseCase
) {
    suspend operator fun invoke(book: Book): ParsedTxtBook = withContext(Dispatchers.Default) {
        currentCoroutineContext().ensureActive()
        val resolved = localBookFileResolver.openRead(book)
        try {
            parseTxtBook.parseSource(resolved.book, resolved.source)
        } finally {
            resolved.source.closeSource()
        }
    }
}

class LoadTxtLocalChapterContentUseCase(
    private val localBookFileResolver: LocalBookFileResolver,
    private val parser: TxtBookParser
) {
    suspend operator fun invoke(book: Book, chapter: BookChapter): String = withContext(Dispatchers.Default) {
        val context = currentCoroutineContext()
        context.ensureActive()
        val resolved = localBookFileResolver.openRead(book)
        try {
            parser.readSourceContent(resolved.source, chapter, resolved.book.charset) { context.ensureActive() }
        } finally {
            resolved.source.closeSource()
        }
    }
}

class IsLocalBookModifiedUseCase(
    private val localBookFileResolver: LocalBookFileResolver
) {
    suspend operator fun invoke(book: Book): Boolean {
        if (!book.isLocal) return false
        val lastModified = localBookFileResolver.lastModified(book) ?: return false
        return lastModified > book.latestChapterTime
    }
}
