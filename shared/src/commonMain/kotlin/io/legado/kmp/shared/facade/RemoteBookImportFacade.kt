package io.legado.kmp.shared.facade

import io.legado.kmp.shared.bootstrap.SharedBootstrap
import io.legado.kmp.shared.domain.localbook.RemoteBookOrigin
import io.legado.kmp.shared.domain.repository.BookRepository
import io.legado.kmp.shared.model.Book
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import org.koin.mp.KoinPlatformTools
import kotlin.coroutines.cancellation.CancellationException

/** Associates an already committed platform import; it never imports or rewrites the whole book. */
class RemoteBookImportFacade(private val bookRepository: BookRepository) {
    companion object {
        @Throws(RecoverableSharedException::class, CancellationException::class)
        fun create(): RemoteBookImportFacade = try {
            SharedBootstrap.startOrThrow()
            RemoteBookImportFacade(KoinPlatformTools.defaultContext().get().get<BookRepository>())
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            throw RecoverableSharedException("REMOTE_BOOK_SERVICE_UNAVAILABLE", "远程书籍来源服务不可用，请重试")
        }
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun associateImportedBook(remoteOrigin: String, expectedLocalBook: Book): Book =
        remoteBookOperation("ASSOCIATION_FAILED", "无法关联远程书籍来源，原书籍未被替换") {
            currentCoroutineContext().ensureActive()
            val origin = RemoteBookOrigin.parse(remoteOrigin)
                ?: throw RecoverableSharedException("REMOTE_BOOK_INVALID_ORIGIN", "远程书籍来源无效")
            bookRepository.associateRemoteOriginIfUnchanged(origin.encoded, expectedLocalBook)
                ?: throw RecoverableSharedException(
                    "REMOTE_BOOK_ASSOCIATION_CONFLICT", "书籍已被删除或身份、来源、变量发生变化，请刷新后重新关联",
                )
        }
}

internal suspend inline fun <T> remoteBookOperation(code: String, message: String, block: () -> T): T = try {
    block()
} catch (cancelled: CancellationException) {
    throw cancelled
} catch (error: Exception) {
    // Platform/parser/network exceptions may include local paths, URLs or credentials.
    if (error is RecoverableSharedException && error.code.startsWith("REMOTE_BOOK_")) throw error
    throw RecoverableSharedException("REMOTE_BOOK_$code", message)
}
