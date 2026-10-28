package io.legado.kmp.shared.facade

enum class AutomaticBackupOutcome {
    SAVED, ALREADY_PRESENT, NOT_CONFIGURED, PASSWORD_REQUIRED, NOT_DUE, BACKING_OFF, BUSY, CANCELLED, FAILED,
}

/** Unix milliseconds. A zero nextAttemptTime means wait for a configuration/password/lifecycle event. */
data class AutomaticBackupResult(
    val outcome: AutomaticBackupOutcome,
    val lastSuccessTime: Long = 0,
    val nextAttemptTime: Long = 0,
    val localFile: String? = null,
    val cloudFile: String? = null,
    val warnings: List<String> = emptyList(),
    val errorCode: String? = null,
    val errorMessage: String? = null,
)

data class AutomaticBackupLocalResult(val file: String? = null, val cancelled: Boolean = false)

/** One writer per request. The native implementation must cancel its pending I/O when cancelled. */
interface AutomaticBackupLocalWriter {
    fun save(
        archive: AndroidBackupExport,
        configuration: AutomaticBackupConfiguration,
        onResult: (AutomaticBackupLocalResult) -> Unit,
    )
    fun cancel()
}
