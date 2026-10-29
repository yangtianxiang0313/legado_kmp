package io.legado.kmp.shared.facade

import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch

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
    val prepared: PreparedCloudBackup? = null,
)

internal object CloudBackupRequest {
    /** A claimed commit publishes its actual outcome before returning to a cancelled caller. */
    fun startSettled(
        method: String,
        action: suspend ((CloudBackupRequestResult) -> Unit) -> CloudBackupRequestResult,
        onResult: (CloudBackupRequestResult) -> Unit,
    ): FlowSubscription {
        val scope = CoroutineScope(Dispatchers.Default)
        val committed = MutableStateFlow<CloudBackupRequestResult?>(null)
        var result: CloudBackupRequestResult? = null
        val job = scope.launch(start = CoroutineStart.LAZY) {
            try {
                currentCoroutineContext().ensureActive()
                result = action { committed.value = it }
                currentCoroutineContext().ensureActive()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                if (committed.value == null) {
                    currentCoroutineContext().ensureActive()
                    findFacadeRequestCancellation(error)?.let { throw it }
                    result = failure(error)
                }
            }
        }
        // Never notify from cancel(): wait for all non-cancellable persistence and cleanup to settle.
        job.invokeOnCompletion { cause ->
            val terminal = committed.value ?: when {
                job.isCancelled || findFacadeRequestCancellation(cause) != null -> {
                    result?.prepared?.discard()
                    CloudBackupRequestResult(isCancelled = true)
                }
                cause != null -> failure(cause)
                else -> result ?: failure(IllegalStateException("Cloud backup result unavailable"))
            }
            scope.cancel()
            try {
                onResult(terminal)
            } catch (_: Throwable) {
                terminal.prepared?.discard()
                CrashCollector.record(
                    "CloudBackupFacade", method, error = IllegalStateException("Cloud backup callback failed"),
                )
            }
        }
        job.start()
        return FlowSubscription(job)
    }

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

    private fun failure(error: Throwable): CloudBackupRequestResult {
        val safe = error as? RecoverableSharedException
        return CloudBackupRequestResult(
            errorCode = safe?.code ?: "CLOUD_BACKUP_FAILED",
            errorMessage = safe?.message ?: "云备份操作失败，请检查配置和网络后重试",
        )
    }
}

internal fun cloudBackupError(code: String, message: String): Nothing =
    throw RecoverableSharedException(code, message)
