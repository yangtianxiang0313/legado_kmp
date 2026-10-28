package io.legado.kmp.shared.facade

import io.legado.kmp.shared.preferences.AppPreferencesStore
import io.legado.kmp.shared.preferences.AppRuntimeConfig
import io.legado.kmp.shared.util.currentTimeMillis
import kotlin.coroutines.cancellation.CancellationException
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ensureActive

/** Policy/execution only. iOS owns opportunities, protected file I/O and encryption-password storage. */
class AutomaticBackupEngine internal constructor(
    private val preferences: AppPreferencesStore,
    private val settings: SettingsFacade,
    private val cloudFacade: CloudBackupFacade,
) {
    private val state = AutomaticBackupState(preferences)
    private val cloudState = CloudBackupState(preferences)

    @Throws(RecoverableSharedException::class)
    fun configuration(): AutomaticBackupConfiguration = AutomaticBackupConfiguration(
        preferences.runtimeConfig.value.let { it.copy(backupRestoreIgnoredKeys = it.backupRestoreIgnoredKeys.toSet()) },
    )

    fun watchConfiguration(onUpdate: (AppRuntimeConfig) -> Unit): FlowSubscription =
        watchFlow(preferences.runtimeConfig, onUpdate, label = "AutomaticBackupEngine.configuration")

    /** Read-only UI snapshot; runRequest rechecks under the shared manual/automatic operation gate. */
    @Throws(RecoverableSharedException::class)
    fun schedule(): AutomaticBackupResult {
        val plan = configuration()
        if (!plan.isConfigured) return AutomaticBackupResult(AutomaticBackupOutcome.NOT_CONFIGURED)
        val mark = state.read()[plan.identifier] ?: AutomaticBackupWatermark()
        val remoteSuccess = plan.cloud?.let { cloudState.read()[it.scope]?.let { value -> maxOf(value.uploadedTime, value.restoredTime) } } ?: 0
        val lastSuccess = maxOf(mark.lastSuccess, remoteSuccess)
        val due = AutomaticBackupState.nextDue(lastSuccess)
        val now = currentTimeMillis().coerceAtLeast(0)
        return AutomaticBackupResult(
            if (now < due) AutomaticBackupOutcome.NOT_DUE else if (now < mark.retryAfter) AutomaticBackupOutcome.BACKING_OFF else AutomaticBackupOutcome.PASSWORD_REQUIRED,
            lastSuccess, maxOf(due, mark.retryAfter),
        )
    }

    /** Password is transient and is never persisted by shared. Each call must use a fresh native writer. */
    fun runRequest(
        configuration: AutomaticBackupConfiguration,
        password: String?,
        writer: AutomaticBackupLocalWriter,
        onResult: (AutomaticBackupResult) -> Unit,
    ): FlowSubscription = CancellableFacadeRequest.start(
        prepare = { run(configuration, password, writer) },
        cancelledResult = AutomaticBackupResult(AutomaticBackupOutcome.CANCELLED),
        failureResult = { failure(it) },
        onResult = { result ->
            try { onResult(result) }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Throwable) { throw IllegalStateException("Automatic backup callback failed") }
        },
        facade = "AutomaticBackupEngine", callbackMethod = "runRequest",
        missingResultMessage = "Automatic backup result unavailable",
    )

    private suspend fun run(
        plan: AutomaticBackupConfiguration, password: String?, writer: AutomaticBackupLocalWriter,
    ): AutomaticBackupResult = cloudFacade.automaticOperation {
        requireActive(plan)
        if (!plan.isConfigured) return@automaticOperation AutomaticBackupResult(AutomaticBackupOutcome.NOT_CONFIGURED)
        val mark = state.read()[plan.identifier] ?: AutomaticBackupWatermark()
        val remoteMarks = cloudState.read()
        // A local-only manual save is not proof that a configured remote destination was saved.
        val remoteSuccess = plan.cloud?.let { remoteMarks[it.scope]?.let { mark -> maxOf(mark.uploadedTime, mark.restoredTime) } } ?: 0
        val lastSuccess = maxOf(mark.lastSuccess, remoteSuccess)
        val now = currentTimeMillis().coerceAtLeast(0)
        if (now < AutomaticBackupState.nextDue(lastSuccess)) return@automaticOperation AutomaticBackupResult(
            AutomaticBackupOutcome.NOT_DUE, lastSuccess, AutomaticBackupState.nextDue(lastSuccess),
        )
        if (now < mark.retryAfter) return@automaticOperation AutomaticBackupResult(
            AutomaticBackupOutcome.BACKING_OFF, lastSuccess,
            minOf(mark.retryAfter, now.coerceAtMost(Long.MAX_VALUE - AutomaticBackupState.MAX_RETRY_DELAY) + AutomaticBackupState.MAX_RETRY_DELAY),
        )
        // Do not send even a metadata request to a new account until its backup password is authorized.
        if (password.isNullOrBlank()) return@automaticOperation AutomaticBackupResult(
            AutomaticBackupOutcome.PASSWORD_REQUIRED, lastSuccess,
        )
        try {
            execute(plan, password, writer, remoteMarks)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            currentCoroutineContext().ensureActive()
            findFacadeRequestCancellation(error)?.let { throw it }
            // Config changes and contention are lifecycle events, not failed backups to penalize.
            if (!plan.matches(preferences.runtimeConfig.value)) throw error
            failure(error).copy(lastSuccessTime = lastSuccess, nextAttemptTime = state.failure(plan.identifier, currentTimeMillis().coerceAtLeast(0)))
        }
    }

    @OptIn(ExperimentalEncodingApi::class)
    private suspend fun execute(
        plan: AutomaticBackupConfiguration, password: String, writer: AutomaticBackupLocalWriter,
        remoteMarks: Map<String, CloudBackupWatermark>,
    ): AutomaticBackupResult {
        val remote = plan.cloud?.let(::WebDavBackupStore)
        try {
            if (remote != null) {
                val existing = try { remote.metadata(plan.archiveName) } catch (error: RecoverableSharedException) {
                    if (error.code == "CLOUD_BACKUP_NOT_FOUND") null else throw error
                }
                requireActive(plan)
                // Android autoBack calls hasBackUp before export/local copy; existence is not an integrity check.
                if (existing != null) return success(plan, remoteMarks, AutomaticBackupOutcome.ALREADY_PRESENT, cloudFile = existing.name)
            }
            val archive = settings.createAndroidBackupArchive(password)
            requireActive(plan)
            val local = saveLocal(writer, archive, plan)
            requireActive(plan)
            if (remote != null) {
                if (archive.base64Zip.length > 180 * 1024 * 1024) {
                    cloudBackupError("CLOUD_BACKUP_LIMIT", "备份 ZIP 超过 128 MB，未上传")
                }
                val bytes = Base64.decode(archive.base64Zip)
                try {
                    remote.ensureDirectory { requireCurrent(plan) }
                    remote.upload(plan.archiveName, bytes) { requireCurrent(plan) }
                    requireActive(plan)
                    val uploaded = remote.metadata(plan.archiveName)
                    if (uploaded.size > 0 && uploaded.size != bytes.size.toLong()) invalidDavResponse()
                } finally { bytes.fill(0) }
                requireActive(plan)
            }
            return success(
                plan, remoteMarks, AutomaticBackupOutcome.SAVED, local,
                if (remote != null) plan.archiveName else null, archive.warnings,
            )
        } finally { remote?.close() }
    }

    private suspend fun saveLocal(
        writer: AutomaticBackupLocalWriter, archive: AndroidBackupExport, plan: AutomaticBackupConfiguration,
    ): String {
        val completion = CompletableDeferred<AutomaticBackupLocalResult>()
        try {
            currentCoroutineContext().ensureActive()
            writer.save(archive, plan) { completion.complete(it) }
            val result = completion.await()
            currentCoroutineContext().ensureActive()
            if (result.cancelled) throw CancellationException("Automatic backup local save cancelled")
            return result.file?.takeIf { it.isNotBlank() } ?: cloudBackupError(
                "AUTOMATIC_BACKUP_LOCAL_FAILED", "本地自动备份写入失败，未记录成功时间",
            )
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: RecoverableSharedException) {
            throw error
        } catch (_: Exception) {
            cloudBackupError("AUTOMATIC_BACKUP_LOCAL_FAILED", "本地自动备份写入失败，未记录成功时间")
        } finally {
            completion.cancel()
            writer.cancel()
        }
    }

    /** Local-only manual backup already performed the same durable native save. */
    internal fun markLocalManualBackup(snapshot: AppRuntimeConfig) {
        val plan = AutomaticBackupConfiguration(snapshot)
        if (plan.isConfigured && !plan.hasCloudDestination && plan.matches(preferences.runtimeConfig.value)) {
            state.success(plan.identifier, currentTimeMillis().coerceAtLeast(0))
        }
    }

    private suspend fun requireActive(plan: AutomaticBackupConfiguration) {
        currentCoroutineContext().ensureActive()
        requireCurrent(plan)
    }

    private suspend fun success(
        plan: AutomaticBackupConfiguration, remoteMarks: Map<String, CloudBackupWatermark>,
        outcome: AutomaticBackupOutcome, localFile: String? = null, cloudFile: String? = null,
        warnings: List<String> = emptyList(),
    ): AutomaticBackupResult {
        requireActive(plan)
        val now = currentTimeMillis().coerceAtLeast(0)
        plan.cloud?.let { config ->
            val prior = remoteMarks[config.scope] ?: CloudBackupWatermark()
            cloudState.save(remoteMarks + (config.scope to prior.copy(
                localBackupTime = if (localFile == null) prior.localBackupTime else maxOf(prior.localBackupTime, now),
                uploadedTime = maxOf(prior.uploadedTime, now),
            )))
        }
        state.success(plan.identifier, now)
        return AutomaticBackupResult(outcome, now, AutomaticBackupState.nextDue(now), localFile, cloudFile, warnings)
    }

    private fun requireCurrent(plan: AutomaticBackupConfiguration) {
        if (!plan.matches(preferences.runtimeConfig.value)) {
            cloudBackupError("AUTOMATIC_BACKUP_CONFIG_CHANGED", "备份配置已变化，本次自动备份已停止")
        }
    }

    private fun failure(error: Throwable): AutomaticBackupResult {
        val code = (error as? RecoverableSharedException)?.code
        return if (code == "CLOUD_BACKUP_BUSY") AutomaticBackupResult(
            AutomaticBackupOutcome.BUSY, nextAttemptTime = currentTimeMillis() + 60_000,
            errorCode = code, errorMessage = "另一项备份操作正在进行，稍后重试",
        ) else AutomaticBackupResult(
            AutomaticBackupOutcome.FAILED, errorCode = code?.takeIf {
                it.startsWith("AUTOMATIC_BACKUP_") || it.startsWith("CLOUD_BACKUP_") || it == "BACKUP_PASSWORD_REQUIRED"
            } ?: "AUTOMATIC_BACKUP_FAILED",
            errorMessage = "自动备份失败，请检查备份密码、应用内路径和网络；未记录成功时间",
        )
    }
}
