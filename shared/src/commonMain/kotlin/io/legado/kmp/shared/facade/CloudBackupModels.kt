package io.legado.kmp.shared.facade

import kotlin.coroutines.cancellation.CancellationException

/** Times are Unix milliseconds; a zero size/time means the server did not supply that property. */
data class CloudBackupFile(val name: String, val size: Long, val lastModified: Long) {
    // Not part of value equality, serialization or toString; copying a file does not copy authority.
    internal var origin: CloudBackupConfiguration? = null
}

data class CloudBackupUpload(val file: CloudBackupFile, val warnings: List<String>)
data class CloudBackupRestore(val result: BackupRestoreResult, val warnings: List<String>)

data class CloudBackupRequestResult(
    val files: List<CloudBackupFile>? = null,
    val upload: CloudBackupUpload? = null,
    val restored: CloudBackupRestore? = null,
    val newBackup: CloudBackupFile? = null,
    val completed: Boolean = false,
    val errorMessage: String? = null,
    val isCancelled: Boolean = false,
    val errorCode: String? = null,
)

internal object CloudBackupRequest {
    fun start(
        method: String,
        prepare: suspend () -> CloudBackupRequestResult,
        onResult: (CloudBackupRequestResult) -> Unit,
    ): FlowSubscription = CancellableFacadeRequest.start(
        prepare = prepare,
        cancelledResult = CloudBackupRequestResult(isCancelled = true),
        failureResult = { error ->
            val safe = error as? RecoverableSharedException
            CloudBackupRequestResult(
                errorCode = safe?.code ?: "CLOUD_BACKUP_FAILED",
                errorMessage = safe?.message ?: "云备份操作失败，请检查配置和网络后重试",
            )
        },
        onResult = { result ->
            try {
                onResult(result)
            } catch (error: CancellationException) {
                throw error
            } catch (_: Throwable) {
                // Do not let callback exceptions log a password, response body or backup payload.
                throw IllegalStateException("Cloud backup callback failed")
            }
        },
        facade = "CloudBackupFacade",
        callbackMethod = method,
        missingResultMessage = "Cloud backup result unavailable",
    )
}

internal fun cloudBackupError(code: String, message: String): Nothing =
    throw RecoverableSharedException(code, message)
