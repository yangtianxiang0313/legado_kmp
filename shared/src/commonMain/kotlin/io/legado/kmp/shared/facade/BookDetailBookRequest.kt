package io.legado.kmp.shared.facade

import io.legado.kmp.shared.model.Book

data class BookDetailBookRequestResult(
    val book: Book?,
    val errorCode: String?,
    val errorMessage: String?,
    val isCancelled: Boolean,
)

internal object BookDetailBookRequest {
    fun start(
        refresh: suspend () -> Book,
        onResult: (BookDetailBookRequestResult) -> Unit,
    ): FlowSubscription = CancellableFacadeRequest.start(
        prepare = {
            BookDetailBookRequestResult(refresh(), null, null, isCancelled = false)
        },
        cancelledResult = BookDetailBookRequestResult(null, null, null, isCancelled = true),
        failureResult = ::failureResult,
        onResult = onResult,
        facade = "BookDetailFacade",
        callbackMethod = "refreshInfoRequest.onResult",
        missingResultMessage = "Book info refresh request completed without a result",
    )

    private fun failureResult(error: Throwable): BookDetailBookRequestResult {
        val failure = error.asRecoverableSharedException("BookDetailFacade.refreshInfo")
        return BookDetailBookRequestResult(null, failure.code, failure.message, isCancelled = false)
    }
}
