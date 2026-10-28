package io.legado.kmp.shared.model

/**
 * Base interface for manga pages.
 * Mirrors legado BaseMangaPage interface.
 */
interface BaseMangaPage {
    val chapterIndex: Int
    val index: Int
}

/**
 * A single manga image page.
 * Mirrors legado MangaPage data class.
 *
 * @param chapterIndex the chapter's absolute index in the book
 * @param chapterSize total number of chapters in the book
 * @param mImageUrl the resolved image URL for this page
 * @param index the page index within the chapter (0-based, among images only)
 * @param imageCount total image count in the chapter (set after all pages collected)
 * @param mChapterName display title of the chapter
 */
data class MangaPage(
    override val chapterIndex: Int = 0,
    val chapterSize: Int = 0,
    val mImageUrl: String = "",
    override val index: Int = 0,
    var imageCount: Int = 0,
    val mChapterName: String = "",
) : BaseMangaPage

/**
 * A title/loading/end marker page in the manga reader.
 * Mirrors legado ReaderLoading data class.
 *
 * @param chapterIndex the chapter index
 * @param index -1 for title pages, imageCount for end pages
 * @param mMessage the display message (e.g. "阅读 <title>" or "已读完 <title>")
 * @param isVolume true if this is a volume-only page (no images)
 */
data class ReaderLoading(
    override val chapterIndex: Int = 0,
    override val index: Int = 0,
    val mMessage: String? = null,
    val isVolume: Boolean = false,
) : BaseMangaPage

/**
 * A parsed manga chapter containing all pages (title + images + end marker).
 * Mirrors legado MangaChapter data class.
 *
 * @param chapter the source BookChapter entity
 * @param pages ordered list of all pages (ReaderLoading + MangaPage entries)
 * @param imageCount number of actual image pages (excludes title/end markers)
 */
data class MangaChapter(
    val chapter: BookChapter,
    val pages: List<BaseMangaPage>,
    val imageCount: Int,
)

/**
 * Aggregated manga content combining prev/cur/next chapters with position offset.
 * Mirrors legado MangaContent data class.
 *
 * @param pos the absolute scroll position (offset into items for current reading position)
 * @param items flat list of all pages across the three-chapter window
 * @param curFinish true if current chapter is loaded
 * @param nextFinish true if next chapter is loaded
 */
data class MangaContent(
    val pos: Int,
    val items: List<BaseMangaPage>,
    val curFinish: Boolean,
    val nextFinish: Boolean,
)
