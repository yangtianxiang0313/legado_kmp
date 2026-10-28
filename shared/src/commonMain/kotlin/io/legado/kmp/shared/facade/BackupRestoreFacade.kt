package io.legado.kmp.shared.facade

data class BackupRestoreRequestResult(
    val result: BackupRestoreResult? = null,
    val errorMessage: String? = null,
    val errorCode: String? = null,
    val isCancelled: Boolean = false,
)

/** Completion is delivered only after the transaction and any accepted settings application settle. */
class BackupRestoreFacade(private val settings: SettingsFacade) {
    fun restore(
        payload: String,
        password: String?,
        onResult: (BackupRestoreRequestResult) -> Unit,
    ): FlowSubscription = CancellableFacadeRequest.start(
        prepare = { BackupRestoreRequestResult(result = settings.restoreFromBackup(payload, password)) },
        cancelledResult = BackupRestoreRequestResult(isCancelled = true),
        failureResult = { error ->
            val safe = error as? RecoverableSharedException
            BackupRestoreRequestResult(
                errorCode = safe?.code ?: "BACKUP_RESTORE_FAILED",
                errorMessage = safe?.message ?: "备份恢复失败，请检查备份后重试",
            )
        },
        onResult = onResult,
        facade = "BackupRestoreFacade",
        callbackMethod = "restore",
        missingResultMessage = "Backup restoration unavailable",
    )
}
