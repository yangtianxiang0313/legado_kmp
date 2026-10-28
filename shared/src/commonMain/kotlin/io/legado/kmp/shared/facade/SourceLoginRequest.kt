package io.legado.kmp.shared.facade

import io.legado.kmp.shared.model.StoredHttpCookie
import kotlin.coroutines.cancellation.CancellationException

data class SourceLoginRequestResult(
    val configuration: SourceLoginConfiguration? = null,
    val loginResult: SourceLoginResult? = null,
    val cookies: List<StoredHttpCookie>? = null,
    val cookieSeed: SourceLoginCookieSeed? = null,
    val loginHeader: String? = null,
    val completed: Boolean = false,
    val errorCode: String? = null,
    val errorMessage: String? = null,
    val isCancelled: Boolean = false,
)

internal object SourceLoginRequest {
    fun start(
        method: String,
        prepare: suspend () -> SourceLoginRequestResult,
        onResult: (SourceLoginRequestResult) -> Unit,
    ): FlowSubscription = CancellableFacadeRequest.start(
        prepare = prepare,
        cancelledResult = SourceLoginRequestResult(isCancelled = true),
        failureResult = {
            SourceLoginRequestResult(
                errorCode = "SourceLoginFacade.$method",
                errorMessage = "书源登录操作失败，请检查登录配置后重试",
            )
        },
        onResult = { result ->
            try {
                onResult(result)
            } catch (error: CancellationException) {
                throw error
            } catch (_: Throwable) {
                // CancellableFacadeRequest logs callback failures. Strip any sensitive payload first.
                throw IllegalStateException("Source login callback failed")
            }
        },
        facade = "SourceLoginFacade",
        callbackMethod = method,
        missingResultMessage = "Source login result unavailable",
    )
}
