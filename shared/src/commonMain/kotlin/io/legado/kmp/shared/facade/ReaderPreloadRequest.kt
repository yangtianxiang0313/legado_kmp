package io.legado.kmp.shared.facade

/** Completion describes the best-effort job, not the number of fully cached chapters. */
data class ReaderPreloadResult(
    val completed: Boolean = false,
    val errorMessage: String? = null,
    val isCancelled: Boolean = false,
) {
    override fun toString(): String =
        "ReaderPreloadResult(completed=$completed, redacted, isCancelled=$isCancelled)"
}

class ReaderPreloadRequest(private val facade: ReaderFacade) {
    /** Delivers one terminal result on the completing thread, not necessarily the UI thread. */
    fun preload(
        bookUrl: String,
        chapterIndex: Int,
        preDownloadNum: Int = -1,
        onResult: (ReaderPreloadResult) -> Unit,
    ): FlowSubscription = start("preload", onResult) {
        facade.preloadAdjacentChapters(bookUrl, chapterIndex, preDownloadNum)
    }

    /** Cache-only work after display; persisted zero still keeps the layout's adjacent chapters. */
    fun preloadDisplayedChapter(
        bookUrl: String,
        chapterIndex: Int,
        onResult: (ReaderPreloadResult) -> Unit,
    ): FlowSubscription = start("preloadDisplayedChapter", onResult) {
        facade.cacheDisplayedChapter(bookUrl, chapterIndex)
    }

    private fun start(
        method: String,
        onResult: (ReaderPreloadResult) -> Unit,
        prepare: suspend () -> Unit,
    ): FlowSubscription = CancellableFacadeRequest.start(
        prepare = {
            prepare()
            ReaderPreloadResult(completed = true)
        },
        cancelledResult = ReaderPreloadResult(isCancelled = true),
        failureResult = { ReaderPreloadResult(errorMessage = "章节预下载失败，请重试") },
        onResult = { result ->
            try {
                onResult(result)
            } catch (error: Throwable) {
                findFacadeRequestCancellation(error)?.let { throw it }
                throw IllegalStateException("预下载结果回调失败")
            }
        },
        facade = "ReaderPreloadRequest",
        callbackMethod = "$method.onResult",
        missingResultMessage = "Preload request completed without a result",
    )
}
