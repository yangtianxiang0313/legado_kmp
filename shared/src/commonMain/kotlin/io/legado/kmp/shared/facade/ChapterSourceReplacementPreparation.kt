package io.legado.kmp.shared.facade

class PreparedChapterSourceReplacement internal constructor(
    private val snapshot: ChapterSourceReplacementCommitSnapshot,
    private val ownerToken: Any,
) {
    private var consumed = false

    val originalBookUrl: String = snapshot.target.bookUrl
    val currentChapterIndex: Int = snapshot.target.chapterIndex
    val currentChapterUrl: String = snapshot.target.chapterUrl

    // Only the owning support calls this, while holding its consume mutex.
    internal fun consume(ownerToken: Any): ChapterSourceReplacementCommitSnapshot {
        if (this.ownerToken !== ownerToken) {
            throw RecoverableSharedException(
                "CHAPTER_SOURCE_REPLACEMENT_OWNER_MISMATCH",
                "Prepared chapter replacement belongs to another owner",
            )
        }
        if (consumed) {
            throw RecoverableSharedException(
                "CHAPTER_SOURCE_REPLACEMENT_ALREADY_CONSUMED",
                "Prepared chapter replacement has already been consumed",
            )
        }
        consumed = true
        return snapshot
    }

    override fun toString(): String = "PreparedChapterSourceReplacement(redacted)"
}

data class ChapterSourceReplacementPreparationResult(
    val prepared: PreparedChapterSourceReplacement? = null,
    val errorCode: String? = null,
    val errorMessage: String? = null,
    val isCancelled: Boolean = false,
) {
    override fun toString(): String =
        "ChapterSourceReplacementPreparationResult(redacted, isCancelled=$isCancelled)"
}

internal object ChapterSourceReplacementPreparationRequest {
    fun start(
        prepare: suspend () -> PreparedChapterSourceReplacement,
        onResult: (ChapterSourceReplacementPreparationResult) -> Unit,
    ): FlowSubscription = CancellableFacadeRequest.start(
        prepare = { ChapterSourceReplacementPreparationResult(prepared = prepare()) },
        cancelledResult = ChapterSourceReplacementPreparationResult(isCancelled = true),
        failureResult = ::failureResult,
        onResult = onResult,
        facade = "BookDetailFacade",
        callbackMethod = "prepareChapterSourceReplacementRequest.onResult",
        missingResultMessage = "Chapter replacement preparation completed without a result",
    )

    private fun failureResult(error: Throwable): ChapterSourceReplacementPreparationResult {
        val failure = error.asRecoverableSharedException("BookDetailFacade.prepareChapterSourceReplacement")
        return ChapterSourceReplacementPreparationResult(errorCode = failure.code, errorMessage = failure.message)
    }
}
