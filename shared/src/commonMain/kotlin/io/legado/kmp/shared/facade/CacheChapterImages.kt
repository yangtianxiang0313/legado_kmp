package io.legado.kmp.shared.facade

import io.legado.kmp.shared.image.ImageDiskCache
import io.legado.kmp.shared.image.ImageRequestGate
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.model.getCacheFolderName
import io.legado.kmp.shared.network.AnalyzeUrl
import io.legado.kmp.shared.network.LegacyJsConnectGateway
import io.legado.kmp.shared.scripting.LegacyImageDecoder
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlin.coroutines.cancellation.CancellationException

/** One image at a time per chapter worker; the batch worker limiter bounds total image traffic. */
class CacheChapterImages(
    private val imageDiskCache: ImageDiskCache,
    private val gateway: LegacyJsConnectGateway,
    private val decoder: LegacyImageDecoder,
) {
    private val requests = ImageRequestGate()
    private val imagePermits = Semaphore(2)

    internal fun changes(book: Book): Flow<Unit> = imageDiskCache.changes
        .filter { it == book.getCacheFolderName() }
        .map { Unit }

    suspend fun save(book: Book, source: BookSource, chapter: BookChapter, content: String) {
        val folder = book.getCacheFolderName()
        val images = imageUrls(chapter, content, allowRawUrls = book.isImage)
        check(!book.isImage || images.isNotEmpty()) { "漫画章节没有可缓存的图片" }
        for (src in images) {
            currentCoroutineContext().ensureActive()
            val storageKey = book.imageCacheIdentity(src)
            imagePermits.withPermit {
                requests.withKey("$folder\n$src") {
                    val existing = imageDiskCache.getImage(folder, storageKey)
                    currentCoroutineContext().ensureActive()
                    if (existing != null && existing.isNotEmpty()) {
                        try {
                            validateCacheImage(existing)
                            return@withKey
                        } catch (cancelled: CancellationException) {
                            throw cancelled
                        } catch (_: Exception) {
                            // A previous failed/partial download is not a cache hit.
                            check(imageDiskCache.deleteImage(folder, storageKey)) { "Failed to remove invalid chapter image: $src" }
                        }
                    }
                    val bytes = download(book, source, chapter, src)
                    currentCoroutineContext().ensureActive()
                    imageDiskCache.writeValidatedImage(folder, storageKey, bytes)
                }
            }
        }
    }

    /** Reconstructed from disk, so another facade or a cold start cannot turn a partial chapter into a hit. */
    internal suspend fun isComplete(book: Book, chapter: BookChapter, content: String): Boolean {
        val folder = book.getCacheFolderName()
        val images = imageUrls(chapter, content, allowRawUrls = book.isImage)
        if (book.isImage && images.isEmpty()) return false
        for (src in images) {
            currentCoroutineContext().ensureActive()
            val bytes = imageDiskCache.getImage(folder, book.imageCacheIdentity(src)) ?: return false
            try {
                validateCacheImage(bytes)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                return false
            }
        }
        return true
    }

    internal fun imageUrls(chapter: BookChapter, content: String, allowRawUrls: Boolean = false): List<String> {
        if (!allowRawUrls && !content.contains("<img", ignoreCase = true)) return emptyList()
        // Reading, prefetch, explicit download and export share identical resource identities.
        return MangaChapterParser.imageSources(chapter, content).distinct()
    }

    private suspend fun download(book: Book, source: BookSource, chapter: BookChapter, src: String): ByteArray {
        val bytes = AnalyzeUrl.getByteArrayIfDataUri(src) ?: run {
            val response = gateway.executeForLegacyJsRaw(
                urlRule = src,
                source = source,
                baseUrl = chapter.getAbsoluteUrl().split(ruleOptions, limit = 2).first(),
                ruleData = book.toImageRuleVariables(),
                chapter = chapter,
            )
            check(response.statusCode in 200..299) { "Image request failed: ${response.statusCode}" }
            response.body
        }
        return checkNotNull(decoder.decode(src, bytes, isCover = false, source = source, book = book)) {
            "Chapter image decode returned no bytes"
        }
    }

    private companion object {
        val ruleOptions = Regex("\\s*,\\s*(?=\\{)")
    }
}

/** Must reject incomplete/corrupt data and force decoding, rather than accepting only dimensions. */
internal expect suspend fun validateCacheImage(bytes: ByteArray)
