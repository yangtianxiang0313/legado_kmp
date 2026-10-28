package io.legado.kmp.shared.platform

import io.legado.kmp.shared.domain.localbook.ArchiveBookRecovery
import io.legado.kmp.shared.domain.localbook.LocalBookByteSource
import io.legado.kmp.shared.domain.localbook.LocalBookFileStore
import io.legado.kmp.shared.domain.runtime.BookCacheService
import io.legado.kmp.shared.domain.runtime.AudioPlayService
import io.legado.kmp.shared.domain.runtime.DownloadService
import io.legado.kmp.shared.domain.runtime.FileDownloadTask
import io.legado.kmp.shared.domain.runtime.ReadAloudService
import io.legado.kmp.shared.domain.runtime.ReadAloudRequest
import io.legado.kmp.shared.domain.runtime.ReadAloudSpeechRateSetting
import io.legado.kmp.shared.domain.runtime.ReadAloudState
import io.legado.kmp.shared.domain.runtime.ReadAloudStatus
import io.legado.kmp.shared.domain.runtime.RemoteLibraryService
import io.legado.kmp.shared.domain.runtime.ServiceState
import io.legado.kmp.shared.domain.runtime.SourceCheckService
import io.legado.kmp.shared.domain.runtime.SourceCheckConfig
import io.legado.kmp.shared.model.Book
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

class FileAccessLocalBookFileStore(
    private val fileAccess: FileAccess
) : LocalBookFileStore {
    override suspend fun openRead(path: String): LocalBookByteSource = fileAccess.openRead(path)

    override suspend fun read(path: String): ByteArray = fileAccess.read(path)

    override suspend fun lastModified(path: String): Long? = fileAccess.lastModified(path)
}

class UnsupportedArchiveBookRecovery : ArchiveBookRecovery {
    override suspend fun recover(book: Book): Book? = null
}

class UnsupportedSourceCheckService : SourceCheckService {
    private val mutableState = MutableStateFlow(unsupportedState("Source checking is not implemented on this platform"))
    override val state: StateFlow<ServiceState> = mutableState.asStateFlow()

    override suspend fun start() = unsupported()
    override suspend fun start(sourceUrls: List<String>, config: SourceCheckConfig) = unsupported()
    override suspend fun pause() = unsupported()
    override suspend fun resume() = unsupported()
    override suspend fun cancel() = mutableState.reset()

    private fun unsupported() {
        mutableState.value = mutableState.value.copy(message = "Source checking is not implemented on this platform")
    }
}

class UnsupportedBookCacheService : BookCacheService {
    private val mutableState = MutableStateFlow(unsupportedState("Book caching is not implemented on this platform"))
    override val state: StateFlow<ServiceState> = mutableState.asStateFlow()

    override suspend fun start() = unsupported()
    override suspend fun pause() = unsupported()
    override suspend fun resume() = unsupported()
    override suspend fun cancel() = mutableState.reset()

    private fun unsupported() {
        mutableState.value = mutableState.value.copy(message = "Book caching is not implemented on this platform")
    }
}

class UnsupportedReadAloudService : ReadAloudService {
    private val mutableState = MutableStateFlow(unsupportedState("Read aloud is not implemented on this platform"))
    override val state: StateFlow<ServiceState> = mutableState.asStateFlow()
    override val readAloudState: StateFlow<ReadAloudState> = MutableStateFlow(
        ReadAloudState(
            status = ReadAloudStatus.ERROR,
            isSupported = false,
            message = "Read aloud is not implemented on this platform",
        )
    )

    override suspend fun start(request: ReadAloudRequest) = unsupported()
    override suspend fun pause() = unsupported()
    override suspend fun resume() = unsupported()
    override suspend fun stop() = mutableState.reset()
    override suspend fun skipToPreviousBlock() = unsupported()
    override suspend fun skipToNextBlock() = unsupported()
    override suspend fun updateSpeechRate(setting: ReadAloudSpeechRateSetting) = unsupported()
    override suspend fun setTimer(minutes: Int) = unsupported()
    override suspend fun setBackgroundPlayback(enabled: Boolean) = unsupported()
    override suspend fun advanceToNextBlock() = unsupported()
    override suspend fun updateCurrentBlockRange(start: Int, end: Int) = unsupported()
    override suspend fun updatePlaybackState(isInBackground: Boolean) = unsupported()
    override suspend fun fail(message: String) = unsupported()

    private fun unsupported() {
        mutableState.value = mutableState.value.copy(message = "Read aloud is not implemented on this platform")
    }
}

class UnsupportedAudioPlayService : AudioPlayService {
    private val mutableState = MutableStateFlow(unsupportedState("Audio play is not implemented on this platform"))
    override val state: StateFlow<ServiceState> = mutableState.asStateFlow()

    override suspend fun start() = unsupported()
    override suspend fun pause() = unsupported()
    override suspend fun resume() = unsupported()
    override suspend fun cancel() = mutableState.reset()

    private fun unsupported() {
        mutableState.value = mutableState.value.copy(message = "Audio play is not implemented on this platform")
    }
}

class UnsupportedDownloadService : DownloadService {
    private val mutableState = MutableStateFlow(unsupportedState("Download is not implemented on this platform"))
    override val state: StateFlow<ServiceState> = mutableState.asStateFlow()
    override val downloads: StateFlow<List<FileDownloadTask>> = MutableStateFlow(emptyList())

    override suspend fun start(url: String, fileName: String) = unsupported()
    override suspend fun pauseTask(taskId: String) = unsupported()
    override suspend fun resumeTask(taskId: String) = unsupported()
    override suspend fun cancel(url: String) = mutableState.reset()
    override suspend fun cancelTask(taskId: String) = mutableState.reset()
    override suspend fun retry(taskId: String) = unsupported()
    override suspend fun refresh() = unsupported()
    override suspend fun clear() = mutableState.reset()

    private fun unsupported() {
        mutableState.value = mutableState.value.copy(message = "Download is not implemented on this platform")
    }
}

class UnsupportedRemoteLibraryService : RemoteLibraryService {
    private val mutableState = MutableStateFlow(unsupportedState("Remote library is not implemented on this platform"))
    override val state: StateFlow<ServiceState> = mutableState.asStateFlow()

    override suspend fun refresh() {
        mutableState.value = mutableState.value.copy(message = "Remote library is not implemented on this platform")
    }

    override suspend fun cancel() = mutableState.reset()
}

private fun unsupportedState(message: String): ServiceState {
    return ServiceState(
        isSupported = false,
        isRunning = false,
        isPaused = false,
        message = message,
    )
}

private fun MutableStateFlow<ServiceState>.reset() {
    value = value.copy(isRunning = false, isPaused = false)
}
