package io.legado.kmp.shared.facade

import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookType
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/** One request owns every byte array; failed lookups are memoized as well as successful ones. */
internal class BookExportImages(
    book: Book,
    private val images: BookImageFacade,
    private val budget: BookExportBudget,
    private val reservedEntries: Int,
    private val checkActive: () -> Unit,
) {
    private val book = if (book.isLocal) book.copy(origin = BookType.LOCAL_TAG) else book
    private val resolved = mutableMapOf<Key, String?>()
    private val resourceList = mutableListOf<EpubResourceEntry>()
    private val zipEntries = mutableListOf<ZipEntryData>()

    val resources: List<EpubResourceEntry> get() = resourceList
    val entries: List<ZipEntryData> get() = zipEntries

    suspend fun bodyPath(source: String): String? = resolve(source, isCover = false)?.let { "../$it" }

    suspend fun cover() {
        val source = book.displayCoverUrl?.trim()?.takeIf { it.isNotEmpty() && it != "use_default_cover" } ?: return
        resolve(source, isCover = true)
    }

    private suspend fun resolve(source: String, isCover: Boolean): String? {
        checkActive()
        val key = Key(source, isCover)
        if (resolved.containsKey(key)) return resolved[key]
        requireBookExport(resolved.size < BookExportLimits.RESOURCES, "图片引用数量超过 20000 项导出限制")
        budget.textBytes(source, if (source.startsWith("data:", true)) {
            BookExportLimits.RESOURCE_BYTES
        } else BookExportLimits.IDENTITY_BYTES)
        val bytes = try {
            images.exportImageBytes(book, source, isCover)
        } catch (error: Exception) {
            currentCoroutineContext().ensureActive()
            findFacadeRequestCancellation(error)?.let { throw it }
            null
        }
        checkActive()
        if (bytes == null || bytes.isEmpty()) {
            resolved[key] = null
            return null
        }
        requireBookExport(bytes.size.toLong() <= BookExportLimits.RESOURCE_BYTES, "单个图片资源超过 32 MiB 导出限制")
        val format = epubImageFormat(bytes)
        if (format == null) {
            resolved[key] = null
            return null
        }
        budget.resourceCount(reservedEntries + zipEntries.size + 1)
        budget.image(bytes)
        val path = "Images/image_${zipEntries.size + 1}.${format.extension}"
        resourceList += EpubResourceEntry(path, format.mediaType, isCover)
        zipEntries += ZipEntryData("OEBPS/$path", bytes)
        resolved[key] = path
        return path
    }

    private data class Key(val source: String, val isCover: Boolean) {
        override fun toString(): String = "BookExportImages.Key(redacted)"
    }
}
