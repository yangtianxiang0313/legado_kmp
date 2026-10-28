package io.legado.kmp.shared.bootstrap

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

@Throws(SharedRuntimeBootstrapException::class)
fun startSharedRuntime(): Boolean = SharedBootstrap.start()

fun stopSharedRuntime() = SharedBootstrap.stop()

@Throws(SharedRuntimeBootstrapException::class)
fun startSharedRuntimeOrThrow(): Boolean = SharedBootstrap.startOrThrow()

fun sharedRuntimeHealthCheck(): SharedRuntimeHealth = SharedBootstrap.healthCheck()

@Throws(SharedRuntimeBootstrapException::class)
fun sharedBookshelfFacade(): BookshelfFacade = SharedBootstrap.bookshelfFacade()

@Throws(SharedRuntimeBootstrapException::class)
fun sharedSearchFacade(): SearchFacade = SharedBootstrap.searchFacade()

@Throws(SharedRuntimeBootstrapException::class)
fun sharedBookDetailFacade(): BookDetailFacade = SharedBootstrap.bookDetailFacade()

@Throws(SharedRuntimeBootstrapException::class)
fun sharedBookImageFacade(): BookImageFacade = SharedBootstrap.bookImageFacade()

@Throws(SharedRuntimeBootstrapException::class)
fun sharedReaderFacade(): ReaderFacade = SharedBootstrap.readerFacade()

@Throws(SharedRuntimeBootstrapException::class)
fun sharedReadRecordFacade(): ReadRecordFacade = SharedBootstrap.readRecordFacade()

@Throws(SharedRuntimeBootstrapException::class)
fun sharedDictionaryFacade(): io.legado.kmp.shared.facade.DictionaryFacade = SharedBootstrap.dictionaryFacade()

@Throws(SharedRuntimeBootstrapException::class)
fun sharedDiscoveryFacade(): DiscoveryFacade = SharedBootstrap.discoveryFacade()

@Throws(SharedRuntimeBootstrapException::class)
fun sharedRssFacade(): RssFacade = SharedBootstrap.rssFacade()

@Throws(SharedRuntimeBootstrapException::class)
fun sharedSettingsFacade(): SettingsFacade = SharedBootstrap.settingsFacade()

@Throws(SharedRuntimeBootstrapException::class)
fun sharedCloudBackupFacade(): io.legado.kmp.shared.facade.CloudBackupFacade = SharedBootstrap.cloudBackupFacade()

@Throws(SharedRuntimeBootstrapException::class)
fun sharedRuntimeFacade(): RuntimeFacade = SharedBootstrap.runtimeFacade()

@Throws(SharedRuntimeBootstrapException::class)
fun sharedRemoteBookFacade(): RemoteBookFacade = SharedBootstrap.remoteBookFacade()

@Throws(SharedRuntimeBootstrapException::class)
fun sharedSourceManagementFacade(): SourceManagementFacade = SharedBootstrap.sourceManagementFacade()

@Throws(SharedRuntimeBootstrapException::class)
fun sharedSourceLoginFacade(): SourceLoginFacade = SharedBootstrap.sourceLoginFacade()

@Throws(SharedRuntimeBootstrapException::class)
fun sharedBookSourceDebugFacade(): BookSourceDebugFacade = SharedBootstrap.bookSourceDebugFacade()

@Throws(SharedRuntimeBootstrapException::class)
fun sharedReplaceRuleFacade(): ReplaceRuleFacade = SharedBootstrap.replaceRuleFacade()

@Throws(SharedRuntimeBootstrapException::class)
fun sharedBookmarkFacade(): BookmarkFacade = SharedBootstrap.bookmarkFacade()

@Throws(SharedRuntimeBootstrapException::class)
fun sharedCacheFacade(): CacheFacade = SharedBootstrap.cacheFacade()

@Throws(SharedRuntimeBootstrapException::class)
fun sharedLogFacade(): LogFacade = SharedBootstrap.logFacade()

@Throws(SharedRuntimeBootstrapException::class)
fun sharedAudioPlayFacade(): AudioPlayFacade = SharedBootstrap.audioPlayFacade()

@Throws(SharedRuntimeBootstrapException::class)
fun sharedMangaReaderFacade(): MangaReaderFacade = SharedBootstrap.mangaReaderFacade()

@Throws(SharedRuntimeBootstrapException::class)
fun seedBundledRssSourcesIfEmpty(payload: String): Boolean = SharedBootstrap.seedBundledRssSourcesIfEmpty(payload)

@Throws(SharedRuntimeBootstrapException::class)
fun sharedBackupCapabilitiesFacade(): io.legado.kmp.shared.facade.BackupCapabilitiesFacade = SharedBootstrap.backupCapabilitiesFacade()

@Throws(SharedRuntimeBootstrapException::class)
fun sharedHttpSpeechFacade(): io.legado.kmp.shared.facade.HttpSpeechFacade = SharedBootstrap.httpSpeechFacade()

@Throws(SharedRuntimeBootstrapException::class)
fun sharedDirectLinkUploadFacade(): io.legado.kmp.shared.facade.DirectLinkUploadFacade = SharedBootstrap.directLinkUploadFacade()
