package io.legado.kmp.shared.facade

import io.legado.kmp.shared.preferences.ReaderRuntimeConfig
import io.legado.kmp.shared.preferences.ReaderStylePreferences

data class ReaderPaginationResult(
    val layout: ReaderChapterLayout? = null,
    val errorMessage: String? = null,
    val isCancelled: Boolean = false,
) {
    override fun toString(): String = "ReaderPaginationResult(redacted, isCancelled=$isCancelled)"
}

class ReaderPaginationRequest(private val facade: ReaderFacade) {
    fun paginate(
        chapterIndex: Int,
        chapterTitle: String,
        content: String,
        style: ReaderStylePreferences,
        runtime: ReaderRuntimeConfig,
        viewport: ReaderViewport,
        imageStyle: String?,
        onResult: (ReaderPaginationResult) -> Unit,
    ): FlowSubscription = CancellableFacadeRequest.start(
        prepare = {
            ReaderPaginationResult(
                layout = facade.paginateChapter(
                    chapterIndex = chapterIndex,
                    chapterTitle = chapterTitle,
                    content = content,
                    style = style,
                    runtime = runtime,
                    viewport = viewport,
                    imageStyle = imageStyle,
                ),
            )
        },
        cancelledResult = ReaderPaginationResult(isCancelled = true),
        failureResult = { ReaderPaginationResult(errorMessage = "章节分页失败，请重试") },
        onResult = { result ->
            try {
                onResult(result)
            } catch (error: Throwable) {
                findFacadeRequestCancellation(error)?.let { throw it }
                throw IllegalStateException("分页结果回调失败")
            }
        },
        facade = "ReaderPaginationRequest",
        callbackMethod = "paginate.onResult",
        missingResultMessage = "Pagination request completed without a result",
    )
}
