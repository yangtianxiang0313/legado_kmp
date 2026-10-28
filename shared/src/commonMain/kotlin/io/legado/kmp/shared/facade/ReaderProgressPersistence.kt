package io.legado.kmp.shared.facade

import io.legado.kmp.shared.domain.usecase.ApplyReplaceRulesUseCase
import io.legado.kmp.shared.domain.usecase.GetBookUseCase
import io.legado.kmp.shared.domain.usecase.ObserveBookChaptersUseCase
import io.legado.kmp.shared.domain.usecase.UpdateReadingProgressUseCase
import io.legado.kmp.shared.domain.usecase.resolveDisplayChapterTitle
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.BookProgress
import io.legado.kmp.shared.model.ReadSimulationSchedule
import io.legado.kmp.shared.preferences.AppPreferencesStore
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.first

/** Progress persistence and snapshots; chapter content loading stays in ReaderFacade. */
internal class ReaderProgressPersistence(
    private val getBookUseCase: GetBookUseCase,
    private val observeBookChaptersUseCase: ObserveBookChaptersUseCase,
    private val updateReadingProgressUseCase: UpdateReadingProgressUseCase,
    private val applyReplaceRulesUseCase: ApplyReplaceRulesUseCase,
    private val preferencesStore: AppPreferencesStore,
    private val settingsFacade: SettingsFacade,
) {
    private val progressUploads = ReaderProgressUploadQueue(preferencesStore, settingsFacade)
    /** Preserves the original position across consecutive jumps until it is restored. */
    private var lastBookProgress: BookProgress? = null

    var webBookProgress: BookProgress? = null

    suspend fun updateReadingProgress(
        bookUrl: String,
        current: Book,
        chapterIndex: Int,
        chapterTitle: String?,
        chapterPosition: Int,
    ) {
        val storedChapters = observeBookChaptersUseCase(bookUrl).first()
        val normalizedIndex = if (storedChapters.isEmpty()) {
            chapterIndex.coerceAtLeast(0)
        } else {
            chapterIndex.coerceIn(0, storedChapters.lastIndex)
        }
        val resolvedTitle = storedChapters.getOrNull(normalizedIndex)?.let { chapter ->
            resolveDisplayChapterTitle(current, chapter, applyReplaceRulesUseCase)
        } ?: current.durChapterTitle?.takeIf { current.durChapterIndex == normalizedIndex }
            ?: chapterTitle?.let { BookChapter(title = it).getDisplayTitle() }
        val updatedBook = current.updateReadingProgress(
            chapterIndex = normalizedIndex,
            chapterTitle = resolvedTitle,
            chapterPos = chapterPosition,
        )
        persistProgressIfChanged(current = current, updated = updatedBook)
    }

    suspend fun saveCurrentBookProgress(bookUrl: String) {
        try {
            if (lastBookProgress != null) return
            val book = getBookUseCase.get(bookUrl) ?: return
            lastBookProgress = BookProgress(book)
        } catch (e: kotlin.coroutines.cancellation.CancellationException) {
            throw e
        } catch (e: Throwable) {
            CrashCollector.record("ReaderFacade", "saveCurrentBookProgress", error = e)
        }
    }

    fun takeLastBookProgress(): BookProgress? {
        val progress = lastBookProgress ?: return null
        lastBookProgress = null
        return progress
    }

    /** Returns the confirmed explicit write and its target, or null for a no-op. */
    suspend fun setProgress(bookUrl: String, book: Book, progress: BookProgress): ReaderProgressWrite? {
        val approval = currentCoroutineContext()[ReaderProgressExpectation]?.book
        if (approval != null && (!sameReaderProgressRevision(approval, book) || book.isNotShelf)) {
            throw RecoverableSharedException("PROGRESS_LOCAL_CHANGED", "本地进度已改变，请重新同步后确认")
        }
        val chapters = observeBookChaptersUseCase(bookUrl).first()
        if (progress.durChapterIndex !in chapters.indices) return null
        val current = requireProgressBook(book)
        val readable = ReadSimulationSchedule.count(current.readConfig, chapters.size)
        if (progress.durChapterIndex !in 0 until readable) return null
        if (current.durChapterIndex == progress.durChapterIndex &&
            current.durChapterPos == progress.durChapterPos
        ) {
            return null
        }
        val chapter = chapters[progress.durChapterIndex]
        val displayTitle = resolveDisplayChapterTitle(current, chapter, applyReplaceRulesUseCase)
        val updatedBook = current.updateReadingProgress(
            chapterIndex = progress.durChapterIndex,
            chapterTitle = displayTitle,
            chapterPos = progress.durChapterPos,
        )
        val requested = ReaderProgressWrite(updatedBook.copy(readConfig = current.readConfig?.copy()), chapter)
        val expected = requireProgressTarget(requested)
        if (approval != null && !sameReaderProgressRevision(approval, expected)) {
            throw RecoverableSharedException("PROGRESS_LOCAL_CHANGED", "本地进度已改变，请重新同步后确认")
        }
        currentCoroutineContext().ensureActive()
        val result = updateReadingProgressUseCase.ifUnchanged(expected, updatedBook)
        val persisted = result.book ?: throw CancellationException("Book was removed before progress was saved")
        if (!result.persisted) throw CancellationException("Reading progress changed before the jump was saved")
        requireSameProgressSource(requested.book, persisted)
        uploadPersistedProgress(persisted)
        return requested.copy(book = persisted.copy(readConfig = persisted.readConfig?.copy()))
    }

    /** Checks identity and readability, deliberately ignoring later explicit progress writes. */
    suspend fun requireProgressTarget(requested: ReaderProgressWrite): Book {
        val chapters = observeBookChaptersUseCase(requested.book.bookUrl).first()
        val latest = requireProgressBook(requested.book)
        val index = requested.book.durChapterIndex
        if (!sameProgressChapter(requested.chapter, chapters.getOrNull(index)) ||
            index !in 0 until ReadSimulationSchedule.count(latest.readConfig, chapters.size)
        ) {
            throw CancellationException("Progress target changed or is no longer readable")
        }
        return latest
    }

    /** Merge fresh metadata with the request anchor without any further progress write. */
    suspend fun resolveRequestedProgress(requested: ReaderProgressWrite, prepared: ReaderChapterPreparation): Book {
        requireSameProgressSource(requested.book, prepared.currentBook)
        val payload = prepared.payload
        requireSameProgressSource(requested.book, payload.book)
        val index = requested.book.durChapterIndex
        if (payload.book.durChapterIndex != index ||
            !sameProgressChapter(requested.chapter, payload.chapter) ||
            !sameProgressChapter(requested.chapter, payload.chapters.getOrNull(index))
        ) {
            throw CancellationException("Prepared chapter does not match the progress target")
        }
        val latest = requireProgressTarget(requested)
        return latest.copy(
            durChapterIndex = index,
            durChapterTitle = payload.displayTitle,
            durChapterPos = requested.book.durChapterPos,
            durChapterTime = requested.book.durChapterTime,
        )
    }

    private suspend fun requireProgressBook(expected: Book): Book {
        val latest = getBookUseCase.get(expected.bookUrl)
            ?: throw CancellationException("Book was removed while applying progress")
        currentCoroutineContext().ensureActive()
        requireSameProgressSource(expected, latest)
        return latest
    }

    private fun requireSameProgressSource(expected: Book, actual: Book) {
        if (actual.bookUrl != expected.bookUrl || actual.origin != expected.origin ||
            actual.tocUrl != expected.tocUrl || actual.config.reverseToc != expected.config.reverseToc
        ) {
            throw CancellationException("Book source or chapter order changed while applying progress")
        }
    }

    private fun sameProgressChapter(expected: BookChapter, actual: BookChapter?): Boolean {
        // BookChapter.equals checks only URL; local offsets and the directory slot also matter.
        return actual != null && actual.url == expected.url && actual.bookUrl == expected.bookUrl &&
            actual.index == expected.index && actual.baseUrl == expected.baseUrl &&
            actual.isVolume == expected.isVolume && actual.start == expected.start && actual.end == expected.end &&
            actual.startFragmentId == expected.startFragmentId && actual.endFragmentId == expected.endFragmentId
    }

    suspend fun syncProgress(bookUrl: String): SyncProgressResult {
        return try {
            val book = getBookUseCase.get(bookUrl) ?: return SyncProgressResult.Error("Book not found")
            val expected = currentCoroutineContext()[ReaderProgressExpectation]?.book
            if (expected != null && !sameReaderProgressIdentity(expected, book)) {
                throw CancellationException("Progress synchronization source changed")
            }
            settingsFacade.syncReaderBookProgress(book)
        } catch (e: kotlin.coroutines.cancellation.CancellationException) {
            throw e
        } catch (e: Throwable) {
            CrashCollector.record("ReaderFacade", "syncProgress", error = e)
            SyncProgressResult.Error(e.message ?: "Unknown sync error")
        }
    }

    /**
     * Persist only when index, title or position differs from the caller's snapshot.
     * Explicit writes are unconditional and touch only progress fields.
     */
    suspend fun persistProgressIfChanged(current: Book, updated: Book) {
        if (current.durChapterIndex == updated.durChapterIndex &&
            current.durChapterTitle == updated.durChapterTitle &&
            current.durChapterPos == updated.durChapterPos
        ) {
            return
        }
        val finalBook = resolveProgressTitle(current, updated)
        val persisted = updateReadingProgressUseCase.persist(
            finalBook.bookUrl,
            finalBook.durChapterIndex,
            finalBook.durChapterTitle,
            finalBook.durChapterPos,
        ) ?: return
        uploadPersistedProgress(persisted)
    }

    /** Returns the requested chapter's display snapshot without overwriting a newer revision. */
    suspend fun persistLoadedProgress(current: Book, updated: Book): Book {
        val finalBook = resolveProgressTitle(current, updated)
        val result = updateReadingProgressUseCase.ifUnchanged(current, finalBook)
        currentCoroutineContext().ensureActive()
        val latest = result.book
        val displayBook = (latest ?: finalBook).copy(
            durChapterIndex = finalBook.durChapterIndex,
            durChapterTitle = finalBook.durChapterTitle,
            durChapterPos = if (latest != null && latest.durChapterIndex == finalBook.durChapterIndex) {
                latest.durChapterPos
            } else {
                0
            },
        )
        if (result.persisted && latest != null) {
            uploadPersistedProgress(latest)
        }
        return displayBook
    }

    private suspend fun resolveProgressTitle(current: Book, updated: Book): Book {
        return if (current.durChapterIndex != updated.durChapterIndex) {
            val chapters = observeBookChaptersUseCase(updated.bookUrl).first()
            val chapter = chapters.getOrNull(updated.durChapterIndex)
            if (chapter != null) {
                val resolvedTitle = resolveDisplayChapterTitle(updated, chapter, applyReplaceRulesUseCase)
                updated.copy(durChapterTitle = resolvedTitle)
            } else {
                updated
            }
        } else {
            updated
        }
    }

    private suspend fun uploadPersistedProgress(book: Book) {
        currentCoroutineContext().ensureActive()
        progressUploads.stage(book)
    }

    fun clearSnapshots() {
        lastBookProgress = null
        webBookProgress = null
    }
}

internal data class ReaderProgressWrite(val book: Book, val chapter: BookChapter)
