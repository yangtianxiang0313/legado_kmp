package io.legado.kmp.shared.facade

import io.legado.kmp.shared.bootstrap.SharedBootstrap
import io.legado.kmp.shared.preferences.AppPreferencesStore
import org.koin.mp.KoinPlatformTools

/** Explicit uploads of already exported book bytes; opening a session never accesses the network. */
class BookExportCloudFacade private constructor(private val preferencesStore: AppPreferencesStore) {
    @Throws(RecoverableSharedException::class)
    fun startSession(): BookExportCloudSession {
        var session: BookExportCloudSession? = null
        try {
            val current = preferencesStore.runtimeConfig.value
            val config = CloudBackupConfiguration(
                current.copy(backupRestoreIgnoredKeys = current.backupRestoreIgnoredKeys.toSet()),
            )
            // Leave room for the fixed export collection under the validated configured root.
            if (config.pathSegments.size >= 64) throw BookExportCloudFailure(BookExportCloudMessage.CONFIGURATION)
            session = BookExportCloudSession(preferencesStore, config)
            if (!bookExportCloudMatches(config, preferencesStore.runtimeConfig.value)) {
                throw BookExportCloudFailure(BookExportCloudMessage.CONFIGURATION_CHANGED)
            }
            return session
        } catch (_: Throwable) {
            session?.close()
            // Even configuration/parser failures may contain an address or a credential.
            throw RecoverableSharedException(
                "BOOK_EXPORT_CLOUD_SESSION", "无法开始书籍云端导出，请检查 WebDAV 配置后重试",
            )
        }
    }

    companion object {
        @Throws(RecoverableSharedException::class)
        fun create(): BookExportCloudFacade = try {
            SharedBootstrap.startOrThrow()
            BookExportCloudFacade(KoinPlatformTools.defaultContext().get().get<AppPreferencesStore>())
        } catch (_: Throwable) {
            throw RecoverableSharedException("BOOK_EXPORT_CLOUD_UNAVAILABLE", "书籍云端导出服务不可用，请重试")
        }
    }
}
