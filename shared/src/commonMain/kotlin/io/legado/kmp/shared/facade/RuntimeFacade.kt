package io.legado.kmp.shared.facade

import io.legado.kmp.shared.domain.runtime.BookCacheService
import io.legado.kmp.shared.domain.runtime.AudioPlayService
import io.legado.kmp.shared.domain.runtime.DownloadService
import io.legado.kmp.shared.domain.runtime.FileDownloadTask
import io.legado.kmp.shared.domain.runtime.ReadAloudService
import io.legado.kmp.shared.domain.runtime.ReadAloudRequest
import io.legado.kmp.shared.domain.runtime.ReadAloudSpeechRateSetting
import io.legado.kmp.shared.domain.runtime.ReadAloudState
import io.legado.kmp.shared.domain.runtime.RemoteLibraryService
import io.legado.kmp.shared.domain.runtime.ServiceState
import io.legado.kmp.shared.domain.runtime.SourceCheckService
import io.legado.kmp.shared.domain.runtime.SourceCheckConfig

class RuntimeFacade(
    private val sourceCheckService: SourceCheckService,
    private val bookCacheService: BookCacheService,
    private val readAloudService: ReadAloudService,
    private val audioPlayService: AudioPlayService,
    private val downloadService: DownloadService,
    private val remoteLibraryService: RemoteLibraryService,
) {
    fun watchSourceCheckState(onUpdate: (ServiceState) -> Unit): FlowSubscription {
        return watchFlow(sourceCheckService.state, onUpdate)
    }

    fun watchBookCacheState(onUpdate: (ServiceState) -> Unit): FlowSubscription {
        return watchFlow(bookCacheService.state, onUpdate)
    }

    fun watchReadAloudState(onUpdate: (ServiceState) -> Unit): FlowSubscription {
        return watchFlow(readAloudService.state, onUpdate)
    }

    fun watchDetailedReadAloudState(onUpdate: (ReadAloudState) -> Unit): FlowSubscription {
        return watchFlow(readAloudService.readAloudState, onUpdate)
    }

    fun watchAudioPlayState(onUpdate: (ServiceState) -> Unit): FlowSubscription {
        return watchFlow(audioPlayService.state, onUpdate)
    }

    fun watchDownloadState(onUpdate: (ServiceState) -> Unit): FlowSubscription {
        return watchFlow(downloadService.state, onUpdate)
    }

    fun watchDownloads(onUpdate: (List<FileDownloadTask>) -> Unit): FlowSubscription {
        return watchFlow(downloadService.downloads, onUpdate, "runtime.fileDownloads")
    }

    fun getDownloads(): List<FileDownloadTask> = downloadService.downloads.value

    fun watchRemoteLibraryState(onUpdate: (ServiceState) -> Unit): FlowSubscription {
        return watchFlow(remoteLibraryService.state, onUpdate)
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun startSourceCheck() = runRecoverable("RuntimeFacade.startSourceCheck") { sourceCheckService.start() }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun startSelectedSourceCheck(sourceUrls: List<String>, config: SourceCheckConfig) =
        runRecoverable("RuntimeFacade.startSelectedSourceCheck") { sourceCheckService.start(sourceUrls, config) }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun pauseSourceCheck() = runRecoverable("RuntimeFacade.pauseSourceCheck") { sourceCheckService.pause() }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun resumeSourceCheck() = runRecoverable("RuntimeFacade.resumeSourceCheck") { sourceCheckService.resume() }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun cancelSourceCheck() = runRecoverable("RuntimeFacade.cancelSourceCheck") { sourceCheckService.cancel() }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun startBookCache() = runRecoverable("RuntimeFacade.startBookCache") { bookCacheService.start() }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun pauseBookCache() = runRecoverable("RuntimeFacade.pauseBookCache") { bookCacheService.pause() }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun resumeBookCache() = runRecoverable("RuntimeFacade.resumeBookCache") { bookCacheService.resume() }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun cancelBookCache() = runRecoverable("RuntimeFacade.cancelBookCache") { bookCacheService.cancel() }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun startReadAloud(request: ReadAloudRequest) = runRecoverable("RuntimeFacade.startReadAloud") {
        readAloudService.start(request)
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun pauseReadAloud() = runRecoverable("RuntimeFacade.pauseReadAloud") { readAloudService.pause() }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun resumeReadAloud() = runRecoverable("RuntimeFacade.resumeReadAloud") { readAloudService.resume() }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun stopReadAloud() = runRecoverable("RuntimeFacade.stopReadAloud") { readAloudService.stop() }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun cancelReadAloud() = stopReadAloud()

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun skipReadAloudToPreviousBlock() = runRecoverable("RuntimeFacade.skipReadAloudToPreviousBlock") {
        readAloudService.skipToPreviousBlock()
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun skipReadAloudToNextBlock() = runRecoverable("RuntimeFacade.skipReadAloudToNextBlock") {
        readAloudService.skipToNextBlock()
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun updateReadAloudSpeechRate(setting: ReadAloudSpeechRateSetting) = runRecoverable("RuntimeFacade.updateReadAloudSpeechRate") {
        readAloudService.updateSpeechRate(setting)
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setReadAloudTimer(minutes: Int) = runRecoverable("RuntimeFacade.setReadAloudTimer") {
        readAloudService.setTimer(minutes)
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setReadAloudBackgroundPlayback(enabled: Boolean) = runRecoverable("RuntimeFacade.setReadAloudBackgroundPlayback") {
        readAloudService.setBackgroundPlayback(enabled)
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun advanceReadAloudToNextBlock() = runRecoverable("RuntimeFacade.advanceReadAloudToNextBlock") {
        readAloudService.advanceToNextBlock()
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun updateReadAloudCurrentRange(start: Int, end: Int) = runRecoverable("RuntimeFacade.updateReadAloudCurrentRange") {
        readAloudService.updateCurrentBlockRange(start, end)
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun updateReadAloudPlaybackState(isInBackground: Boolean) = runRecoverable("RuntimeFacade.updateReadAloudPlaybackState") {
        readAloudService.updatePlaybackState(isInBackground)
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun failReadAloud(message: String) = runRecoverable("RuntimeFacade.failReadAloud") {
        readAloudService.fail(message)
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun startAudioPlay() = runRecoverable("RuntimeFacade.startAudioPlay") { audioPlayService.start() }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun pauseAudioPlay() = runRecoverable("RuntimeFacade.pauseAudioPlay") { audioPlayService.pause() }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun resumeAudioPlay() = runRecoverable("RuntimeFacade.resumeAudioPlay") { audioPlayService.resume() }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun cancelAudioPlay() = runRecoverable("RuntimeFacade.cancelAudioPlay") { audioPlayService.cancel() }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun startDownload(url: String, fileName: String) = runRecoverable("RuntimeFacade.startDownload") {
        downloadService.start(url, fileName)
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun pauseDownloadTask(taskId: String) = runRecoverable("RuntimeFacade.pauseDownloadTask") {
        downloadService.pauseTask(taskId)
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun resumeDownloadTask(taskId: String) = runRecoverable("RuntimeFacade.resumeDownloadTask") {
        downloadService.resumeTask(taskId)
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun cancelDownload(url: String) = runRecoverable("RuntimeFacade.cancelDownload") { downloadService.cancel(url) }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun cancelDownloadTask(taskId: String) = runRecoverable("RuntimeFacade.cancelDownloadTask") {
        downloadService.cancelTask(taskId)
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun retryDownload(taskId: String) = runRecoverable("RuntimeFacade.retryDownload") { downloadService.retry(taskId) }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun refreshDownloads() = runRecoverable("RuntimeFacade.refreshDownloads") { downloadService.refresh() }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun clearDownloads() = runRecoverable("RuntimeFacade.clearDownloads") { downloadService.clear() }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun refreshRemoteLibrary() = runRecoverable("RuntimeFacade.refreshRemoteLibrary") { remoteLibraryService.refresh() }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun cancelRemoteLibraryRefresh() = runRecoverable("RuntimeFacade.cancelRemoteLibraryRefresh") { remoteLibraryService.cancel() }
}
