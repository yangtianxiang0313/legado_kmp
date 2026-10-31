package io.legado.kmp.shared.bootstrap

import io.legado.kmp.shared.di.initKoin
import io.legado.kmp.shared.di.platformModule
import io.legado.kmp.shared.domain.repository.RssSourceRepository
import io.legado.kmp.shared.facade.BookDetailFacade
import io.legado.kmp.shared.facade.BookImageFacade
import io.legado.kmp.shared.facade.BookSourceDebugFacade
import io.legado.kmp.shared.facade.BookshelfFacade
import io.legado.kmp.shared.facade.DiscoveryFacade
import io.legado.kmp.shared.facade.ReaderFacade
import io.legado.kmp.shared.facade.ReadRecordFacade
import io.legado.kmp.shared.facade.RemoteBookFacade
import io.legado.kmp.shared.facade.RuntimeFacade
import io.legado.kmp.shared.facade.RssFacade
import io.legado.kmp.shared.facade.SearchFacade
import io.legado.kmp.shared.facade.SettingsFacade
import io.legado.kmp.shared.facade.ReplaceRuleFacade
import io.legado.kmp.shared.facade.SourceManagementFacade
import io.legado.kmp.shared.facade.SourceLoginFacade
import io.legado.kmp.shared.facade.BookmarkFacade
import io.legado.kmp.shared.facade.CacheFacade
import io.legado.kmp.shared.facade.LogFacade
import io.legado.kmp.shared.facade.AudioPlayFacade
import io.legado.kmp.shared.facade.MangaReaderFacade
import io.legado.kmp.shared.data.database.LegadoDatabase
import io.legado.kmp.shared.facade.BackupPreferencesRestoreCoordinator
import io.legado.kmp.shared.preferences.AppPreferencesStore
import kotlinx.coroutines.flow.MutableStateFlow
import io.legado.kmp.shared.model.RssSource
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import org.koin.core.Koin
import org.koin.mp.KoinPlatformTools

object SharedBootstrap {
    private val recoveryReady = MutableStateFlow(false)
    fun start(): Boolean {
        startOrThrow()
        return true
    }

    fun startOrThrow(): Boolean {
        try {
            val existing = KoinPlatformTools.defaultContext().getOrNull()
            if (existing != null && recoveryReady.value) return false
            if (existing == null) initKoin(platformModule = platformModule)
            recoverPreferences(checkNotNull(KoinPlatformTools.defaultContext().getOrNull()))
            return existing == null
        } catch (throwable: Throwable) {
            throw SharedRuntimeBootstrapException(
                message = "Failed to initialize shared runtime",
                cause = throwable,
            )
        }
    }

    fun stop() {
        recoveryReady.value = false
        if (KoinPlatformTools.defaultContext().getOrNull() != null) {
            KoinPlatformTools.defaultContext().stopKoin()
        }
    }

    fun bookshelfFacade(): BookshelfFacade = getFacade("BookshelfFacade")

    fun searchFacade(): SearchFacade = getFacade("SearchFacade")

    fun bookDetailFacade(): BookDetailFacade = getFacade("BookDetailFacade")

    fun bookImageFacade(): BookImageFacade = getFacade("BookImageFacade")

    fun readerFacade(): ReaderFacade = getFacade("ReaderFacade")

    fun readRecordFacade(): ReadRecordFacade = getFacade("ReadRecordFacade")

    fun dictionaryFacade(): io.legado.kmp.shared.facade.DictionaryFacade = getFacade("DictionaryFacade")

    fun discoveryFacade(): DiscoveryFacade = getFacade("DiscoveryFacade")

    fun rssFacade(): RssFacade = getFacade("RssFacade")

    fun httpSpeechFacade(): io.legado.kmp.shared.facade.HttpSpeechFacade = getFacade("HttpSpeechFacade")

    fun directLinkUploadFacade(): io.legado.kmp.shared.facade.DirectLinkUploadFacade = getFacade("DirectLinkUploadFacade")

    fun backupCapabilitiesFacade(): io.legado.kmp.shared.facade.BackupCapabilitiesFacade = getFacade("BackupCapabilitiesFacade")

    fun settingsFacade(): SettingsFacade = getFacade("SettingsFacade")

    fun cloudBackupFacade(): io.legado.kmp.shared.facade.CloudBackupFacade = getFacade("CloudBackupFacade")

    fun runtimeFacade(): RuntimeFacade = getFacade("RuntimeFacade")

    fun remoteBookFacade(): RemoteBookFacade = getFacade("RemoteBookFacade")

    fun sourceManagementFacade(): SourceManagementFacade = getFacade("SourceManagementFacade")

    fun sourceLoginFacade(): SourceLoginFacade = getFacade("SourceLoginFacade")

    fun bookSourceDebugFacade(): BookSourceDebugFacade = getFacade("BookSourceDebugFacade")

    fun replaceRuleFacade(): ReplaceRuleFacade = getFacade("ReplaceRuleFacade")

    fun bookmarkFacade(): BookmarkFacade = getFacade("BookmarkFacade")

    fun cacheFacade(): CacheFacade = getFacade("CacheFacade")

    fun logFacade(): LogFacade = getFacade("LogFacade")

    fun audioPlayFacade(): AudioPlayFacade = getFacade("AudioPlayFacade")

    fun mangaReaderFacade(): MangaReaderFacade = getFacade("MangaReaderFacade")

    fun seedBundledRssSourcesIfEmpty(payload: String): Boolean {
        val repository: RssSourceRepository = getDependency("RssSourceRepository")
        val parsed = try {
            Json { ignoreUnknownKeys = true }.decodeFromString(ListSerializer(RssSource.serializer()), payload)
        } catch (throwable: Throwable) {
            throw SharedRuntimeBootstrapException(
                message = "Failed to decode bundled RSS sources",
                cause = throwable,
            )
        }.filter { it.isValid }

        if (parsed.isEmpty()) {
            throw SharedRuntimeBootstrapException("Bundled RSS sources payload did not contain any valid RSS source")
        }

        return runBlocking {
            if (repository.size() > 0) {
                false
            } else {
                repository.deleteDefault()
                repository.insert(*parsed.toTypedArray())
                true
            }
        }
    }

    fun healthCheck(): SharedRuntimeHealth {
        val started = KoinPlatformTools.defaultContext().getOrNull() != null
        return SharedRuntimeHealth(
            started = started,
            status = if (!started) "idle" else if (recoveryReady.value) "ready" else "recovery_required",
        )
    }

    private fun koin(): Koin {
        return KoinPlatformTools.defaultContext().getOrNull()
            ?: throw SharedRuntimeBootstrapException("Shared runtime has not been started")
    }

    private inline fun <reified T : Any> getFacade(name: String): T {
        return try {
            val container = koin()
            if (!recoveryReady.value) recoverPreferences(container)
            container.get()
        } catch (throwable: Throwable) {
            throw SharedRuntimeBootstrapException(
                message = "Failed to resolve $name",
                cause = throwable,
            )
        }
    }

    private inline fun <reified T : Any> getDependency(name: String): T {
        return try {
            val container = koin()
            if (!recoveryReady.value) recoverPreferences(container)
            container.get()
        } catch (throwable: Throwable) {
            throw SharedRuntimeBootstrapException(
                message = "Failed to resolve $name",
                cause = throwable,
            )
        }
    }

    private fun recoverPreferences(container: Koin) {
        recoveryReady.value = false
        BackupPreferencesRestoreCoordinator.recoverAtStartup(container.get<LegadoDatabase>(), container.get<AppPreferencesStore>())
        recoveryReady.value = true
    }
}
