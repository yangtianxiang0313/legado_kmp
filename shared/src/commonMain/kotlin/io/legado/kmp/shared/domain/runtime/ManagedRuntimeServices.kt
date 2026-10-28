package io.legado.kmp.shared.domain.runtime

import io.legado.kmp.shared.domain.usecase.GetBookSourcesUseCase
import io.legado.kmp.shared.domain.usecase.GetBooksUseCase
import io.legado.kmp.shared.domain.usecase.GetHttpTTSUseCase
import io.legado.kmp.shared.domain.usecase.GetServersUseCase
import io.legado.kmp.shared.domain.usecase.SaveBookSourceUseCase
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.model.SourceGroups
import io.legado.kmp.shared.model.isTxtLocalBook
import io.legado.kmp.shared.preferences.AppPreferencesStore
import io.legado.kmp.shared.preferences.ReaderRuntimeConfig
import io.legado.kmp.shared.util.currentTimeMillis
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

class ManagedSourceCheckService(
    private val getBookSourcesUseCase: GetBookSourcesUseCase,
    private val saveBookSourceUseCase: SaveBookSourceUseCase,
    private val sourceCheckBackend: SourceCheckBackend,
    private val preferencesStore: AppPreferencesStore,
) : SourceCheckService {
    private val mutableState = MutableStateFlow(supportedIdleState("Source checking ready"))
    override val state: StateFlow<ServiceState> = mutableState.asStateFlow()
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val commands = Mutex()
    private var checkJob: Job? = null
    private var resumeSignal: CompletableDeferred<Unit>? = null
    private var revision = 0L

    override suspend fun start() = startInternal(null, SourceCheckConfig())

    override suspend fun start(sourceUrls: List<String>, config: SourceCheckConfig) = startInternal(sourceUrls, config)

    private suspend fun startInternal(sourceUrls: List<String>?, config: SourceCheckConfig) {
        require(config.timeoutMs > 0 && config.keyword.isNotBlank()) { "校验关键词和超时时间无效" }
        require(config.checkSearch || config.checkDiscovery) { "请至少选择搜索或发现" }
        require(!config.checkCategory || config.checkInfo) { "校验目录需要启用详情" }
        require(!config.checkContent || config.checkCategory) { "校验正文需要启用目录" }
        commands.withLock {
            check(checkJob?.isCompleted != false) { "已有书源在校验或停止中，请稍后再试" }
            val sources = if (sourceUrls == null) {
                getBookSourcesUseCase.getEnabled()
            } else {
                require(sourceUrls.isNotEmpty() && sourceUrls.all { it.isNotBlank() && it == it.trim() }) { "请选择有效书源" }
                val available = getBookSourcesUseCase.getAll().associateBy { it.bookSourceUrl }
                sourceUrls.distinct().map { url -> requireNotNull(available[url]) { "所选书源已不存在，请重新选择" } }
            }
            if (sources.isEmpty()) {
                ++revision
                checkJob = null
                mutableState.value = supportedIdleState("没有可校验的启用书源")
                return@withLock
            }
            val concurrency = preferencesStore.runtimeConfig.first().threadCount
                .coerceIn(1, 64)
                .coerceAtMost(sources.size)
            resumeSignal = null
            val currentRevision = ++revision
            val run = SourceCheckRun(sources, config, currentRevision, concurrency)
            mutableState.value = supportedRunningState("正在校验 0/${sources.size}")
            checkJob = serviceScope.launch { checkSources(run) }
        }
    }

    private suspend fun checkSources(run: SourceCheckRun) {
        var cancelled = false
        var failure: Throwable? = null
        try {
            coroutineScope {
                // Fixed workers bound both in-flight sources and the number of child coroutines.
                List(run.concurrency) {
                    async {
                        while (true) {
                            val source = awaitNextSource(run) ?: break
                            currentCoroutineContext().ensureActive()
                            val result = sourceCheckBackend.checkSource(source, run.config)
                            commands.withLock {
                                currentCoroutineContext().ensureActive()
                                if (run.revision != revision) return@async
                                val applied = saveBookSourceUseCase.updateIfUnchanged(source, source.withSourceCheckResult(result))
                                run.checked += 1
                                if (!applied) run.skipped += 1 else if (result.invalidGroups.isNotEmpty()) run.failed += 1
                                val message = run.progressMessage(source)
                                mutableState.value = supportedRunningState(message).let {
                                    if (resumeSignal != null) it.toPausedState(message) else it
                                }
                            }
                        }
                    }
                }.awaitAll()
            }
            currentCoroutineContext().ensureActive()
        } catch (error: CancellationException) {
            cancelled = true
            throw error
        } catch (error: Throwable) {
            failure = error
        } finally {
            withContext(NonCancellable) {
                commands.withLock {
                    if (run.revision == revision) {
                        checkJob = null
                        resumeSignal?.complete(Unit)
                        resumeSignal = null
                        val error = failure
                        val message = when {
                            cancelled -> "书源校验已取消：${run.summary()}"
                            error != null -> "${error.message ?: "书源校验失败"}：${run.summary()}"
                            else -> "书源校验完成：${run.summary()}"
                        }
                        mutableState.value = supportedIdleState(message)
                    }
                }
            }
        }
    }

    private suspend fun awaitNextSource(run: SourceCheckRun): BookSource? {
        while (true) {
            val signal = commands.withLock {
                currentCoroutineContext().ensureActive()
                if (run.revision != revision || run.nextSourceIndex == run.sources.size) return null
                val paused = resumeSignal
                if (paused == null) {
                    val source = run.sources[run.nextSourceIndex++]
                    mutableState.value = supportedRunningState("正在校验：${run.progressMessage(source)}")
                    return source
                }
                paused
            }
            signal.await()
        }
    }

    override suspend fun pause() = commands.withLock {
        if (checkJob?.isActive != true) return@withLock
        if (resumeSignal == null) resumeSignal = CompletableDeferred()
        mutableState.value = mutableState.value.toPausedState("书源校验已暂停")
    }

    override suspend fun resume() = commands.withLock {
        if (checkJob?.isActive != true) return@withLock
        resumeSignal?.complete(Unit)
        resumeSignal = null
        mutableState.value = supportedRunningState("书源校验已继续")
    }

    override suspend fun cancel() {
        val cancelled = commands.withLock {
            ++revision
            resumeSignal?.complete(Unit)
            resumeSignal = null
            val previous = checkJob
            previous?.cancel()
            mutableState.value = supportedIdleState("书源校验已取消")
            previous
        }
        // Keep the draining job visible to both start() and concurrent cancel() calls.
        withContext(NonCancellable) {
            cancelled?.join()
            commands.withLock {
                if (checkJob === cancelled) checkJob = null
            }
        }
    }

    private class SourceCheckRun(
        val sources: List<BookSource>,
        val config: SourceCheckConfig,
        val revision: Long,
        val concurrency: Int,
    ) {
        var nextSourceIndex = 0
        var checked = 0
        var failed = 0
        var skipped = 0

        fun progressMessage(source: BookSource): String =
            "已校验 $checked/${sources.size}，失败 $failed，跳过 $skipped：${source.bookSourceName}"

        fun summary(): String = "已校验 $checked，失败 $failed，跳过 $skipped"
    }
}

internal fun BookSource.withSourceCheckResult(result: SourceCheckResult): BookSource {
    val baseGroups = SourceGroups.split(bookSourceGroup)
        .filterNot { "失效" in it || it == "校验超时" }
        .joinToString(",")
        .takeUnless(String::isBlank)
    val baseSource = copy(
        bookSourceGroup = baseGroups,
        bookSourceComment = bookSourceComment.withoutSourceCheckErrorComments(),
        respondTime = result.respondTimeMs,
        lastUpdateTime = currentTimeMillis(),
    )
    val sourceWithGroups = result.invalidGroups.fold(baseSource) { source, group ->
        source.addGroups(group)
    }
    val failureMessage = result.failureMessage?.takeIf(String::isNotBlank)
        ?: result.invalidGroups.takeIf(Set<String>::isNotEmpty)?.joinToString()
    return if (failureMessage.isNullOrBlank()) {
        sourceWithGroups
    } else {
        sourceWithGroups.copy(
            bookSourceComment = listOfNotNull(
                "// Error: $failureMessage",
                sourceWithGroups.bookSourceComment?.takeIf(String::isNotBlank),
            ).joinToString("\n\n")
        )
    }
}

private fun String?.withoutSourceCheckErrorComments(): String? {
    return this
        ?.split("\n\n")
        ?.filterNot { it.startsWith("// Error: ") }
        ?.joinToString("\n")
        ?.takeUnless(String::isBlank)
}

class ManagedBookCacheService(
    private val getBooksUseCase: GetBooksUseCase,
) : BookCacheService {
    private val mutableState = MutableStateFlow(supportedIdleState("Book caching ready"))
    override val state: StateFlow<ServiceState> = mutableState.asStateFlow()

    override suspend fun start() {
        val count = getBooksUseCase.getAll().count { !it.isTxtLocalBook }
        mutableState.value = if (count > 0) {
            supportedRunningState("Caching $count remote books")
        } else {
            supportedIdleState("No remote books available for caching")
        }
    }

    override suspend fun pause() {
        mutableState.value = mutableState.value.toPausedState("Book caching paused")
    }

    override suspend fun resume() {
        val count = getBooksUseCase.getAll().count { !it.isTxtLocalBook }
        mutableState.value = if (count > 0) {
            supportedRunningState("Resumed caching $count remote books")
        } else {
            supportedIdleState("No remote books available for caching")
        }
    }

    override suspend fun cancel() {
        mutableState.value = supportedIdleState("Book caching cancelled")
    }
}

class ManagedReadAloudService(
    private val getHttpTTSUseCase: GetHttpTTSUseCase,
    private val preferencesStore: AppPreferencesStore,
) : ReadAloudService {
    private val mutableState = MutableStateFlow(supportedIdleState("Read aloud ready"))
    override val state: StateFlow<ServiceState> = mutableState.asStateFlow()
    private val mutableReadAloudState = MutableStateFlow(ReadAloudState(message = "Read aloud ready"))
    override val readAloudState: StateFlow<ReadAloudState> = mutableReadAloudState.asStateFlow()
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var timerJob: Job? = null
    private var currentSession: ReadAloudSession? = null
    private var engineRevision = 0

    init {
        serviceScope.launch {
            preferencesStore.runtimeConfig.map { it.ttsEngine }.distinctUntilChanged().collect { identifier ->
                val session = currentSession ?: return@collect
                currentSession = session.copy(resolvedEngine = resolveEngine(identifier))
                val status = mutableReadAloudState.value.status
                if (status == ReadAloudStatus.RUNNING || status == ReadAloudStatus.PAUSED) {
                    engineRevision += 1
                    syncState(status, "Read aloud engine changed ($engineRevision)")
                }
            }
        }
    }

    override suspend fun start(request: ReadAloudRequest) {
        val blocks = request.blocks.filter { it.text.isNotBlank() }
        if (blocks.isEmpty()) {
            fail("Read aloud has no readable text in the current chapter")
            return
        }
        val runtimeConfig = preferencesStore.runtimeConfig.first()
        val engine = resolveEngine(request.ttsEngine)
        val normalizedPosition = resolveStartPosition(request.startBlockIndex, blocks)
        currentSession = ReadAloudSession(
            request = request.copy(blocks = blocks, startBlockIndex = blocks[normalizedPosition].blockIndex),
            blocks = blocks,
            currentBlockPosition = normalizedPosition,
            currentRangeStart = request.startTextOffset.coerceAtLeast(0),
            currentRangeEnd = request.startTextOffset.coerceAtLeast(0),
            rateSetting = runtimeConfig.reader.toSpeechRateSetting(),
            timerMinutes = runtimeConfig.reader.ttsTimerMinutes,
            isInBackground = false,
            isBackgroundPlaybackEnabled = request.preferBackgroundPlayback,
            resolvedEngine = engine,
        )
        syncState(
            status = if (request.startPaused) ReadAloudStatus.PAUSED else ReadAloudStatus.RUNNING,
            message = if (request.startPaused) "Read aloud paused" else "Read aloud active",
        )
        scheduleTimer(runtimeConfig.reader.ttsTimerMinutes)
    }

    override suspend fun pause() {
        if (currentSession == null) return
        syncState(ReadAloudStatus.PAUSED, "Read aloud paused")
    }

    override suspend fun resume() {
        if (currentSession == null) return
        syncState(ReadAloudStatus.RUNNING, "Read aloud resumed")
    }

    override suspend fun stop() {
        stopWithMessage("Read aloud stopped")
    }

    private fun stopWithMessage(message: String) {
        timerJob?.cancel()
        timerJob = null
        val session = currentSession
        currentSession = null
        mutableReadAloudState.value = ReadAloudState(
            engine = session?.resolvedEngine ?: ReadAloudEngineKind.SYSTEM_TTS,
            status = ReadAloudStatus.STOPPED,
            progress = session?.toProgress() ?: ReadAloudProgress(),
            isSupported = true,
            isBackgroundPlaybackEnabled = session?.isBackgroundPlaybackEnabled ?: false,
            message = message,
            bookUrl = session?.request?.bookUrl,
        )
        mutableState.value = supportedIdleState(message)
    }

    override suspend fun skipToPreviousBlock() {
        val session = currentSession ?: return
        session.currentBlockPosition = (session.currentBlockPosition - 1).coerceAtLeast(0)
        session.currentRangeStart = 0
        session.currentRangeEnd = 0
        syncState(mutableReadAloudState.value.status.resumedStatus(), "Read aloud moved to previous paragraph")
    }

    override suspend fun skipToNextBlock() {
        val session = currentSession ?: return
        session.currentBlockPosition = (session.currentBlockPosition + 1).coerceAtMost(session.blocks.lastIndex)
        session.currentRangeStart = 0
        session.currentRangeEnd = 0
        syncState(mutableReadAloudState.value.status.resumedStatus(), "Read aloud moved to next paragraph")
    }

    override suspend fun updateSpeechRate(setting: ReadAloudSpeechRateSetting) {
        val session = currentSession ?: return
        session.rateSetting = setting.normalized()
        syncState(mutableReadAloudState.value.status, "Read aloud speech rate updated")
    }

    override suspend fun setTimer(minutes: Int) {
        val session = currentSession ?: return
        session.timerMinutes = minutes.coerceIn(0, 180)
        scheduleTimer(session.timerMinutes)
        syncState(mutableReadAloudState.value.status, "Read aloud timer updated")
    }

    override suspend fun setBackgroundPlayback(enabled: Boolean) {
        val session = currentSession ?: return
        session.isBackgroundPlaybackEnabled = enabled
        syncState(mutableReadAloudState.value.status, "Read aloud background playback updated")
    }

    override suspend fun advanceToNextBlock() {
        val session = currentSession ?: return
        if (mutableReadAloudState.value.status != ReadAloudStatus.RUNNING) return
        if (session.currentBlockPosition >= session.blocks.lastIndex) {
            stopWithMessage("Read aloud chapter completed")
            return
        }
        session.currentBlockPosition += 1
        session.currentRangeStart = 0
        session.currentRangeEnd = 0
        syncState(ReadAloudStatus.RUNNING, "Read aloud advanced")
    }

    override suspend fun updateCurrentBlockRange(start: Int, end: Int) {
        val session = currentSession ?: return
        session.currentRangeStart = start.coerceAtLeast(0)
        session.currentRangeEnd = end.coerceAtLeast(session.currentRangeStart)
        syncState(mutableReadAloudState.value.status, mutableReadAloudState.value.message ?: "Read aloud active")
    }

    override suspend fun updatePlaybackState(isInBackground: Boolean) {
        val session = currentSession ?: return
        session.isInBackground = isInBackground
        syncState(mutableReadAloudState.value.status, mutableReadAloudState.value.message ?: "Read aloud active")
    }

    override suspend fun fail(message: String) {
        timerJob?.cancel()
        val session = currentSession
        mutableReadAloudState.value = ReadAloudState(
            engine = session?.resolvedEngine ?: ReadAloudEngineKind.SYSTEM_TTS,
            status = ReadAloudStatus.ERROR,
            progress = session?.toProgress() ?: ReadAloudProgress(),
            isSupported = true,
            isBackgroundPlaybackEnabled = session?.isBackgroundPlaybackEnabled ?: false,
            message = message,
            bookUrl = session?.request?.bookUrl,
        )
        mutableState.value = ServiceState(
            isSupported = true,
            isRunning = false,
            isPaused = false,
            message = message,
        )
    }

    private suspend fun resolveEngine(ttsEngine: String?): ReadAloudEngineKind {
        val selectedId = ttsEngine?.removePrefix("httpTts:")?.toLongOrNull() ?: return ReadAloudEngineKind.SYSTEM_TTS
        val matched = getHttpTTSUseCase.getAll().any { it.id == selectedId }
        return if (matched) ReadAloudEngineKind.HTTP_TTS else ReadAloudEngineKind.SYSTEM_TTS
    }

    private fun resolveStartPosition(startBlockIndex: Int, blocks: List<ReadAloudBlock>): Int {
        val exact = blocks.indexOfFirst { it.blockIndex == startBlockIndex }
        return when {
            exact >= 0 -> exact
            startBlockIndex <= 0 -> 0
            else -> blocks.lastIndex
        }
    }

    private fun scheduleTimer(minutes: Int) {
        timerJob?.cancel()
        if (minutes <= 0) return
        timerJob = serviceScope.launch {
            delay(minutes * 60_000L)
            stop()
        }
    }

    private fun syncState(status: ReadAloudStatus, message: String) {
        val session = currentSession ?: return
        mutableReadAloudState.value = ReadAloudState(
            engine = session.resolvedEngine,
            status = status,
            progress = session.toProgress(),
            isSupported = true,
            isBackgroundPlaybackEnabled = session.isBackgroundPlaybackEnabled,
            message = message,
            bookUrl = session.request.bookUrl,
        )
        mutableState.value = ServiceState(
            isSupported = true,
            isRunning = status == ReadAloudStatus.RUNNING,
            isPaused = status == ReadAloudStatus.PAUSED,
            message = message,
        )
    }
}

class ManagedAudioPlayService(
    private val getBooksUseCase: GetBooksUseCase,
) : AudioPlayService {
    private val mutableState = MutableStateFlow(supportedIdleState("Audio play ready"))
    override val state: StateFlow<ServiceState> = mutableState.asStateFlow()

    override suspend fun start() {
        val count = getBooksUseCase.getAll().count { it.isAudio }
        mutableState.value = if (count > 0) {
            supportedRunningState("Audio play active ($count audio books)")
        } else {
            supportedIdleState("No audio books available for playback")
        }
    }

    override suspend fun pause() {
        mutableState.value = mutableState.value.toPausedState("Audio play paused")
    }

    override suspend fun resume() {
        val count = getBooksUseCase.getAll().count { it.isAudio }
        mutableState.value = if (count > 0) {
            supportedRunningState("Audio play resumed ($count audio books)")
        } else {
            supportedIdleState("No audio books available for playback")
        }
    }

    override suspend fun cancel() {
        mutableState.value = supportedIdleState("Audio play stopped")
    }
}

class ManagedRemoteLibraryService(
    private val getServersUseCase: GetServersUseCase,
    private val preferencesStore: AppPreferencesStore,
) : RemoteLibraryService {
    private val mutableState = MutableStateFlow(supportedIdleState("Remote library ready"))
    override val state: StateFlow<ServiceState> = mutableState.asStateFlow()

    override suspend fun refresh() {
        val remoteServerId = preferencesStore.runtimeConfig.first().remoteServerId
        if (remoteServerId == 0L) {
            mutableState.value = supportedIdleState("No remote server configured")
            return
        }
        val server = getServersUseCase.getAll().firstOrNull { it.id == remoteServerId }
        mutableState.value = if (server != null) {
            supportedIdleState("Remote library refreshed: ${server.name}")
        } else {
            supportedIdleState("Configured remote server not found: $remoteServerId")
        }
    }

    override suspend fun cancel() {
        mutableState.value = supportedIdleState("Remote library refresh cancelled")
    }
}

private fun supportedIdleState(message: String): ServiceState {
    return ServiceState(
        isSupported = true,
        isRunning = false,
        isPaused = false,
        message = message,
    )
}

private fun supportedRunningState(message: String): ServiceState {
    return ServiceState(
        isSupported = true,
        isRunning = true,
        isPaused = false,
        message = message,
    )
}

private fun ServiceState.toPausedState(message: String): ServiceState {
    return if (!isRunning && !isPaused) {
        copy(message = this.message ?: message)
    } else {
        copy(isRunning = false, isPaused = true, message = message)
    }
}

private data class ReadAloudSession(
    val request: ReadAloudRequest,
    val blocks: List<ReadAloudBlock>,
    var currentBlockPosition: Int,
    var currentRangeStart: Int,
    var currentRangeEnd: Int,
    var rateSetting: ReadAloudSpeechRateSetting,
    var timerMinutes: Int,
    var isInBackground: Boolean,
    var isBackgroundPlaybackEnabled: Boolean,
    val resolvedEngine: ReadAloudEngineKind,
) {
    fun toProgress(): ReadAloudProgress {
        return ReadAloudProgress(
            chapterIndex = request.chapterIndex,
            blockIndex = blocks.getOrNull(currentBlockPosition)?.blockIndex ?: request.startBlockIndex,
            utteranceRangeStart = currentRangeStart,
            utteranceRangeEnd = currentRangeEnd,
            isInBackground = isInBackground,
            speechRate = rateSetting.value,
            remainingTimerMinutes = timerMinutes,
        )
    }
}

private fun ReaderRuntimeConfig.toSpeechRateSetting(): ReadAloudSpeechRateSetting {
    return ReadAloudSpeechRateSetting(
        followSystem = ttsFollowSystemRate,
        value = if (ttsFollowSystemRate) 1.0f else ((ttsSpeechRate.coerceIn(0, 45) + 5) / 10f),
    ).normalized()
}

private fun ReadAloudSpeechRateSetting.normalized(): ReadAloudSpeechRateSetting {
    return if (followSystem) copy(value = 1.0f) else copy(value = value.coerceIn(0.5f, 5.0f))
}

private fun ReadAloudStatus.resumedStatus(): ReadAloudStatus {
    return if (this == ReadAloudStatus.PAUSED) ReadAloudStatus.RUNNING else this
}
