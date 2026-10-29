package io.legado.kmp.shared.facade

import io.legado.kmp.shared.preferences.AppPreferencesStore
import io.legado.kmp.shared.preferences.AppRuntimeConfig
import io.legado.kmp.shared.util.currentTimeMillis
import kotlin.coroutines.cancellation.CancellationException
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.withContext

/** Explicit cloud operations only. A check never restores data or acknowledges a hidden prompt. */
class CloudBackupFacade(
    private val preferencesStore: AppPreferencesStore,
    private val settingsFacade: SettingsFacade,
) {
    private val state = CloudBackupState(preferencesStore)
    private val listed = MutableStateFlow<Map<String, CloudBackupFile>>(emptyMap())
    private val preparationOwner = Any()

    fun isBusy(): Boolean = operations.isLocked

    fun automaticBackups(): AutomaticBackupEngine = AutomaticBackupEngine(preferencesStore, settingsFacade, this)

    fun listBackupsRequest(onResult: (CloudBackupRequestResult) -> Unit): FlowSubscription {
        val snapshot = snapshot()
        return CloudBackupRequest.start("listBackupsRequest", {
            CloudBackupRequestResult(files = list(snapshot), completed = true)
        }, onResult)
    }

    fun uploadBackupRequest(password: String?, onResult: (CloudBackupRequestResult) -> Unit): FlowSubscription {
        val snapshot = snapshot()
        return CloudBackupRequest.start("uploadBackupRequest", {
            CloudBackupRequestResult(upload = upload(snapshot, password), completed = true)
        }, onResult)
    }

    fun restoreBackupRequest(
        name: String, password: String?, onResult: (CloudBackupRequestResult) -> Unit,
    ): FlowSubscription {
        val snapshot = snapshot()
        val selection = listed.value[name]
        return CloudBackupRequest.startSettled("restoreBackupRequest", { terminal ->
            CloudBackupRequestResult(restored = restore(snapshot, name, password, selection, terminal), completed = true)
        }, onResult)
    }

    /** Prefer this over a bare name when a list can remain visible while account settings change. */
    fun restoreBackupFileRequest(
        file: CloudBackupFile, password: String?, onResult: (CloudBackupRequestResult) -> Unit,
    ): FlowSubscription {
        val snapshot = snapshot()
        return CloudBackupRequest.startSettled("restoreBackupFileRequest", { terminal ->
            CloudBackupRequestResult(restored = restore(snapshot, file.name, password, file, terminal), completed = true)
        }, onResult)
    }

    /** Download, decrypt and validate without any local persistence or watermark acknowledgement. */
    fun prepareRestoreBackupFileRequest(
        file: CloudBackupFile, password: String?, onResult: (CloudBackupRequestResult) -> Unit,
    ): FlowSubscription {
        val snapshot = snapshot()
        return CloudBackupRequest.startSettled("prepareRestoreBackupFileRequest", {
            CloudBackupRequestResult(prepared = prepare(snapshot, file, password), completed = true)
        }, onResult)
    }

    /** Pass the exact facade-issued object displayed in the native confirmation UI. */
    fun restorePreparedBackupRequest(
        prepared: PreparedCloudBackup, onResult: (CloudBackupRequestResult) -> Unit,
    ): FlowSubscription = CloudBackupRequest.startSettled("restorePreparedBackupRequest", { terminal ->
        CloudBackupRequestResult(restored = restorePrepared(prepared, terminal), completed = true)
    }, onResult)

    fun checkNewBackupRequest(onResult: (CloudBackupRequestResult) -> Unit): FlowSubscription {
        val snapshot = snapshot()
        return CloudBackupRequest.start("checkNewBackupRequest", {
            CloudBackupRequestResult(newBackup = checkNew(snapshot), completed = true)
        }, onResult)
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun listBackups(): List<CloudBackupFile> = list(snapshot())

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun uploadBackup(password: String? = null): CloudBackupUpload = upload(snapshot(), password)

    /** A name must first have been returned by this facade's successful list/check operation. */
    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun restoreBackup(name: String, password: String? = null): CloudBackupRestore =
        restore(snapshot(), name, password, listed.value[name])

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun restoreBackupFile(file: CloudBackupFile, password: String? = null): CloudBackupRestore =
        restore(snapshot(), file.name, password, file)

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun prepareRestoreBackupFile(file: CloudBackupFile, password: String? = null): PreparedCloudBackup =
        prepare(snapshot(), file, password)

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun restorePreparedBackup(prepared: PreparedCloudBackup): CloudBackupRestore =
        restorePrepared(prepared)

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun checkNewBackup(): CloudBackupFile? = checkNew(snapshot())

    /** Call only after native UI has actually presented the new-backup prompt. */
    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun acknowledgeBackup(file: CloudBackupFile): Unit = operation(snapshot()) { config ->
        requireSelection(file.name, file, config)
        currentCoroutineContext().ensureActive()
        requireCurrent(config)
        val scopes = state.read()
        val prior = scopes[config.scope] ?: CloudBackupWatermark()
        if (file.lastModified > prior.seenModified) {
            state.save(scopes + (config.scope to prior.copy(seenModified = file.lastModified, seenName = file.name)))
        }
    }

    /** Call after the local ZIP was durably saved, not when opening/cancelling a share sheet. */
    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun markLocalBackupCreated() {
        val snapshot = snapshot()
        // Saving a local backup remains usable without an account; there is no cloud scope to mark.
        if (!hasCredentials(snapshot)) {
            automaticOperation {
                automaticBackups().markLocalManualBackup(snapshot)
            }
            return
        }
        operation(snapshot) { config ->
            val scopes = state.read()
            val prior = scopes[config.scope] ?: CloudBackupWatermark()
            currentCoroutineContext().ensureActive()
            requireCurrent(config)
            state.save(scopes + (config.scope to prior.copy(localBackupTime = maxOf(prior.localBackupTime, currentTimeMillis()))))
            automaticBackups().markLocalManualBackup(snapshot)
        }
    }

    private suspend fun list(snapshot: AppRuntimeConfig): List<CloudBackupFile> = operation(snapshot) { config ->
        val files = withStore(config) { it.list() }
        currentCoroutineContext().ensureActive()
        requireCurrent(config)
        publish(files, config)
    }

    @OptIn(ExperimentalEncodingApi::class)
    private suspend fun upload(snapshot: AppRuntimeConfig, password: String?): CloudBackupUpload = operation(snapshot) { config ->
        // Validate marker storage before accepting any remote mutation.
        val scopes = state.read()
        val exported = settingsFacade.createAndroidBackupArchive(password)
        currentCoroutineContext().ensureActive()
        requireCurrent(config)
        if (exported.base64Zip.length > 180 * 1024 * 1024) {
            cloudBackupError("CLOUD_BACKUP_LIMIT", "备份 ZIP 超过 128 MB，未上传")
        }
        val bytes = Base64.decode(exported.base64Zip)
        if (bytes.isEmpty() || bytes.size > WebDavBackupStore.MAX_ARCHIVE_BYTES) {
            cloudBackupError("CLOUD_BACKUP_LIMIT", "备份 ZIP 为空或超过 128 MB，未上传")
        }
        val name = config.backupName()
        val file = withStore(config) { store ->
            store.ensureDirectory { requireCurrent(config) }
            store.upload(name, bytes) { requireCurrent(config) }
            currentCoroutineContext().ensureActive()
            requireCurrent(config)
            // PUT success is not inferred from local export or a swallowed network exception.
            store.metadata(name).also {
                if (it.size > 0 && it.size != bytes.size.toLong()) invalidDavResponse()
            }
        }
        currentCoroutineContext().ensureActive()
        requireCurrent(config)
        val prior = scopes[config.scope] ?: CloudBackupWatermark()
        state.save(scopes + (config.scope to prior.copy(uploadedTime = maxOf(
            prior.uploadedTime, currentTimeMillis(), file.lastModified,
        ))))
        file.origin = config
        CloudBackupUpload(file, exported.warnings.toList())
    }

    private suspend fun restore(
        snapshot: AppRuntimeConfig, name: String, password: String?, selection: CloudBackupFile?,
        terminal: (CloudBackupRequestResult) -> Unit = {},
    ): CloudBackupRestore = operation(snapshot) { config ->
        val prepared = prepareRestore(config, name, password, selection)
        try {
            commitPrepared(prepared, terminal)
        } finally {
            prepared.discard()
        }
    }.getOrThrow()

    private suspend fun prepare(
        snapshot: AppRuntimeConfig, file: CloudBackupFile, password: String?,
    ): PreparedCloudBackup = operation(snapshot) { config ->
        prepareRestore(config, file.name, password, file)
    }

    /** The caller owns the global gate: legacy one-step restore must not enter it a second time. */
    private suspend fun prepareRestore(
        config: CloudBackupConfiguration, name: String, password: String?, selection: CloudBackupFile?,
    ): PreparedCloudBackup {
        cloudBackupName(name)
        requireSelection(name, selection, config)
        // Preflight marker storage too, but never write it in the preparation phase.
        state.read()
        val downloaded = withStore(config) { store ->
            val metadata = store.metadata(name)
            requireUnchanged(requireNotNull(selection), metadata)
            currentCoroutineContext().ensureActive()
            requireCurrent(config)
            val bytes = store.download(name)
            if (metadata.size > 0 && metadata.size != bytes.size.toLong()) {
                cloudBackupError("CLOUD_BACKUP_CHANGED", "云端备份已变化或传输不完整，请刷新后重试")
            }
            currentCoroutineContext().ensureActive()
            requireCurrent(config)
            requireUnchanged(metadata, store.metadata(name))
            bytes
        }
        val payload = decodeCloudBackup(downloaded, password, config.snapshot.backupRestoreIgnoredKeys)
        currentCoroutineContext().ensureActive()
        requireCurrent(config)
        return PreparedCloudBackup.create(preparationOwner, config, requireNotNull(selection), payload)
    }

    private suspend fun restorePrepared(
        prepared: PreparedCloudBackup,
        terminal: (CloudBackupRequestResult) -> Unit = {},
    ): CloudBackupRestore = automaticOperation { commitPrepared(prepared, terminal) }.getOrThrow()

    /** Everything before claim is cancellable and read-only. A claimed commit always settles. */
    private suspend fun commitPrepared(
        prepared: PreparedCloudBackup,
        terminal: (CloudBackupRequestResult) -> Unit,
    ): Result<CloudBackupRestore> {
        val context = currentCoroutineContext()
        context.ensureActive()
        val config = prepared.configuration(preparationOwner, preferencesStore.runtimeConfig.value)
        val scopes = state.read()
        context.ensureActive()
        return withContext(NonCancellable) {
            context.ensureActive()
            // Check configuration/ignore keys again at the single-use acceptance point, after all reads.
            val claimed = prepared.claim(preparationOwner, preferencesStore.runtimeConfig.value)
            val outcome = try {
                // Canonical decrypted JSON is private to the claimed object; native cannot inject it.
                val result = settingsFacade.restoreFromBackup(claimed.payload.payload)
                val prior = scopes[config.scope] ?: CloudBackupWatermark()
                try {
                    // Restored settings may change accounts; mark only the original cloud scope.
                    state.save(scopes + (config.scope to prior.copy(restoredTime = maxOf(
                        prior.restoredTime, currentTimeMillis(), claimed.file.lastModified,
                    ))))
                } catch (_: Exception) {
                    cloudBackupError(
                        "CLOUD_BACKUP_RESTORE_STATE_FAILED",
                        "备份数据已恢复，但云备份恢复记录保存失败，请检查本地数据后再操作",
                    )
                }
                Result.success(CloudBackupRestore(result, claimed.payload.warnings.toList()))
            } catch (error: Exception) {
                Result.failure<CloudBackupRestore>(safeCommitError(error))
            }
            // Publish inside NonCancellable: a later job cancellation cannot replace the real outcome.
            terminal(outcome.fold(
                onSuccess = { CloudBackupRequestResult(restored = it, completed = true) },
                onFailure = {
                    val safe = it as RecoverableSharedException
                    CloudBackupRequestResult(errorCode = safe.code, errorMessage = safe.message)
                },
            ))
            // Unwrap only outside the gate, where its cancellation sanitizer cannot mask a commit error.
            outcome
        }
    }

    private fun safeCommitError(error: Exception): RecoverableSharedException = when (
        (error as? RecoverableSharedException)?.code
    ) {
        "BACKUP_PREFERENCES_RESTORE_FAILED" -> RecoverableSharedException(
            "BACKUP_PREFERENCES_RESTORE_FAILED", "数据库已恢复，但设置恢复失败，请重新应用设置",
        )
        "BACKUP_DATABASE_RESTORE_FAILED" -> RecoverableSharedException(
            "BACKUP_DATABASE_RESTORE_FAILED", "数据库恢复失败，本次数据库写入已回滚，设置未应用",
        )
        "BACKUP_DATABASE_UNAVAILABLE", "BACKUP_REPOSITORY_UNAVAILABLE" -> RecoverableSharedException(
            "CLOUD_BACKUP_RESTORE_UNAVAILABLE", "备份数据库或恢复依赖尚未就绪，未恢复任何数据",
        )
        "CLOUD_BACKUP_RESTORE_STATE_FAILED" -> RecoverableSharedException(
            "CLOUD_BACKUP_RESTORE_STATE_FAILED", "备份数据已恢复，但云备份恢复记录保存失败，请检查本地数据后再操作",
        )
        else -> RecoverableSharedException(
            "CLOUD_BACKUP_RESTORE_FAILED", "备份恢复未能完整完成，请检查本地数据和设置后重试",
        )
    }

    private suspend fun checkNew(snapshot: AppRuntimeConfig): CloudBackupFile? {
        if (!snapshot.autoCheckNewBackup || !hasCredentials(snapshot)) return null
        return operation(snapshot) { config ->
            val scopes = state.read()
            val files = withStore(config) { it.list() }
            currentCoroutineContext().ensureActive()
            requireCurrent(config)
            if (!preferencesStore.runtimeConfig.value.autoCheckNewBackup) return@operation null
            publish(files, config)
            val latest = files.firstOrNull() ?: return@operation null
            val threshold = (scopes[config.scope] ?: CloudBackupWatermark()).threshold
            latest.takeIf { it.lastModified > threshold && it.lastModified - threshold > 60_000 }
        }
    }

    private fun publish(files: List<CloudBackupFile>, config: CloudBackupConfiguration): List<CloudBackupFile> {
        files.forEach { it.origin = config }
        listed.value = files.associateBy { it.name }
        return files
    }

    private fun requireSelection(name: String, file: CloudBackupFile?, config: CloudBackupConfiguration) {
        if (file == null || file.name != name || file.origin?.scope != config.scope ||
            file.origin?.matches(preferencesStore.runtimeConfig.value) != true) {
            cloudBackupError("CLOUD_BACKUP_STALE_SELECTION", "备份选择已失效或 WebDAV 配置已变化，请重新获取列表")
        }
    }

    private fun requireUnchanged(before: CloudBackupFile, after: CloudBackupFile) {
        if (before.name != after.name || (before.size > 0 && before.size != after.size) ||
            (before.lastModified > 0 && before.lastModified != after.lastModified)) {
            cloudBackupError("CLOUD_BACKUP_CHANGED", "云端备份已变化，请刷新列表后重新选择")
        }
    }

    private fun snapshot(): AppRuntimeConfig = preferencesStore.runtimeConfig.value.let {
        it.copy(backupRestoreIgnoredKeys = it.backupRestoreIgnoredKeys.toSet())
    }

    private fun requireCurrent(config: CloudBackupConfiguration) {
        if (!config.matches(preferencesStore.runtimeConfig.value)) {
            cloudBackupError("CLOUD_BACKUP_CONFIG_CHANGED", "WebDAV 配置已变化，本次操作已停止，请重试")
        }
    }

    private suspend fun <T> withStore(config: CloudBackupConfiguration, body: suspend (WebDavBackupStore) -> T): T {
        val store = WebDavBackupStore(config)
        return try { body(store) } finally { store.close() }
    }

    private suspend fun <T> operation(snapshot: AppRuntimeConfig, body: suspend (CloudBackupConfiguration) -> T): T =
        automaticOperation {
            val config = CloudBackupConfiguration(snapshot)
            requireCurrent(config)
            body(config)
        }

    /** The native local save callback is also inside this gate, not only the remote PUT. */
    internal suspend fun <T> automaticOperation(body: suspend () -> T): T {
        currentCoroutineContext().ensureActive()
        if (!operations.tryLock()) cloudBackupError("CLOUD_BACKUP_BUSY", "另一项云备份操作正在进行，请稍后重试")
        try {
            return body()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            currentCoroutineContext().ensureActive()
            findFacadeRequestCancellation(error)?.let { throw it }
            throw safeError(error)
        } finally {
            operations.unlock()
        }
    }

    private fun safeError(error: Exception): RecoverableSharedException {
        if (error is RecoverableSharedException) {
            if (error.code.startsWith("CLOUD_BACKUP_") || error.code.startsWith("AUTOMATIC_BACKUP_") || error.code in setOf(
                    "BACKUP_PASSWORD_REQUIRED", "BACKUP_ENCRYPTION_FAILED", "BACKUP_DECRYPTION_FAILED",
                    "INVALID_BACKUP_ENCRYPTION", "UNSUPPORTED_BACKUP_ENCRYPTION",
                )) return error
        }
        // Transport/decoding errors may contain URLs, Basic auth, config.xml or uploaded credentials.
        return RecoverableSharedException("CLOUD_BACKUP_FAILED", "云备份操作失败，请检查网络、证书、配置和服务状态")
    }

    private fun hasCredentials(config: AppRuntimeConfig): Boolean =
        !config.webDavAccount.isNullOrBlank() && !config.webDavPassword.isNullOrBlank()

    private companion object {
        // Shared by instances so a recreated settings screen cannot start a second restore/upload.
        val operations = Mutex()
    }
}
