package io.legado.kmp.shared.domain.runtime

import kotlinx.coroutines.flow.StateFlow

data class ReadAloudBlock(
    val blockIndex: Int,
    val text: String,
)

data class ReadAloudRequest(
    val bookUrl: String,
    val chapterIndex: Int,
    val blocks: List<ReadAloudBlock>,
    val startBlockIndex: Int = 0,
    val startTextOffset: Int = 0,
    val preferBackgroundPlayback: Boolean = false,
    val ttsEngine: String? = null,
    val startPaused: Boolean = false,
)

enum class ReadAloudEngineKind {
    SYSTEM_TTS,
    HTTP_TTS,
}

enum class ReadAloudStatus {
    IDLE,
    RUNNING,
    PAUSED,
    STOPPED,
    ERROR,
}

data class ReadAloudSpeechRateSetting(
    val followSystem: Boolean = true,
    val value: Float = 1.0f,
)

data class ReadAloudProgress(
    val chapterIndex: Int = 0,
    val blockIndex: Int = 0,
    val utteranceRangeStart: Int = 0,
    val utteranceRangeEnd: Int = 0,
    val isInBackground: Boolean = false,
    val speechRate: Float = 1.0f,
    val remainingTimerMinutes: Int = 0,
)

data class ReadAloudState(
    val engine: ReadAloudEngineKind = ReadAloudEngineKind.SYSTEM_TTS,
    val status: ReadAloudStatus = ReadAloudStatus.IDLE,
    val progress: ReadAloudProgress = ReadAloudProgress(),
    val isSupported: Boolean = true,
    val isBackgroundPlaybackEnabled: Boolean = false,
    val message: String? = null,
    val bookUrl: String? = null,
)

interface SourceCheckService {
    val state: StateFlow<ServiceState>

    suspend fun start()

    suspend fun start(sourceUrls: List<String>, config: SourceCheckConfig)

    suspend fun pause()

    suspend fun resume()

    suspend fun cancel()
}

interface BookCacheService {
    val state: StateFlow<ServiceState>

    suspend fun start()

    suspend fun pause()

    suspend fun resume()

    suspend fun cancel()
}

interface ReadAloudService {
    val state: StateFlow<ServiceState>
    val readAloudState: StateFlow<ReadAloudState>

    suspend fun start(request: ReadAloudRequest)

    suspend fun pause()

    suspend fun resume()

    suspend fun stop()

    suspend fun skipToPreviousBlock()

    suspend fun skipToNextBlock()

    suspend fun updateSpeechRate(setting: ReadAloudSpeechRateSetting)

    suspend fun setTimer(minutes: Int)

    suspend fun setBackgroundPlayback(enabled: Boolean)

    suspend fun advanceToNextBlock()

    suspend fun updateCurrentBlockRange(start: Int, end: Int)

    suspend fun updatePlaybackState(isInBackground: Boolean)

    suspend fun fail(message: String)
}

interface AudioPlayService {
    val state: StateFlow<ServiceState>

    suspend fun start()

    suspend fun pause()

    suspend fun resume()

    suspend fun cancel()
}

interface DownloadService {
    val state: StateFlow<ServiceState>
    val downloads: StateFlow<List<FileDownloadTask>>

    suspend fun start(url: String, fileName: String)

    suspend fun pauseTask(taskId: String)

    suspend fun resumeTask(taskId: String)

    suspend fun cancel(url: String)

    suspend fun cancelTask(taskId: String)

    suspend fun retry(taskId: String)

    suspend fun refresh()

    // Clears task records and cancels transfers, but never deletes delivered files.
    suspend fun clear()
}

interface RemoteLibraryService {
    val state: StateFlow<ServiceState>

    suspend fun refresh()

    suspend fun cancel()
}

data class ServiceState(
    val isSupported: Boolean,
    val isRunning: Boolean = false,
    val isPaused: Boolean = false,
    val message: String? = null,
)
