package io.legado.kmp.shared.facade

import kotlin.coroutines.cancellation.CancellationException

data class ReaderChapterRequestResult(
    val payload: ReaderChapterPayload?,
    val errorCode: String?,
    val errorMessage: String?,
    val isCancelled: Boolean,
)

internal object ReaderChapterRequest {
    fun start(
        prepare: suspend () -> ReaderChapterPayload,
        onResult: (ReaderChapterRequestResult) -> Unit,
    ): FlowSubscription = CancellableFacadeRequest.start(
        prepare = {
            ReaderChapterRequestResult(prepare(), null, null, isCancelled = false)
        },
        cancelledResult = ReaderChapterRequestResult(null, null, null, isCancelled = true),
        failureResult = ::failureResult,
        onResult = onResult,
        facade = "ReaderFacade",
        callbackMethod = "prepareChapterRequest.onResult",
        missingResultMessage = "Chapter request completed without a payload",
    )

    private fun failureResult(error: Throwable): ReaderChapterRequestResult {
        val failure = error.asRecoverableSharedException("ReaderFacade.prepareChapter")
        return ReaderChapterRequestResult(null, failure.code, failure.message, isCancelled = false)
    }
}

internal fun findReaderChapterCancellation(error: Throwable?): CancellationException? =
    findFacadeRequestCancellation(error)
