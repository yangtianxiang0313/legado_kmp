package io.legado.kmp.shared.facade

import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookProgress
import kotlin.coroutines.AbstractCoroutineContextElement
import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.withContext

/** A confirmation applies only to the source and persisted revision actually shown to the user. */
internal class ReaderProgressExpectation(val book: Book) : AbstractCoroutineContextElement(Key) {
    companion object Key : CoroutineContext.Key<ReaderProgressExpectation>
}

data class ReaderProgressSyncResponse(
    val result: SyncProgressResult? = null,
    val progress: BookProgress? = null,
    val payload: ReaderChapterPayload? = null,
    val errorCode: String? = null,
    val errorMessage: String? = null,
    val isCancelled: Boolean = false,
)

/** Cancellable bridge around the existing ReaderFacade path; no additional facade/DI lifetime. */
class ReaderProgressSyncClient(private val reader: ReaderFacade, private val settings: SettingsFacade) {
    fun syncRequest(bookUrl: String, onResult: (ReaderProgressSyncResponse) -> Unit): FlowSubscription =
        request("syncRequest", onResult) { ReaderProgressSyncResponse(result = reader.syncProgress(bookUrl)) }

    fun syncExpectedRequest(book: Book, onResult: (ReaderProgressSyncResponse) -> Unit): FlowSubscription =
        request("syncExpectedRequest", onResult) {
            withContext(ReaderProgressExpectation(book.copy(readConfig = book.readConfig?.copy()))) {
                ReaderProgressSyncResponse(result = reader.syncProgress(book.bookUrl))
            }
        }

    fun syncBookRequest(book: Book, onResult: (ReaderProgressSyncResponse) -> Unit): FlowSubscription =
        request("syncBookRequest", onResult) {
            ReaderProgressSyncResponse(result = settings.syncReaderBookProgress(book))
        }

    fun readRequest(book: Book, onResult: (ReaderProgressSyncResponse) -> Unit): FlowSubscription =
        request("readRequest", onResult) {
            if (book.isNotShelf) ReaderProgressSyncResponse()
            else ReaderProgressSyncResponse(progress = settings.getBookProgress(book.name, book.author))
        }

    fun uploadRequest(book: Book, onResult: (ReaderProgressSyncResponse) -> Unit): FlowSubscription =
        request("uploadRequest", onResult) {
            if (!book.isNotShelf) settings.uploadBookProgress(book)
            ReaderProgressSyncResponse()
        }

    fun applyRequest(
        expected: Book,
        progress: BookProgress,
        onResult: (ReaderProgressSyncResponse) -> Unit,
    ): FlowSubscription {
        val snapshot = expected.copy(readConfig = expected.readConfig?.copy())
        return request("applyRequest", onResult) {
            if (snapshot.isNotShelf || progress.name != snapshot.name || progress.author != snapshot.author ||
                progress.durChapterIndex < 0 || progress.durChapterPos < 0
            ) {
                throw RecoverableSharedException("PROGRESS_INVALID", "云端进度与当前书籍不匹配")
            }
            withContext(ReaderProgressExpectation(snapshot)) {
                ReaderProgressSyncResponse(payload = reader.setProgress(snapshot.bookUrl, progress))
            }
        }
    }

    private fun request(
        method: String,
        onResult: (ReaderProgressSyncResponse) -> Unit,
        operation: suspend () -> ReaderProgressSyncResponse,
    ): FlowSubscription = CancellableFacadeRequest.start(
        prepare = operation,
        cancelledResult = ReaderProgressSyncResponse(isCancelled = true),
        failureResult = { error ->
            val failure = error.asRecoverableSharedException("ReaderProgressSyncClient.$method")
            ReaderProgressSyncResponse(errorCode = failure.code, errorMessage = failure.message)
        },
        onResult = onResult,
        facade = "ReaderProgressSyncClient",
        callbackMethod = "$method.onResult",
        missingResultMessage = "Progress request completed without a result",
    )
}
