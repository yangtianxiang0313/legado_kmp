package io.legado.kmp.shared.facade

import kotlin.coroutines.cancellation.CancellationException

class RecoverableSharedException(
    val code: String,
    override val message: String,
    override val cause: Throwable? = null,
) : Exception(message, cause)

internal suspend inline fun <T> runRecoverable(
    code: String,
    crossinline block: suspend () -> T,
): T {
    return try {
        block()
    } catch (throwable: Throwable) {
        if (throwable is CancellationException) {
            throw throwable
        }
        // Record to CrashCollector for crash analysis
        val parts = code.split(".", limit = 2)
        val facade = parts.getOrElse(0) { code }
        val method = parts.getOrElse(1) { "" }
        CrashCollector.record(facade, method, error = throwable)
        throw throwable.asRecoverableSharedException(code)
    }
}

internal fun Throwable.asRecoverableSharedException(code: String): RecoverableSharedException {
    if (this is RecoverableSharedException) {
        return this
    }
    val resolvedMessage = message?.takeIf { it.isNotBlank() } ?: "Shared operation failed: $code"
    return RecoverableSharedException(
        code = code,
        message = resolvedMessage,
        cause = this,
    )
}
