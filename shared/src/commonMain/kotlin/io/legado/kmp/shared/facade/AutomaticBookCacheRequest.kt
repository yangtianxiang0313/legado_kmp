package io.legado.kmp.shared.facade

data class AutomaticBookCacheResult(
    val summary: BookDownloadSummary? = null,
    val errorMessage: String? = null,
    val isCancelled: Boolean = false,
) {
    override fun toString(): String = "AutomaticBookCacheResult(redacted, isCancelled=$isCancelled)"
}

class AutomaticBookCacheRequest(private val facade: CacheFacade) {
    fun download(
        bookUrl: String,
        startIndex: Int,
        endIndex: Int,
        onProgress: (CacheProgress) -> Unit,
        onResult: (AutomaticBookCacheResult) -> Unit,
    ): FlowSubscription = CancellableFacadeRequest.start(
        prepare = {
            facade.downloadAutomatically(bookUrl, startIndex, endIndex, onProgress)
            AutomaticBookCacheResult(summary = facade.getDownloadSummaryForBook(bookUrl))
        },
        cancelledResult = AutomaticBookCacheResult(isCancelled = true),
        failureResult = { AutomaticBookCacheResult(errorMessage = "自动缓存失败，请重新更新目录后重试") },
        onResult = { result ->
            try {
                onResult(result)
            } catch (error: Throwable) {
                findFacadeRequestCancellation(error)?.let { throw it }
                throw IllegalStateException("Automatic cache callback failed")
            }
        },
        facade = "AutomaticBookCacheRequest",
        callbackMethod = "download.onResult",
        missingResultMessage = "Automatic cache completed without a result",
    )
}
