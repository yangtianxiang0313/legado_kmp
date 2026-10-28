package io.legado.kmp.shared.facade

import io.legado.kmp.shared.domain.repository.BookChapterRepository
import io.legado.kmp.shared.domain.repository.BookRepository
import io.legado.kmp.shared.domain.repository.BookSourceRepository
import io.legado.kmp.shared.domain.repository.WebBookRepository
import io.legado.kmp.shared.preferences.AppPreferencesStore
import io.legado.kmp.shared.network.LegacyJsConnectGateway
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.ReadConfig
import io.legado.kmp.shared.model.ReadSimulationSchedule
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlin.coroutines.cancellation.CancellationException

enum class AudioPlayMode(val value: Int) {
    LIST_END_STOP(0),
    SINGLE_LOOP(1),
    RANDOM(2),
    LIST_LOOP(3);

    fun next(): AudioPlayMode = entries[(ordinal + 1) % entries.size]

    companion object {
        fun fromValue(value: Int): AudioPlayMode =
            entries.firstOrNull { it.value == value } ?: LIST_END_STOP
    }
}

/**
 * Playback status aligned with legado Status.STOP/PLAY/PAUSE.
 *
 * Aligns with legado `io.legado.app.constant.Status` used by `AudioPlay.status`.
 * IDLE is the initial state before any playback action.
 */
enum class AudioPlayStatus {
    /** No playback session active (initial state). */
    IDLE,
    /** Audio content is being loaded/buffered. */
    LOADING,
    /** Audio is actively playing. */
    PLAYING,
    /** Audio is paused, can be resumed. */
    PAUSED,
    /** Audio playback has been stopped (session ended). */
    STOPPED;
}

data class AudioChapterInfo(
    val index: Int,
    val title: String,
    val totalChapters: Int,
    /** Audio size (duration in ms) from chapter.end, 0 if unknown. Aligns with legado upDurChapter. */
    val durAudioSize: Long,
)

/**
 * Result of getAudioUrl, carrying the actual chapter index (may differ from requested
 * if volume chapters were skipped) and the resolved audio URL.
 */
data class AudioUrlResult(
    val actualChapterIndex: Int,
    val audioUrl: String,
)

/**
 * Result of [AudioPlayFacade.upData], describing what changed so the caller
 * can take appropriate action (e.g., stop playback if chapter changed).
 */
data class AudioUpDataResult(
    val book: Book,
    val chapterSize: Int,
    val simulatedChapterSize: Int,
    /** True if the book's durChapterIndex differs from [previousChapterIndex]. */
    val chapterChanged: Boolean,
)

/**
 * Result of [AudioPlayFacade.resetData], providing all state needed to
 * initialize a fresh audio playback session.
 */
data class AudioResetResult(
    val book: Book,
    val chapterSize: Int,
    val simulatedChapterSize: Int,
    val chapterInfo: AudioChapterInfo?,
)

class AudioPlayFacade(
    private val bookRepository: BookRepository,
    private val bookChapterRepository: BookChapterRepository,
    private val bookSourceRepository: BookSourceRepository,
    private val webBookRepository: WebBookRepository,
    private val preferencesStore: AppPreferencesStore,
    private val mediaGateway: LegacyJsConnectGateway,
) {
    // A37/A38/A39: Android Service lifecycle (register/unregister/onCreate/onDestroy)
    // are N/A in KMP. The stateless Facade design eliminates the need for
    // register/unregister patterns. The platform layer manages its own lifecycle
    // (e.g., iOS AVAudioSession setup/teardown) independently of the Facade.

    /**
     * Mutex-protected set of chapter indices currently being loaded.
     * Prevents duplicate loading of the same chapter.
     *
     * Aligns with legado AudioPlay.loadingChapters + addLoading/removeLoading.
     */
    private val loadingMutex = Mutex()
    private val loadingChapters = mutableSetOf<Int>()

    // A36: Loading state as SharedFlow for UI observation
    private val _loadingState = MutableSharedFlow<Boolean>(extraBufferCapacity = 1)
    /** Observable loading state. Aligns with legado AudioPlay upLoading event. */
    val loadingState: SharedFlow<Boolean> = _loadingState.asSharedFlow()

    // --- A13: Play mode change event ---
    private val _playModeChanged = MutableSharedFlow<Int>(extraBufferCapacity = 1)
    /** Emits the new play mode value when play mode changes. Aligns with legado EventBus.PLAY_MODE_CHANGED. */
    val playModeChanged: SharedFlow<Int> = _playModeChanged.asSharedFlow()

    // --- A21: Chapter change event ---
    private val _chapterChanged = MutableSharedFlow<AudioChapterInfo>(extraBufferCapacity = 1)
    /** Emits when the current chapter info changes. Aligns with legado upDurChapter() posting AUDIO_SUB_TITLE/AUDIO_SIZE/AUDIO_PROGRESS. */
    val chapterChanged: SharedFlow<AudioChapterInfo> = _chapterChanged.asSharedFlow()

    // --- A30: Timer change event ---
    private val _timerChanged = MutableSharedFlow<Int>(extraBufferCapacity = 1)
    /** Emits remaining minutes when timer is updated. Aligns with legado EventBus.AUDIO_DS. */
    val timerChanged: SharedFlow<Int> = _timerChanged.asSharedFlow()

    /**
     * Try to add a chapter index to the loading set.
     *
     * @return true if the index was added (not already loading), false if already loading
     */
    suspend fun addLoading(index: Int): Boolean {
        return try {
            val added = loadingMutex.withLock { loadingChapters.add(index) }
            if (added) _loadingState.tryEmit(true)
            added
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            CrashCollector.record("AudioPlayFacade", "addLoading", mapOf("index" to index.toString()), e)
            false
        }
    }

    /**
     * Remove a chapter index from the loading set.
     */
    suspend fun removeLoading(index: Int) {
        try {
            loadingMutex.withLock { loadingChapters.remove(index) }
            val isEmpty = loadingMutex.withLock { loadingChapters.isEmpty() }
            if (isEmpty) _loadingState.tryEmit(false)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            CrashCollector.record("AudioPlayFacade", "removeLoading", mapOf("index" to index.toString()), e)
        }
    }

    /**
     * Clear all loading chapter indices.
     */
    suspend fun clearLoading() {
        try {
            loadingMutex.withLock { loadingChapters.clear() }
            _loadingState.tryEmit(false)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            CrashCollector.record("AudioPlayFacade", "clearLoading", error = e)
        }
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun loadBook(bookUrl: String): Book {
        return runRecoverable("AudioPlayFacade.loadBook") {
            bookRepository.getBook(bookUrl) ?: throw IllegalArgumentException("Book not found: $bookUrl")
        }
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun getChapters(bookUrl: String): List<BookChapter> {
        return runRecoverable("AudioPlayFacade.getChapters") {
            bookChapterRepository.getChaptersByBookUrl(bookUrl)
        }
    }

    /**
     * Get audio URL for a chapter, automatically skipping volume (isVolume) chapters.
     * Integrates with the loading set to prevent duplicate loading of the same chapter.
     *
     * Aligns with legado AudioPlay.loadPlayUrl():
     * - Calls addLoading() before starting; throws if already loading
     * - If the target chapter is a volume header (isVolume=true), skip forward to the next
     *   non-volume chapter and return its audio URL.
     * - Returns a pair of (actualChapterIndex, audioUrl) so the caller knows which chapter
     *   was actually loaded (may differ from requested index if volumes were skipped).
     * - Always calls removeLoading() on completion or error.
     *
     * @param bookUrl the book URL
     * @param chapterIndex the requested chapter index
     * @param chapterSize total number of real chapters (use computeSimulatedChapterSize result)
     * @return AudioUrlResult with the actual chapter index and audio URL
     * @throws RecoverableSharedException if no playable chapter found, content fetch fails,
     *         or the chapter is already being loaded
     */
    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun getAudioUrl(bookUrl: String, chapterIndex: Int, chapterSize: Int = Int.MAX_VALUE): AudioUrlResult {
        if (!addLoading(chapterIndex)) {
            throw RecoverableSharedException(
                code = "AudioPlayFacade.getAudioUrl",
                message = "Chapter $chapterIndex is already being loaded"
            )
        }
        return try {
            runRecoverable("AudioPlayFacade.getAudioUrl") {
                val book = bookRepository.getBook(bookUrl)
                    ?: throw IllegalArgumentException("Book not found: $bookUrl")
                val source = bookSourceRepository.getBookSource(book.origin)
                    ?: throw IllegalArgumentException("Source not found: ${book.origin}")

                // Skip volume chapters (aligns with legado loadPlayUrl isVolume check)
                var actualIndex = chapterIndex
                while (actualIndex < chapterSize) {
                    val chapter = bookChapterRepository.getChapter(bookUrl, actualIndex)
                        ?: throw IllegalArgumentException("Chapter not found: $actualIndex")
                    if (!chapter.isVolume) {
                        val result = webBookRepository.getChapterContent(source, book, chapter)
                        val content = result.getOrThrow()
                        if (content.isEmpty()) {
                            throw IllegalStateException("Empty audio URL for chapter $actualIndex")
                        }
                        return@runRecoverable AudioUrlResult(actualIndex, content)
                    }
                    // isVolume chapter: skip to next (aligns with legado: skipTo(index + 1))
                    actualIndex++
                }
                throw IllegalStateException("No playable chapter found from index $chapterIndex")
            }
        } finally {
            removeLoading(chapterIndex)
        }
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun preparePlaybackRequest(bookUrl: String, chapterIndex: Int, chapterSize: Int): AudioPlaybackRequest =
        runRecoverable("AudioPlayFacade.preparePlaybackRequest") {
            val resolved = getAudioUrl(bookUrl, chapterIndex, chapterSize)
            val book = requireNotNull(bookRepository.getBook(bookUrl)) { "书籍不存在" }
            val source = requireNotNull(bookSourceRepository.getBookSource(book.origin)) { "书源不存在" }
            val chapter = requireNotNull(bookChapterRepository.getChapter(bookUrl, resolved.actualChapterIndex)) { "章节不存在" }
            AudioPlaybackRequest(
                resolved.actualChapterIndex,
                mediaGateway.prepareMediaForLegacyJs(
                    urlRule = resolved.audioUrl, source = source, baseUrl = chapter.getAbsoluteUrl(),
                    ruleData = mapOf("book" to book, "chapter" to chapter), chapter = chapter,
                ),
            )
        }

    /**
     * Save audio reading progress with full legado saveRead semantics:
     * - Resets lastCheckCount to 0
     * - Updates durChapterTime to current time
     * - Updates durChapterIndex and durChapterPos
     * - When chapter changed, resolves the chapter title for durChapterTitle
     *
     * Aligns with legado AudioPlay.saveRead().
     *
     * @param bookUrl the book URL
     * @param chapterIndex current chapter index
     * @param chapterPos current playback position
     * @param previousChapterIndex the chapter index before this save (to detect chapter change)
     */
    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun saveProgress(
        bookUrl: String,
        chapterIndex: Int,
        chapterPos: Int,
        previousChapterIndex: Int
    ) {
        runRecoverable("AudioPlayFacade.saveProgress") {
            val chapterTitle: String? = if (chapterIndex != previousChapterIndex) {
                // Chapter changed: resolve the display title (aligns with legado saveRead
                // which uses ContentProcessor.getTitleReplaceRules + getDisplayTitle)
                val chapter = bookChapterRepository.getChapter(bookUrl, chapterIndex)
                chapter?.getDisplayTitle()
            } else {
                // Chapter unchanged: use existing title from the book record
                val book = bookRepository.getBook(bookUrl)
                book?.durChapterTitle
            }

            // Use the audio-specific update that also resets last_check_count = 0
            bookRepository.updateAudioReadingProgress(
                bookUrl = bookUrl,
                chapterIndex = chapterIndex,
                chapterTitle = chapterTitle,
                chapterPos = chapterPos
            )
        }
    }

    /**
     * Save the audio duration to the chapter's end field.
     *
     * Aligns with legado AudioPlay.saveDurChapter(audioSize):
     * - Sets chapter.end = audioSize (total duration in ms)
     * - Used by isPlayToEnd() and UI progress display
     *
     * @param bookUrl the book URL
     * @param chapterIndex the chapter index
     * @param audioSize the total audio duration in milliseconds
     * @return the updated durAudioSize (audioSize as Int), or null if chapter not found
     */
    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun saveDurChapter(bookUrl: String, chapterIndex: Int, audioSize: Long): Int? {
        return runRecoverable("AudioPlayFacade.saveDurChapter") {
            val chapter = bookChapterRepository.getChapter(bookUrl, chapterIndex) ?: return@runRecoverable null
            val updatedChapter = chapter.copy(end = audioSize)
            bookChapterRepository.update(updatedChapter)
            audioSize.toInt()
        }
    }

    /**
     * Handle playback position change: save progress immediately.
     *
     * Aligns with legado AudioPlay.playPositionChanged(position):
     * - Updates durChapterPos
     * - Calls saveRead()
     *
     * @param bookUrl the book URL
     * @param chapterIndex current chapter index
     * @param position current playback position in ms
     */
    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun savePlayPosition(bookUrl: String, chapterIndex: Int, position: Int) {
        saveProgress(
            bookUrl = bookUrl,
            chapterIndex = chapterIndex,
            chapterPos = position,
            previousChapterIndex = chapterIndex // same chapter, no title re-resolve needed
        )
    }

    /**
     * Get chapter info including durAudioSize from chapter.end.
     *
     * Aligns with legado AudioPlay.upDurChapter() which reads chapter.end into durAudioSize
     * and broadcasts AUDIO_SUB_TITLE, AUDIO_SIZE, AUDIO_PROGRESS events.
     */
    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun getChapterInfo(bookUrl: String, chapterIndex: Int): AudioChapterInfo {
        return runRecoverable("AudioPlayFacade.chapterInfo") {
            val chapter = bookChapterRepository.getChapter(bookUrl, chapterIndex)
                ?: throw IllegalArgumentException("Chapter not found: $chapterIndex")
            val total = bookChapterRepository.getChapterCount(bookUrl)
            val info = AudioChapterInfo(
                index = chapter.index,
                title = chapter.title,
                totalChapters = total,
                durAudioSize = chapter.end ?: 0L,
            )
            // A21: Emit chapter change event (aligns with legado upDurChapter posting events)
            _chapterChanged.tryEmit(info)
            info
        }
    }

    /**
     * Update book data while preserving loaded state.
     *
     * Aligns with legado AudioPlay.upData(book):
     * - Refreshes chapterSize and simulatedChapterSize from DB
     * - Detects if durChapterIndex changed (caller should stop playback and reset URL/position)
     * - Returns the new state so caller can act on chapter change
     *
     * @param bookUrl the book URL
     * @param previousChapterIndex the chapter index the caller currently has
     * @return AudioUpDataResult with updated sizes and whether the chapter changed
     */
    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun upData(bookUrl: String, previousChapterIndex: Int): AudioUpDataResult {
        return runRecoverable("AudioPlayFacade.upData") {
            val book = bookRepository.getBook(bookUrl)
                ?: throw IllegalArgumentException("Book not found: $bookUrl")
            val chapterSize = bookChapterRepository.getChapterCount(bookUrl)
            val simulatedChapterSize = computeSimulatedChapterSize(book.readConfig, chapterSize)
            val chapterChanged = previousChapterIndex != book.durChapterIndex
            AudioUpDataResult(
                book = book,
                chapterSize = chapterSize,
                simulatedChapterSize = simulatedChapterSize,
                chapterChanged = chapterChanged,
            )
        }
    }

    /**
     * Reset all audio play state and initialize fresh for a given book.
     *
     * Aligns with legado AudioPlay.resetData(book):
     * - Clears loading set
     * - Loads fresh chapterSize and simulatedChapterSize
     * - Reads durChapterIndex/durChapterPos from book
     * - Loads current chapter info (including durAudioSize from chapter.end)
     * - Returns all data needed for a fresh session
     *
     * The caller is responsible for stopping any active playback before calling this.
     *
     * @param bookUrl the book URL
     * @return AudioResetResult with all state for a fresh session
     */
    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun resetData(bookUrl: String): AudioResetResult {
        clearLoading()
        return runRecoverable("AudioPlayFacade.resetData") {
            val book = bookRepository.getBook(bookUrl)
                ?: throw IllegalArgumentException("Book not found: $bookUrl")
            val chapterSize = bookChapterRepository.getChapterCount(bookUrl)
            val simulatedChapterSize = computeSimulatedChapterSize(book.readConfig, chapterSize)
            val chapterInfo = if (chapterSize > 0 && book.durChapterIndex in 0 until chapterSize) {
                val chapter = bookChapterRepository.getChapter(bookUrl, book.durChapterIndex)
                chapter?.let {
                    AudioChapterInfo(
                        index = it.index,
                        title = it.title,
                        totalChapters = chapterSize,
                        durAudioSize = it.end ?: 0L,
                    )
                }
            } else {
                null
            }
            AudioResetResult(
                book = book,
                chapterSize = chapterSize,
                simulatedChapterSize = simulatedChapterSize,
                chapterInfo = chapterInfo,
            )
        }
    }

    // --- Pure computation methods (no state, no I/O) ---

    /**
     * Determine the current playback status from component states.
     *
     * Aligns with legado AudioPlay.status (Status.STOP/PLAY/PAUSE).
     * Since the Facade doesn't hold singleton state, this is a pure function
     * that derives status from the caller's state flags.
     *
     * @param isServiceRunning whether the audio player service is currently running
     * @param isPlaying whether audio is actively playing
     * @param isPaused whether audio is paused
     * @param isLoading whether audio content is being loaded
     * @return the current AudioPlayStatus
     */
    fun getCurrentStatus(
        isServiceRunning: Boolean,
        isPlaying: Boolean,
        isPaused: Boolean,
        isLoading: Boolean,
    ): AudioPlayStatus {
        if (!isServiceRunning) return AudioPlayStatus.STOPPED
        if (isLoading) return AudioPlayStatus.LOADING
        if (isPlaying) return AudioPlayStatus.PLAYING
        if (isPaused) return AudioPlayStatus.PAUSED
        return AudioPlayStatus.IDLE
    }

    /**
     * Compute the simulated chapter size based on readConfig simulation settings.
     *
     * Aligns with legado BookExtensions.simulatedTotalChapterNum():
     * - If readSimulating is false, returns realChapterSize.
     * - Otherwise, calculates unlocked chapters based on startDate, startChapter,
     *   dailyChapters, and current date.
     *
     * @param readConfig the book's ReadConfig (may be null)
     * @param realChapterSize the actual total number of chapters
     * @return the effective chapter size (may be less than realChapterSize if simulating)
     */
    fun computeSimulatedChapterSize(readConfig: ReadConfig?, realChapterSize: Int): Int {
        return ReadSimulationSchedule.count(readConfig, realChapterSize)
    }

    /**
     * Compute the next chapter index based on play mode.
     *
     * Aligns with legado AudioPlay.next():
     * - Uses simulatedChapterSize (not raw chapter count)
     * - LIST_END_STOP: returns null if already at last chapter (caller should not reload)
     * - SINGLE_LOOP: returns currentIndex (same chapter)
     * - RANDOM: returns a random index in [0, totalChapters)
     * - LIST_LOOP: wraps around
     *
     * Returns null when playback should stop (LIST_END_STOP at end).
     * This allows the caller to distinguish "no change" from "same chapter replay".
     *
     * @param currentIndex current chapter index
     * @param totalChapters effective chapter count (use computeSimulatedChapterSize result)
     * @param modeValue AudioPlayMode ordinal value
     * @return the next chapter index, or null if playback should stop
     */
    fun computeNextChapterIndex(
        currentIndex: Int,
        totalChapters: Int,
        modeValue: Int,
    ): Int? {
        val mode = AudioPlayMode.fromValue(modeValue)
        return when (mode) {
            AudioPlayMode.LIST_END_STOP -> {
                if (currentIndex + 1 < totalChapters) currentIndex + 1 else null
            }
            AudioPlayMode.SINGLE_LOOP -> currentIndex
            AudioPlayMode.RANDOM -> (0 until totalChapters).random()
            AudioPlayMode.LIST_LOOP -> (currentIndex + 1) % totalChapters
        }
    }

    fun computePrevChapterIndex(currentIndex: Int): Int {
        return (currentIndex - 1).coerceAtLeast(0)
    }

    /**
     * Determine whether to play from beginning (playNew) or resume (play).
     *
     * Aligns with legado AudioPlay.upPlayUrl() / isPlayToEnd():
     * - If the current position equals the audio size AND the current chapter is the last one,
     *   the track has played to the end -> should playNew (start from beginning).
     * - Otherwise, resume from current position.
     *
     * @param currentChapterIndex current chapter index
     * @param currentPosition current playback position in the chapter
     * @param audioSize total audio size/duration of the current chapter
     * @param totalChapters effective chapter count (use computeSimulatedChapterSize result)
     * @return true if playNew should be used, false if play (resume) should be used
     */
    fun shouldPlayNew(
        currentChapterIndex: Int,
        currentPosition: Int,
        audioSize: Int,
        totalChapters: Int
    ): Boolean {
        return currentChapterIndex + 1 == totalChapters && currentPosition == audioSize
    }

    /**
     * Validate that a loaded audio URL belongs to the expected chapter.
     *
     * Aligns with legado AudioPlay.contentLoadFinish(chapter, content):
     * - Checks that the loaded chapter index matches the current durChapterIndex
     * - If matched, the caller should cache the content as durPlayUrl
     * - If not matched, the loaded content is stale and should be discarded
     *
     * @param loadedChapterIndex the chapter index that was loaded
     * @param currentChapterIndex the chapter index the player currently expects
     * @return true if the loaded content matches the current chapter
     */
    fun isContentLoadValid(loadedChapterIndex: Int, currentChapterIndex: Int): Boolean {
        return loadedChapterIndex == currentChapterIndex
    }

    /**
     * Determine whether to load the audio URL or use the cached one.
     *
     * Aligns with legado AudioPlay.loadOrUpPlayUrl():
     * - If durPlayUrl is empty, should load (fetch from server)
     * - If durPlayUrl is not empty, should use cached URL directly
     *
     * @param durPlayUrl the currently cached play URL (empty string if none)
     * @return true if the URL needs to be loaded, false if cached URL can be used
     */
    fun shouldLoadUrl(durPlayUrl: String): Boolean {
        return durPlayUrl.isEmpty()
    }

    /**
     * Adjust playback speed by a delta value, clamped to [0.5, 3.0].
     *
     * Aligns with legado AudioPlay.adjustSpeed() -> AudioPlayService.upSpeed():
     * - The delta is added to the current speed (e.g., +0.1 or -0.1).
     * - Result is clamped to the valid range.
     *
     * @param currentSpeed current playback speed
     * @param delta speed adjustment (positive to speed up, negative to slow down)
     * @return the new speed, clamped to [0.5, 3.0]
     */
    fun adjustSpeed(currentSpeed: Float, delta: Float): Float {
        return (currentSpeed + delta).coerceIn(0.5f, 3.0f)
    }

    /**
     * Validate and clamp a chapter index to the valid range.
     *
     * Aligns with legado AudioPlay.skipTo() which checks `index in 0..<simulatedChapterSize`.
     *
     * @param index the requested chapter index
     * @param chapterSize the effective chapter size (use computeSimulatedChapterSize result)
     * @return the clamped index within [0, chapterSize-1], or null if chapterSize is 0
     */
    fun validateChapterIndex(index: Int, chapterSize: Int): Int? {
        if (chapterSize <= 0) return null
        return index.coerceIn(0, chapterSize - 1)
    }

    /**
     * Compute the timer value after appending additional minutes.
     *
     * Aligns with legado AudioPlay.addTimer() which sends IntentAction.addTimer
     * to the service. The service typically adds a fixed increment (e.g. 10 minutes)
     * to the remaining timer.
     *
     * @param currentRemainingMinutes the current remaining timer minutes
     * @param incrementMinutes the minutes to add (default 10, matching legado service behavior)
     * @return the new remaining minutes
     */
    fun addTimer(currentRemainingMinutes: Int, incrementMinutes: Int = 10): Int {
        val newMinutes = currentRemainingMinutes + incrementMinutes
        // A30: Emit timer change event
        _timerChanged.tryEmit(newMinutes)
        return newMinutes
    }

    /**
     * Set the timer to a specific value and emit change event.
     *
     * Aligns with legado AudioPlay.setTimer(minute) which sends IntentAction.setTimer
     * and posts EventBus.AUDIO_DS.
     *
     * @param minutes the timer value in minutes
     */
    fun setTimer(minutes: Int) {
        _timerChanged.tryEmit(minutes)
    }

    /**
     * Compute the next play mode after cycling.
     *
     * Aligns with legado AudioPlay.changePlayMode() which calls playMode.next().
     *
     * @param currentModeValue current AudioPlayMode value
     * @return the next AudioPlayMode value
     */
    fun computeNextPlayMode(currentModeValue: Int): Int {
        return AudioPlayMode.fromValue(currentModeValue).next().value
    }

    /**
     * Save play mode to preferences and emit change event.
     *
     * Aligns with legado AudioPlay.changePlayMode() which updates playMode
     * and posts EventBus.PLAY_MODE_CHANGED.
     *
     * @param modeValue the AudioPlayMode value to persist (0-3)
     */
    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun savePlayMode(modeValue: Int) {
        runRecoverable("AudioPlayFacade.savePlayMode") {
            val clamped = modeValue.coerceIn(0, 3)
            preferencesStore.setAudioPlayMode(clamped)
            _playModeChanged.tryEmit(clamped)
        }
    }

    /**
     * Get the persisted play mode from preferences.
     *
     * @return the current AudioPlayMode value (0-3)
     */
    suspend fun getPlayMode(): Int {
        return try {
            preferencesStore.runtimeConfig.first().audioPlayMode
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            CrashCollector.record("AudioPlayFacade", "getPlayMode", error = e)
            0 // default to LIST_END_STOP
        }
    }

    /**
     * Change play mode: compute next, persist, and emit.
     * Convenience method combining computeNextPlayMode + savePlayMode.
     *
     * Aligns with legado AudioPlay.changePlayMode().
     *
     * @param currentModeValue current AudioPlayMode value
     * @return the new AudioPlayMode value
     */
    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun changePlayMode(currentModeValue: Int): Int {
        val next = computeNextPlayMode(currentModeValue)
        savePlayMode(next)
        return next
    }

    /**
     * Check if a book is in the bookshelf.
     *
     * Aligns with legado AudioPlay.inBookshelf property.
     *
     * @param bookUrl the book URL
     * @return true if the book exists in the bookshelf
     */
    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun isInBookshelf(bookUrl: String): Boolean {
        return runRecoverable("AudioPlayFacade.isInBookshelf") {
            bookRepository.getBook(bookUrl) != null
        }
    }

    /**
     * Determine whether the player should stop or just stop playback.
     *
     * Aligns with legado AudioPlay.stopPlay() vs AudioPlay.stop():
     * - stopPlay: stops playback but keeps the session alive (service still running)
     * - stop: full stop, destroys the service/session
     *
     * This is a pure function for the caller to decide behavior.
     *
     * @param isFullStop true to indicate full stop (destroy session), false for just pausing playback
     * @param durPlayUrl the current cached play URL — will be cleared on full stop
     * @return the new durPlayUrl value (empty string if full stop, unchanged otherwise)
     */
    fun computeStopState(isFullStop: Boolean, durPlayUrl: String): String {
        return if (isFullStop) "" else durPlayUrl
    }
}
