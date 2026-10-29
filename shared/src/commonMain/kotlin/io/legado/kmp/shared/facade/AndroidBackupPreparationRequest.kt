package io.legado.kmp.shared.facade

import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

data class AndroidBackupPreparationResult(
    val prepared: AndroidBackupImport? = null,
    val errorCode: String? = null,
    val errorMessage: String? = null,
    val isCancelled: Boolean = false,
) {
    override fun toString(): String = "AndroidBackupPreparationResult(redacted, isCancelled=$isCancelled)"
}

/** Prepares in memory on Dispatchers.Default; never writes rows or preferences. */
class AndroidBackupPreparationRequest {
    /**
     * Delivers one background callback after the Kotlin job reaches its terminal state.
     * Cancellation is cooperative: individual Base64/JSON/crypto materializations are not interruptible.
     */
    fun prepare(
        base64Zip: String,
        password: String,
        onResult: (AndroidBackupPreparationResult) -> Unit,
    ): FlowSubscription = CancellableFacadeRequest.start(
        prepare = {
            val context = currentCoroutineContext()
            AndroidBackupPreparationResult(
                prepared = AndroidBackupArchive().convert(base64Zip, password) { context.ensureActive() },
            )
        },
        cancelledResult = AndroidBackupPreparationResult(isCancelled = true),
        failureResult = {
            // Never expose ZIP names, JSON contents, passwords or arbitrary exception messages.
            AndroidBackupPreparationResult(
                errorCode = "INVALID_ANDROID_BACKUP",
                errorMessage = "Android 备份无法读取：文件损坏、格式无效或超过大小上限",
            )
        },
        onResult = { result ->
            try {
                onResult(result)
            } catch (error: Throwable) {
                findFacadeRequestCancellation(error)?.let { throw it }
                throw IllegalStateException("Android backup preparation callback failed")
            }
        },
        facade = "AndroidBackupPreparationRequest",
        callbackMethod = "prepare.onResult",
        missingResultMessage = "Android backup preparation completed without a result",
    )
}
