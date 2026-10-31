package io.legado.kmp.shared.facade

import io.legado.kmp.shared.analyze.AnalyzeRule
import io.legado.kmp.shared.domain.localbook.EpubBookParser
import io.legado.kmp.shared.domain.localbook.EpubEmbeddedImage
import io.legado.kmp.shared.domain.localbook.LocalBookFileResolver
import io.legado.kmp.shared.domain.localbook.LocalBookSvg
import io.legado.kmp.shared.domain.localbook.MobiBookParser
import io.legado.kmp.shared.domain.usecase.GetBookSourcesUseCase
import io.legado.kmp.shared.domain.usecase.GetBookUseCase
import io.legado.kmp.shared.image.CoverRuleConfig
import io.legado.kmp.shared.image.ImageDiskCache
import io.legado.kmp.shared.image.ImageLruCache
import io.legado.kmp.shared.image.ImageRequestGate
import io.legado.kmp.shared.image.ImageSize
import io.legado.kmp.shared.image.ImageSizeDecoder
import io.legado.kmp.shared.image.renderLocalBookSvg
import io.legado.kmp.shared.preferences.AppPreferencesStore
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.SearchBook
import io.legado.kmp.shared.model.getCacheFolderName
import io.legado.kmp.shared.network.LegacyJsConnectGateway
import io.legado.kmp.shared.scripting.LegacyImageDecoder
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi
import kotlin.coroutines.cancellation.CancellationException

/**
 * Unified image facade covering:
 * - Cover loading with useDefaultCover support and fallback (BC-05)
 * - Manga image loading (BC-06)
 * - Manga preload (BC-07)
 * - Blurred cover loading (BC-08)
 * - CoverRule CRUD (BC-09/10/12/13/14/15)
 * - Cover search via AnalyzeRule (BC-11)
 * - Default cover management (BC-03/04)
 * - Error placeholder (IP-01)
 * - LRU in-memory cache (IP-02/03)
 * - Cache clear (IP-12)
 * - Disk image cache (IP-09)
 * - Image size pre-fetch (IP-10)
 * - Full decode pipeline with cache integration (IP-11)
 */
class BookImageFacade(
    private val getBookUseCase: GetBookUseCase,
    private val getBookSourcesUseCase: GetBookSourcesUseCase,
    private val legacyGateway: LegacyJsConnectGateway,
    private val legacyImageDecoder: LegacyImageDecoder,
    private val imageLruCache: ImageLruCache,
    private val imageDiskCache: ImageDiskCache,
    private val imageSizeDecoder: ImageSizeDecoder,
    private val preferencesStore: AppPreferencesStore? = null,
    private val epubBookParser: EpubBookParser,
    private val localBookFileResolver: LocalBookFileResolver,
    private val mobiBookParser: MobiBookParser,
) {
    private val imageRequests = ImageRequestGate.bookImages
    private val imageBytes = BookImageBytes(legacyGateway, legacyImageDecoder)

    // ==================== BC-03/BC-04: Default cover management ====================

    /**
     * Default cover URL or resource identifier.
     *
     * Mirrors legado BookCover.defaultDrawable: platforms use this to resolve the
     * fallback cover image. When null, platforms should use their built-in default cover resource.
     *
     * Set via [upDefaultCover] or directly by platform code.
     */
    var defaultCoverUrl: String? = null
        private set

    /**
     * Whether to draw book name on the default cover.
     * Mirrors legado BookCover.drawBookName (theme-dependent preference).
     */
    var drawBookName: Boolean = true
        private set

    /**
     * Whether to draw book author on the default cover.
     * Mirrors legado BookCover.drawBookAuthor (theme-dependent preference).
     */
    var drawBookAuthor: Boolean = true
        private set

    /**
     * Refresh default cover configuration.
     *
     * Mirrors legado BookCover.upDefaultCover():
     * - Reads theme-dependent preferences for drawBookName / drawBookAuthor
     * - Reads user-customized default cover path (day/night variants)
     * - Falls back to null (platform uses built-in resource)
     *
     * @param isNightTheme Whether the current theme is dark mode
     * @param coverShowName Whether to show book name on cover (for current theme)
     * @param coverShowAuthor Whether to show author on cover (for current theme)
     * @param customCoverPath User-configured custom default cover path, or null for built-in
     */
    fun upDefaultCover(
        isNightTheme: Boolean = false,
        coverShowName: Boolean = true,
        coverShowAuthor: Boolean = true,
        customCoverPath: String? = null,
    ) {
        drawBookName = coverShowName
        drawBookAuthor = coverShowAuthor
        defaultCoverUrl = customCoverPath?.takeIf { it.isNotBlank() }
    }

    // ==================== IP-01: Error placeholder ====================

    /**
     * Whether the last image load resulted in an error (caller should show error placeholder).
     *
     * In legado, ImageProvider.errorBitmap is a static resource returned on decode failure.
     * In KMP, image decode returns null on failure. This constant signals to platform layers
     * that they should use their platform-specific error placeholder resource.
     */
    companion object {
        /**
         * Sentinel value returned in [BlurredCoverResult.base64Data] when loading fails
         * but the caller needs to distinguish "no cover" from "load error".
         */
        const val ERROR_PLACEHOLDER_SENTINEL = "__error_placeholder__"
    }

    // ==================== BC-05: Cover loading with useDefaultCover + fallback ====================

    /**
     * Load book cover as base64 string.
     *
     * @param bookUrl The book's URL (primary key)
     * @param useDefaultCover If true, skip network loading and return null (caller should show default cover).
     *   Mirrors legado AppConfig.useDefaultCover behavior.
     * @param loadOnlyWifi If true, skip network loading and only return cached covers.
     *   Mirrors legado AppConfig.loadCoverOnlyWifi — when on cellular data,
     *   covers should only be loaded from cache. The platform layer determines
     *   the current network state and passes this parameter.
     * @return Base64-encoded image data, or null if cover is unavailable or useDefaultCover is true.
     */
    @OptIn(ExperimentalEncodingApi::class)
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun loadBookCoverBase64(
        bookUrl: String,
        useDefaultCover: Boolean = false,
        loadOnlyWifi: Boolean = false,
    ): String? {
        if (useDefaultCover) return null
        return runRecoverable("BookImageFacade.loadBookCoverBase64") {
            val book = requireBook(bookUrl)
            val coverUrl = book.displayCoverUrl?.takeIf { it.isNotBlank() } ?: return@runRecoverable null

            loadImageWithCachePipeline(
                book, coverUrl, isCover = true,
                cacheOnly = loadOnlyWifi && !book.isLocalEmbeddedImageBook(),
            )
        }
    }

    /**
     * Load an unpersisted search result's cover as base64 through the existing image pipeline.
     *
     * Converts [candidate] to an in-memory [Book] without writing to the book table.
     * Image disk and LRU caches are still read and updated normally.
     *
     * @return Base64-encoded image data, or null for an unavailable or default cover.
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun loadSearchCoverBase64(candidate: SearchBook): String? {
        return runRecoverable("BookImageFacade.loadSearchCoverBase64") {
            val book = candidate.toBook()
            val coverUrl = book.displayCoverUrl?.takeIf { it.isNotBlank() } ?: return@runRecoverable null
            if (coverUrl.trim() == "use_default_cover") return@runRecoverable null

            loadImageWithCachePipeline(book, coverUrl, isCover = true)
        }
    }

    // ==================== BC-06: Manga image loading ====================

    /**
     * Load a manga/comic image as base64 string.
     *
     * Mirrors legado BookCover.loadManga() semantics:
     * - mangaOption = true (tells loader to use manga-specific settings)
     * - DiskCacheStrategy.ALL equivalent: always cache to disk
     * - skipMemoryCache: manga images bypass LRU memory cache to avoid evicting text content images
     *
     * @param bookUrl The book's URL
     * @param imageUrl The image URL to load
     * @return Base64-encoded image data, or null if unavailable
     */
    @OptIn(ExperimentalEncodingApi::class)
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun loadMangaImageBase64(bookUrl: String, imageUrl: String): String? {
        return runRecoverable("BookImageFacade.loadMangaImageBase64") {
            val book = requireBook(bookUrl)
            loadImageWithCachePipeline(book, imageUrl, isCover = false, useMemoryCache = false)
        }
    }

    /**
     * Load the original through the same source/decoder/integrity pipeline without a Base64 bridge copy.
     * The returned cache path is borrowed, not a lease: callers must handle concurrent cache removal.
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun loadMangaImageFile(bookUrl: String, imageUrl: String, refresh: Boolean = false): String? {
        return runRecoverable("BookImageFacade.loadMangaImageFile") {
            val book = requireBook(bookUrl)
            val src = imageUrl.trim().takeIf { it.isNotEmpty() } ?: return@runRecoverable null
            loadImageBytesWithCachePipeline(book, src, isCover = false, refresh = refresh, useMemoryCache = false)
                ?: return@runRecoverable null
            currentCoroutineContext().ensureActive()
            imageDiskCache.getImagePath(book.getCacheFolderName(), book.imageCacheIdentity(src))
        }
    }

    // ==================== BC-11: Cover search ====================

    /**
     * Search for a book cover URL using configured cover rule.
     *
     * Mirrors legado BookCover.searchCover():
     * - Reads CoverRuleConfig
     * - Uses AnalyzeUrl to fetch the search page
     * - Applies AnalyzeRule to extract cover URL
     *
     * @param bookUrl The book's URL
     * @param coverRuleConfig The cover search rule configuration. If null or disabled, returns null.
     * @return The discovered cover URL, or null if not found / rule disabled
     */
    /**
     * Search for a book cover URL using configured cover rule.
     *
     * Mirrors legado BookCover.searchCover():
     * - Reads CoverRuleConfig
     * - Uses AnalyzeUrl to fetch the search page
     * - Applies AnalyzeRule to extract cover URL using coverRule
     *
     * @param bookUrl The book's URL
     * @param coverRuleConfig The cover search rule configuration. If null or disabled, returns null.
     * @return The discovered cover URL, or null if not found / rule disabled
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun searchCover(bookUrl: String, coverRuleConfig: CoverRuleConfig?): String? {
        if (coverRuleConfig == null || !coverRuleConfig.enable) return null
        if (coverRuleConfig.searchUrl.isBlank() || coverRuleConfig.coverRule.isBlank()) return null
        return runRecoverable("BookImageFacade.searchCover") {
            val book = requireBook(bookUrl)
            // Use legacyGateway to execute the search URL with book name as keyword
            val source = buildCoverSearchSource(coverRuleConfig)
            val response = legacyGateway.executeForLegacyJs(
                urlRule = coverRuleConfig.searchUrl,
                source = source,
                baseUrl = coverRuleConfig.searchUrl,
                ruleData = book.toImageRuleVariables()
            )
            val bodyText = response.bodyText.trim()
            if (bodyText.isBlank()) return@runRecoverable null

            AnalyzeRule(source = source, connectGateway = legacyGateway)
                .setBookContext(book)
                .setContent(bodyText, response.url)
                .setRedirectUrl(response.url)
                .getString(coverRuleConfig.coverRule, isUrl = true)
                .trim().takeIf { it.isNotBlank() }

        }
    }

    // ==================== BC-07: Manga preload ====================

    /**
     * Batch preload manga images to disk cache.
     *
     * Mirrors legado BookCover.preloadManga() which uses Glide downloadOnly().
     * Downloads images concurrently and writes them to disk cache so that
     * subsequent [loadMangaImageBase64] calls are instant.
     *
     * @param bookUrl The book's URL
     * @param imageUrls List of image URLs to preload
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun preloadMangaImages(bookUrl: String, imageUrls: List<String>) {
        runRecoverable("BookImageFacade.preloadMangaImages") {
            val book = requireBook(bookUrl)
            coroutineScope {
                for (url in imageUrls.distinct()) {
                    val normalizedUrl = url.trim()
                    if (normalizedUrl.isEmpty()) continue
                    launch {
                        loadImageBytesWithCachePipeline(book, normalizedUrl, isCover = false, useMemoryCache = false)
                    }
                }
            }
        }
    }

    // ==================== BC-08: Blurred cover ====================

    /**
     * Result of a blurred cover load request.
     *
     * @param base64Data Base64-encoded image data (the original cover, not blurred).
     *   Null if no cover is available.
     * @param blurRadius Recommended Gaussian blur radius for platform-side processing.
     *   Mirrors legado BlurTransformation(25).
     * @param shouldBlur Whether the platform should apply blur. Always true for this method.
     */
    data class BlurredCoverResult(
        val base64Data: String?,
        val blurRadius: Int = DEFAULT_BLUR_RADIUS,
        val shouldBlur: Boolean = true,
    ) {
        companion object {
            const val DEFAULT_BLUR_RADIUS = 25
        }
    }

    /**
     * Load a cover image with blur metadata for platform-side Gaussian blur processing.
     *
     * Mirrors legado BookCover.loadBlur():
     * - BlurTransformation(25) + CenterCrop
     * - crossFade(1500ms) transition (platform responsibility)
     * - thumbnail = blurred default cover (platform responsibility)
     *
     * Since Gaussian blur is inherently platform-specific (CoreImage on iOS, RenderScript on Android),
     * this method returns the raw cover data with blur parameters. The platform layer applies the
     * actual blur transformation.
     *
     * @param bookUrl The book's URL
     * @param useDefaultCover If true, returns null data (platform should blur its default cover)
     * @return BlurredCoverResult with cover data and blur parameters
     */
    @OptIn(ExperimentalEncodingApi::class)
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun loadBlurredCover(bookUrl: String, useDefaultCover: Boolean = false): BlurredCoverResult {
        if (useDefaultCover) {
            return BlurredCoverResult(base64Data = null)
        }
        return runRecoverable("BookImageFacade.loadBlurredCover") {
            val coverBase64 = loadBookCoverBase64(bookUrl, useDefaultCover = false)
            BlurredCoverResult(base64Data = coverBase64)
        }
    }

    // ==================== BC-09/10/12/13/14: CoverRule CRUD ====================

    /**
     * In-memory cover rule config store.
     * Mirrors legado BookCover's CacheManager-backed storage.
     * Platform layers can persist this via their own key-value storage on app lifecycle events.
     */
    private var coverRuleConfigCache: CoverRuleConfig? = null

    /** Default cover rule used when no user config is saved. Mirrors legado DefaultData.coverRule. */
    private val defaultCoverRule = CoverRuleConfig(
        enable = false,
        searchUrl = "",
        coverRule = "",
    )

    /**
     * Get the active cover search rule.
     * Falls back to [defaultCoverRule] if no user config is saved.
     * Mirrors legado BookCover.getCoverRule().
     */
    fun getCoverRule(): CoverRuleConfig {
        return getCoverRuleConfig() ?: defaultCoverRule
    }

    /**
     * Get the user-saved cover rule config, or null if none is saved.
     * Mirrors legado BookCover.getConfig().
     */
    fun getCoverRuleConfig(): CoverRuleConfig? {
        if (preferencesStore == null) return coverRuleConfigCache
        val raw = preferencesStore.getBackupConfigJson("android.coverRule.json")
            ?: preferencesStore.getBackupConfigJson("android.coverConfig.json") ?: return null
        return runCatching { coverRuleJson.decodeFromString<CoverRuleConfig>(raw) }.getOrNull()
    }

    private val coverRuleJson = Json { ignoreUnknownKeys = true; coerceInputValues = true }

    /**
     * Save a cover rule configuration.
     * Mirrors legado BookCover.saveCoverRule(config).
     */
    fun saveCoverRule(config: CoverRuleConfig) {
        coverRuleConfigCache = config
        preferencesStore?.setBackupConfigJson("android.coverRule.json", coverRuleJson.encodeToString(config))
    }

    /**
     * Save a cover rule configuration from JSON string.
     * Mirrors legado BookCover.saveCoverRule(json).
     */
    fun saveCoverRuleFromJson(json: String) {
        val config = runCatching {
            coverRuleJson.decodeFromString<CoverRuleConfig>(json)
        }.getOrNull() ?: return
        coverRuleConfigCache = config
        preferencesStore?.setBackupConfigJson("android.coverRule.json", json)
    }

    /**
     * Export the current cover rule config as JSON.
     * Returns null if no config is saved.
     */
    fun exportCoverRuleJson(): String? {
        val config = getCoverRuleConfig() ?: return null
        return Json.encodeToString(config)
    }

    /**
     * Delete the saved cover rule configuration.
     * Mirrors legado BookCover.delCoverRule().
     */
    fun deleteCoverRule() {
        coverRuleConfigCache = null
        preferencesStore?.setBackupConfigJson("android.coverRule.json", null)
        preferencesStore?.setBackupConfigJson("android.coverConfig.json", null)
    }

    // ==================== IP-02/03: LRU memory cache access ====================

    /**
     * Get the shared image LRU cache instance for direct access.
     * Primarily for platform layers that need to manage cache lifecycle.
     */
    fun getImageLruCache(): ImageLruCache = imageLruCache

    /**
     * Clear the in-memory LRU image cache.
     * Mirrors legado ImageProvider.clear().
     */
    suspend fun clearMemoryCache() {
        try {
            imageLruCache.evictAll()
        } catch (e: kotlin.coroutines.cancellation.CancellationException) {
            throw e
        } catch (e: Throwable) {
            CrashCollector.record("BookImageFacade", "clearMemoryCache", error = e)
        }
    }

    /**
     * Non-suspend variant for cleanup / shutdown contexts.
     */
    fun clearMemoryCacheSync() {
        imageLruCache.evictAllSync()
    }

    // ==================== IP-09: Disk cache access ====================

    /**
     * Check if an image is cached on disk.
     */
    suspend fun isImageCached(bookUrl: String, src: String): Boolean {
        return try {
            val book = getBookUseCase.get(bookUrl) ?: return false
            val normalizedUrl = src.trim().takeIf { it.isNotEmpty() } ?: return false
            val folder = book.getCacheFolderName()
            val storageKey = book.imageCacheIdentity(normalizedUrl)
            val key = imageDiskCache.getImagePath(folder, storageKey)
            imageRequests.withKey(key) {
                imageDiskCache.readValidatedImage(folder, storageKey) != null
            }
        } catch (e: kotlin.coroutines.cancellation.CancellationException) {
            throw e
        } catch (e: Throwable) {
            CrashCollector.record("BookImageFacade", "isImageCached", mapOf("bookUrl" to bookUrl), e)
            false
        }
    }

    /**
     * Cache an image to disk (download if not already cached).
     *
     * @return true if the image is now cached on disk
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun cacheImageToDisk(bookUrl: String, src: String): Boolean {
        return runRecoverable("BookImageFacade.cacheImageToDisk") {
            val book = requireBook(bookUrl)
            loadImageBytesWithCachePipeline(book, src, isCover = false, useMemoryCache = false) != null
        }
    }

    // ==================== IP-10: Image size pre-fetch ====================

    /**
     * Get image dimensions without fully decoding the image.
     *
     * Mirrors legado ImageProvider.getImageSize():
     * - First ensures the image is disk-cached
     * - Then reads dimensions via platform decoder (BitmapFactory.Options / CGImageSource)
     * - Falls back to SVG parsing if bitmap decoding returns zero dimensions
     *
     * @param bookUrl The book's URL
     * @param src The image source URL
     * @return ImageSize with width and height, or null if decoding fails
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun getImageSize(bookUrl: String, src: String): ImageSize? {
        return runRecoverable("BookImageFacade.getImageSize") {
            val book = requireBook(bookUrl)
            val bytes = loadImageBytesWithCachePipeline(book, src, isCover = false, useMemoryCache = false)
                ?: return@runRecoverable null
            imageSizeDecoder.decodeSize(bytes)?.takeIf { it.width > 0 && it.height > 0 }
        }
    }

    // ==================== IP-11: Full decode pipeline with LRU cache ====================

    /**
     * Load a book image as base64 with full decode pipeline.
     *
     * Mirrors legado ImageProvider.getImage() pipeline:
     * 1. Check LRU memory cache → hit → return
     * 2. Check disk cache → miss → fetch from network + decode via JS
     * 3. Write to disk cache
     * 4. Put result into LRU memory cache
     * 5. Return base64-encoded data
     *
     * @param bookUrl The book's URL
     * @param imageUrl The image URL
     * @param isCover Whether this is a cover image (affects JS decode rule selection)
     * @return Base64-encoded image data, or null if loading fails
     */
    @OptIn(ExperimentalEncodingApi::class)
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun loadBookImageBase64(bookUrl: String, imageUrl: String, isCover: Boolean): String? {
        return runRecoverable("BookImageFacade.loadBookImageBase64") {
            val book = requireBook(bookUrl)
            loadImageWithCachePipeline(book, imageUrl, isCover)
        }
    }

    /** Reload only the selected image through the original source headers and decoder. */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun refreshBookImageBase64(bookUrl: String, imageUrl: String, isCover: Boolean): String? {
        return runRecoverable("BookImageFacade.refreshBookImageBase64") {
            val book = requireBook(bookUrl)
            loadImageWithCachePipeline(book, imageUrl, isCover, refresh = true)
        }
    }

    /** Export never downloads a missing image or recovers a missing local book from a remote URL. */
    internal suspend fun exportImageBytes(book: Book, src: String, isCover: Boolean): ByteArray? {
        currentCoroutineContext().ensureActive()
        val source = src.trim()
        if (source == "use_default_cover") return null
        try {
            if (source.startsWith("data:", ignoreCase = true)) {
                val context = currentCoroutineContext()
                val bytes = EpubEmbeddedImage.prepareDataImage(source) { context.ensureActive() }
                val rendered = renderLocalImage(bytes) ?: return null
                if (epubImageFormat(rendered) == null) return null
                validateCacheImage(rendered)
                context.ensureActive()
                return rendered
            }
            if (source.isNotEmpty()) {
                val cached = loadImageBytesWithCachePipeline(book, source, isCover, cacheOnly = true)
                if (cached != null) return cached.takeIf { epubImageFormat(it) != null }
            }
            if (!book.isLocal) return null
            // Do not call fetchAndDecodeImage here: its resolver can perform remote recovery.
            // The actual parsers read this exact book path and retain their existing SVG preparation.
            val bytes = when {
                book.isLocalEpubImageBook() -> {
                    val reference = source.ifEmpty {
                        if (isCover) epubBookParser.parse(book).book.displayCoverUrl.orEmpty() else ""
                    }
                    if (reference.isEmpty()) null else epubBookParser.readImage(book, reference)
                }
                book.isLocalMobiImageBook() -> {
                    val reference = source.ifEmpty {
                        if (isCover) mobiBookParser.parse(book).book.displayCoverUrl.orEmpty() else ""
                    }
                    if (reference.isEmpty()) null else mobiBookParser.readImage(book, reference)
                }
                // UMD's cover is not part of this facade's existing image pipeline.
                else -> null
            }
            val rendered = renderLocalImage(bytes) ?: return null
            currentCoroutineContext().ensureActive()
            if (epubImageFormat(rendered) == null) return null
            val size = imageSizeDecoder.decodeSize(rendered) ?: return null
            if (size.width <= 0 || size.height <= 0) return null
            validateCacheImage(rendered)
            currentCoroutineContext().ensureActive()
            return rendered
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            currentCoroutineContext().ensureActive()
            return null
        }
    }

    // ==================== Internal pipeline ====================

    @OptIn(ExperimentalEncodingApi::class)
    private suspend fun loadImageWithCachePipeline(
        book: Book,
        imageUrl: String,
        isCover: Boolean,
        refresh: Boolean = false,
        cacheOnly: Boolean = false,
        useMemoryCache: Boolean = true,
    ): String? = loadImageBytesWithCachePipeline(book, imageUrl, isCover, refresh, cacheOnly, useMemoryCache)
        ?.let { Base64.encode(it) }

    private suspend fun loadImageBytesWithCachePipeline(
        book: Book,
        imageUrl: String,
        isCover: Boolean,
        refresh: Boolean = false,
        cacheOnly: Boolean = false,
        useMemoryCache: Boolean = true,
    ): ByteArray? {
        currentCoroutineContext().ensureActive()
        val normalizedUrl = imageUrl.trim()
        if (normalizedUrl.isEmpty()) return null

        val bookFolder = book.getCacheFolderName()
        val storageKey = book.imageCacheIdentity(normalizedUrl)
        // Cache key for LRU: use disk file path to match legado's approach
        // (legado uses vFile.absolutePath as LRU key)
        val lruKey = imageDiskCache.getImagePath(bookFolder, storageKey)

        return imageRequests.withKey(lruKey) {
            if (!refresh) {
                if (useMemoryCache) {
                    val memoryCached = imageLruCache.get(lruKey)
                    if (memoryCached != null) {
                        try {
                            validateCacheImage(memoryCached)
                            return@withKey memoryCached
                        } catch (cancelled: CancellationException) {
                            throw cancelled
                        } catch (_: Exception) {
                            imageLruCache.remove(lruKey)
                        }
                    }
                }

                val diskCached = imageDiskCache.readValidatedImage(bookFolder, storageKey)
                if (diskCached != null) {
                    if (useMemoryCache) imageLruCache.put(lruKey, diskCached)
                    return@withKey diskCached
                }
            }
            if (cacheOnly) return@withKey null

            // A failed refresh keeps the previous usable image; success replaces only this key.
            val decoded = fetchAndDecodeImage(book, normalizedUrl, isCover) ?: return@withKey null
            currentCoroutineContext().ensureActive()
            val persisted = imageDiskCache.writeValidatedImage(bookFolder, storageKey, decoded)
            if (useMemoryCache) imageLruCache.put(lruKey, persisted)
            persisted
        }
    }

    /** Keeps local-book rendering separate from shared network/embedded byte acquisition. */
    private suspend fun fetchAndDecodeImage(
        book: Book,
        imageUrl: String,
        isCover: Boolean,
    ): ByteArray? {
        if (book.isLocalEpubImageBook()) {
            return renderLocalImage(epubBookParser.readImage(localBookFileResolver.resolve(book), imageUrl))
        }
        if (book.isLocalMobiImageBook()) {
            return renderLocalImage(mobiBookParser.readImage(localBookFileResolver.resolve(book), imageUrl))
        }
        val source = getBookSourcesUseCase.getByUrl(book.origin)
        return imageBytes.fetchAndDecode(
            src = imageUrl,
            isCover = isCover,
            baseUrl = book.bookUrl.ifBlank { source?.bookSourceUrl.orEmpty() },
            source = source,
            book = book,
        )
    }

    private suspend fun renderLocalImage(bytes: ByteArray?): ByteArray? {
        if (bytes == null) return null
        currentCoroutineContext().ensureActive()
        return if (LocalBookSvg.isSvg(bytes)) renderLocalBookSvg(bytes) else bytes
    }

    private suspend fun requireBook(bookUrl: String): Book {
        return getBookUseCase.get(bookUrl) ?: error("Book not found: $bookUrl")
    }

    /**
     * Build a minimal BookSource-like object for cover search rule.
     * The cover rule config acts as a source with minimal fields.
     */
    private fun buildCoverSearchSource(config: CoverRuleConfig): io.legado.kmp.shared.model.BookSource {
        return io.legado.kmp.shared.model.BookSource(
            bookSourceUrl = config.searchUrl,
            bookSourceName = "CoverSearch",
            enabledExplore = false,
            enabledCookieJar = config.enabledCookieJar ?: false,
            concurrentRate = config.concurrentRate,
            header = config.header,
            loginUrl = config.loginUrl,
            loginUi = config.loginUi,
            jsLib = config.jsLib,
        )
    }
}

private fun Book.isLocalEpubImageBook(): Boolean = isLocal &&
    (isEpub || bookUrl.substringBefore('?').substringBefore('#').endsWith(".epub", true))

private fun Book.isLocalMobiImageBook(): Boolean = isLocal &&
    bookUrl.substringBefore('?').substringBefore('#').substringAfterLast('.').lowercase() in setOf("mobi", "azw", "azw3")

private fun Book.isLocalEmbeddedImageBook(): Boolean = isLocalEpubImageBook() || isLocalMobiImageBook()

// Old local SVG entries may be valid JPEGs that silently dropped all vector overlays.
// Keep those files intact, but never mistake them for a complete rendered local image.
internal fun Book.imageCacheIdentity(src: String): String =
    if (isLocalEmbeddedImageBook()) "local-image-render-v2:$src" else src
