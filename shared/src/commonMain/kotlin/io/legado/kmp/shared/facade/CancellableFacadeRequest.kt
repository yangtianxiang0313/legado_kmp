package io.legado.kmp.shared.facade

import kotlin.coroutines.cancellation.CancellationException
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancel
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch

internal object CancellableFacadeRequest {
    fun <T : Any> start(
        prepare: suspend () -> T,
        cancelledResult: T,
        failureResult: (Throwable) -> T,
        onResult: (T) -> Unit,
        facade: String,
        callbackMethod: String,
        missingResultMessage: String,
    ): FlowSubscription {
        val scope = CoroutineScope(Dispatchers.Default)
        var result: T? = null
        val job = scope.launch(start = CoroutineStart.LAZY) {
            try {
                coroutineContext.ensureActive()
                val prepared = prepare()
                coroutineContext.ensureActive()
                result = prepared
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                coroutineContext.ensureActive()
                findFacadeRequestCancellation(error)?.let { throw it }
                result = failureResult(error)
            }
        }
        // Completion also runs when cancellation prevents the coroutine body from starting.
        job.invokeOnCompletion { cause ->
            val terminalResult = when {
                job.isCancelled || findFacadeRequestCancellation(cause) != null -> cancelledResult
                cause != null -> failureResult(cause)
                else -> result ?: failureResult(IllegalStateException(missingResultMessage))
            }
            scope.cancel()
            try {
                onResult(terminalResult)
            } catch (error: Throwable) {
                if (findFacadeRequestCancellation(error) == null) {
                    CrashCollector.record(facade, callbackMethod, error = error)
                }
            }
        }
        job.start()
        return FlowSubscription(job)
    }
}

internal fun findFacadeRequestCancellation(error: Throwable?): CancellationException? {
    var current = error
    val visited = mutableSetOf<Throwable>()
    while (current != null && visited.add(current)) {
        if (current is CancellationException) return current
        current = current.cause
    }
    return null
}
