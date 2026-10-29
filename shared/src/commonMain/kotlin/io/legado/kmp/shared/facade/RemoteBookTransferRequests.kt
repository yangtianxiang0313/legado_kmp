package io.legado.kmp.shared.facade

/** Cancels the actual Kotlin job/Ktor request, then delivers exactly one terminal callback. */
internal fun remoteBookTransferRequest(
    method: String,
    mutation: RemoteBookMutation? = null,
    onResult: (RemoteBookTransferResult) -> Unit,
    prepare: suspend () -> RemoteBookTransferResult,
): FlowSubscription = CancellableFacadeRequest.start(
    prepare = prepare,
    cancelledResult = RemoteBookTransferResult(isCancelled = true),
    failureResult = { error ->
        val message = (error as? RecoverableSharedException)?.takeIf {
            it.code.startsWith("RemoteBookTransferFacade.")
        }?.message ?: mutation?.outcomeMessage() ?: "远程书库操作失败，请重试"
        RemoteBookTransferResult(errorMessage = message)
    },
    onResult = { result ->
        val terminal = if (result.isCancelled) result.copy(errorMessage = mutation?.outcomeMessage()) else result
        try {
            onResult(terminal)
        } catch (_: Throwable) {
            // CancellableFacadeRequest logs callback failures; never forward user-provided diagnostics.
            throw IllegalStateException("Remote book transfer callback failed")
        }
    },
    facade = "RemoteBookTransferFacade",
    callbackMethod = "$method.onResult",
    missingResultMessage = "Remote book transfer result unavailable",
)
