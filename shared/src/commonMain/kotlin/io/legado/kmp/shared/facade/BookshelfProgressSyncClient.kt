package io.legado.kmp.shared.facade

data class BookshelfProgressSyncResult(
    val updatedCount: Int = 0,
    val skippedCount: Int = 0,
    val failedCount: Int = 0,
    val disabled: Boolean = false,
)

data class BookshelfProgressSyncResponse(
    val result: BookshelfProgressSyncResult? = null,
    val errorCode: String? = null,
    val errorMessage: String? = null,
    val isCancelled: Boolean = false,
)

/** Native startup waits for the actual terminal callback, including cancellation of an active GET. */
class BookshelfProgressSyncClient(private val settings: SettingsFacade) {
    fun syncRequest(onResult: (BookshelfProgressSyncResponse) -> Unit): FlowSubscription = CancellableFacadeRequest.start(
        prepare = { BookshelfProgressSyncResponse(result = settings.syncBookshelfProgress()) },
        cancelledResult = BookshelfProgressSyncResponse(isCancelled = true),
        failureResult = { error ->
            val safe = error as? RecoverableSharedException
            BookshelfProgressSyncResponse(
                errorCode = safe?.code ?: "PROGRESS_SYNC_FAILED",
                errorMessage = "书架云端进度同步失败，请检查 WebDAV 配置和网络后重试",
            )
        },
        onResult = onResult,
        facade = "BookshelfProgressSyncClient",
        callbackMethod = "syncRequest.onResult",
        missingResultMessage = "Bookshelf progress synchronization unavailable",
    )
}
