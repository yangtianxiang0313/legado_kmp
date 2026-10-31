package io.legado.kmp.shared.facade

import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.BookProgress

data class ReaderChapterPayload(
    val book: Book,
    val chapters: List<BookChapter>,
    val chapter: BookChapter,
    val content: String,
    val displayTitle: String,
    val blocks: List<ReaderContentBlock>,
    val sameTitleRemoved: Boolean,
) {
    val hasReadableContent: Boolean
        get() = chapter.isVolume || content.isNotBlank() ||
            (book.isLocal && book.isEpub && sameTitleRemoved && displayTitle.isNotBlank() &&
                blocks.any { it.type == ReaderContentBlockType.HEADING && it.text.isNotBlank() })
}

data class ReaderChapterListItem(
    val chapter: BookChapter,
    val displayTitle: String,
    val isCurrent: Boolean,
    val isCached: Boolean,
)

enum class ReaderContentBlockType {
    HEADING,
    PARAGRAPH,
    IMAGE,
    SPACER,
}

data class ReaderContentBlock(
    val blockIndex: Int = 0,
    val type: ReaderContentBlockType,
    val text: String = "",
    val imageUrl: String? = null,
    val imageAlt: String? = null,
    val imageWidth: Int = 0,
    val imageHeight: Int = 0,
)

/**
 * 全文搜索结果。
 * Mirrors legado SearchResult (searchContent package).
 */
data class ContentSearchResult(
    val chapterIndex: Int,
    val chapterTitle: String,
    val matchText: String,
    val query: String,
    val queryIndexInResult: Int,
    val queryIndexInChapter: Int,
) {
    private var searchCoordinates: SearchCoordinates? = null

    val searchTextFingerprint: String?
        get() = searchCoordinates?.fingerprint

    val queryIndexInVisibleText: Int?
        get() = searchCoordinates?.range?.start

    val queryLengthInVisibleText: Int?
        get() = searchCoordinates?.range?.length

    internal fun attachSearchCoordinates(index: ReaderSearchTextIndex): ContentSearchResult {
        if (searchCoordinates == null) {
            val range = index.visibleRange(queryIndexInChapter, query.length)
            searchCoordinates = SearchCoordinates(
                fingerprint = if (range != null) index.fingerprint else null,
                range = range,
            )
        }
        return this
    }

    private class SearchCoordinates(val fingerprint: String?, val range: ReaderSearchVisibleRange?)
}

/**
 * Result of a progress sync operation against WebDAV.
 * Mirrors legado ReadBook.syncProgress() three-way comparison.
 */
sealed class SyncProgressResult {
    /** Server has a newer progress; iOS should confirm before applying. */
    data class ServerAhead(val progress: BookProgress) : SyncProgressResult()
    /** Local progress is ahead; already uploaded to server. */
    object LocalAhead : SyncProgressResult()
    /** Local and server progress are identical. */
    object InSync : SyncProgressResult()
    /** Book progress sync is disabled in settings. */
    object Disabled : SyncProgressResult()
    /** An error occurred during sync. */
    data class Error(val message: String) : SyncProgressResult()
}

/**
 * Result of [ReaderFacade.upData] — reports whether the chapter list changed
 * and the new chapter count after refresh.
 * Mirrors legado ReadBook.upData() semantics.
 */
data class UpDataResult(
    val chaptersChanged: Boolean,
    val newChapterCount: Int,
    val simulatedChapterSize: Int,
)

/**
 * Relative position for content update operations.
 * Mirrors legado ReadBook.textChapter(chapterOnDur) convention.
 */
enum class RelativePosition(val offset: Int) {
    PREV(-1),
    CUR(0),
    NEXT(1),
}

/**
 * Result of a chapter navigation (moveToNext/moveToPrev).
 */
data class ChapterNavigationResult(
    val success: Boolean,
    val payload: ReaderChapterPayload? = null,
)

/**
 * ReadAloud state enum for TTS subsystem.
 * Mirrors legado BaseReadAloudService states.
 */
enum class ReadAloudState {
    IDLE,
    PLAYING,
    PAUSED,
}

/**
 * ReadAloud (TTS) configuration.
 * Aligns with legado ReadAloud engine/speed/pitch settings stored in AppConfig/preferences.
 * Used by Reader's TTS integration (A01-A03, A06).
 */
data class ReadAloudConfig(
    /** TTS engine identifier (null = system default). Aligns with legado AppConfig.ttsEngine. */
    val engine: String? = null,
    /** Speech rate (0-45 scale, default 5). Aligns with legado AppConfig.ttsSpeechRate. */
    val speed: Int = 5,
    /** Whether to follow system speech rate. Aligns with legado AppConfig.ttsFollowSys. */
    val followSystemRate: Boolean = false,
    /** TTS timer minutes (0 = disabled). Aligns with legado ReadAloud timer. */
    val timerMinutes: Int = 0,
    /** Voice identifier (null = system default). */
    val voiceIdentifier: String? = null,
)
