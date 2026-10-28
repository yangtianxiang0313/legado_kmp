package io.legado.kmp.shared.facade

data class BookDetailChapterRequestResult(
    val result: BookDetailRefreshResult?,
    val errorCode: String?,
    val errorMessage: String?,
    val isCancelled: Boolean,
)

internal object BookDetailChapterRequest {
    fun start(
        refresh: suspend () -> BookDetailRefreshResult,
        onResult: (BookDetailChapterRequestResult) -> Unit,
    ): FlowSubscription = CancellableFacadeRequest.start(
        prepare = {
            BookDetailChapterRequestResult(refresh(), null, null, isCancelled = false)
        },
        cancelledResult = BookDetailChapterRequestResult(null, null, null, isCancelled = true),
        failureResult = ::failureResult,
        onResult = onResult,
        facade = "BookDetailFacade",
        callbackMethod = "refreshChaptersRequest.onResult",
        missingResultMessage = "Chapter refresh request completed without a result",
    )

    private fun failureResult(error: Throwable): BookDetailChapterRequestResult {
        val failure = error.asRecoverableSharedException("BookDetailFacade.refreshChapters")
        return BookDetailChapterRequestResult(null, failure.code, failure.message, isCancelled = false)
    }
}
