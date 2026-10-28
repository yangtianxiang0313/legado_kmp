package io.legado.kmp.shared.facade

import io.legado.kmp.shared.bootstrap.SharedBootstrap
import io.legado.kmp.shared.domain.localbook.LocalBookFileResolver
import io.legado.kmp.shared.domain.localbook.PdfBookParser
import io.legado.kmp.shared.domain.usecase.GetBookUseCase
import io.legado.kmp.shared.model.Book
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.koin.mp.KoinPlatformTools

data class PdfReaderDocument(val book: Book, val filePath: String)

/** Resolves retained ZIP originals and sandbox relocations without changing the database identity. */
class PdfReaderDocumentFacade(
    private val books: GetBookUseCase,
    private val resolver: LocalBookFileResolver,
    private val parser: PdfBookParser,
) {
    companion object {
        @Throws(RecoverableSharedException::class)
        fun create(): PdfReaderDocumentFacade = try {
            SharedBootstrap.startOrThrow()
            val koin = KoinPlatformTools.defaultContext().get()
            PdfReaderDocumentFacade(koin.get(), koin.get(), koin.get())
        } catch (error: Exception) {
            throw error.asRecoverableSharedException("PdfReaderDocumentFacade.create")
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun resolve(bookUrl: String): PdfReaderDocument = runRecoverable("PdfReaderDocument.resolve") {
        withContext(Dispatchers.Default) {
            val book = requireNotNull(books.get(bookUrl)) { "书籍已移除" }
            require(book.isLocal && book.bookUrl.substringAfterLast('.').equals("pdf", true)) { "不是本地 PDF" }
            val resolved = resolver.resolve(book)
            PdfReaderDocument(book, parser.documentPath(resolved))
        }
    }
}
