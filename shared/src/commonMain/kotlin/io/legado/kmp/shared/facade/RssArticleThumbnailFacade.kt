package io.legado.kmp.shared.facade

import io.legado.kmp.shared.bootstrap.SharedBootstrap
import io.legado.kmp.shared.domain.repository.CookieRepository
import io.legado.kmp.shared.domain.repository.RssSourceRepository
import io.legado.kmp.shared.domain.rss.asBookSourceShim
import io.legado.kmp.shared.domain.rss.rssRuleBaseUrl
import io.legado.kmp.shared.image.ImageDiskCache
import io.legado.kmp.shared.image.ImageRequestGate
import io.legado.kmp.shared.model.RssArticle
import io.legado.kmp.shared.model.RssSource
import io.legado.kmp.shared.network.LegacyJsConnectGateway
import io.legado.kmp.shared.scripting.LegacyImageDecoder
import io.legado.kmp.shared.source.SourceStateStore
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import okio.ByteString.Companion.encodeUtf8
import org.koin.mp.KoinPlatformTools
import kotlin.coroutines.cancellation.CancellationException
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi

data class RssArticleThumbnailResult(
    val imageBase64: String? = null,
    val errorMessage: String? = null,
    val isCancelled: Boolean = false,
) {
    override fun toString(): String = "RssArticleThumbnailResult(redacted)"
}

/** The list and favorites share the source-aware image/cover decoder, without creating book records. */
class RssArticleThumbnailFacade(
    private val sources: RssSourceRepository,
    private val state: SourceStateStore,
    private val cookies: CookieRepository,
    private val gateway: LegacyJsConnectGateway,
    decoder: LegacyImageDecoder,
    private val disk: ImageDiskCache,
) {
    private val bytes = BookImageBytes(gateway, decoder)

    companion object {
        private val loads = Semaphore(4)

        @Throws(RecoverableSharedException::class)
        fun create(): RssArticleThumbnailFacade = try {
            SharedBootstrap.startOrThrow()
            val koin = KoinPlatformTools.defaultContext().get()
            RssArticleThumbnailFacade(koin.get(), koin.get(), koin.get(), koin.get(), koin.get(), koin.get())
        } catch (_: Exception) {
            throw RecoverableSharedException("RssArticleThumbnailFacade.create", "RSS image service unavailable")
        }
    }

    fun loadImage(
        article: RssArticle,
        cacheOnly: Boolean,
        onResult: (RssArticleThumbnailResult) -> Unit,
    ): FlowSubscription = CancellableFacadeRequest.start(
        prepare = { RssArticleThumbnailResult(imageBase64 = loadImageBase64(article, cacheOnly)) },
        cancelledResult = RssArticleThumbnailResult(isCancelled = true),
        failureResult = { RssArticleThumbnailResult(errorMessage = "RSS image unavailable") },
        onResult = onResult,
        facade = "RssArticleThumbnailFacade",
        callbackMethod = "loadImage",
        missingResultMessage = "RSS image result unavailable",
    )

    @OptIn(ExperimentalEncodingApi::class)
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun loadImageBase64(article: RssArticle, cacheOnly: Boolean = false): String? {
        return try {
            val image = article.image?.takeUnless { it.isBlank() } ?: return null
            currentCoroutineContext().ensureActive()
            loads.withPermit {
                val source = sources.getByKey(article.origin)
                val context = cacheContext(article, source, image)
                val folder = "rss-thumbnails-" + article.origin.encodeUtf8().sha256().hex()
                val key = context.storageKey ?: "uncached"
                ImageRequestGate.bookImages.withKey(disk.getImagePath(folder, key)) {
                    currentCoroutineContext().ensureActive()
                    if (context.storageKey != null) {
                        disk.readValidatedImage(folder, key)?.let {
                            currentCoroutineContext().ensureActive()
                            if (cacheContext(article, sources.getByKey(article.origin), image) != context) return@withKey null
                            return@withKey Base64.encode(it)
                        }
                    }
                    if (cacheOnly) return@withKey null
                    val decoded = bytes.fetchAndDecode(
                        src = image,
                        isCover = true,
                        baseUrl = rssRuleBaseUrl(article.link).ifBlank { source?.sourceUrl.orEmpty() },
                        source = source?.asBookSourceShim(),
                    ) ?: return@withKey null
                    currentCoroutineContext().ensureActive()
                    validateCacheImage(decoded)
                    val latestSource = sources.getByKey(article.origin)
                    if (imageConfiguration(source) != imageConfiguration(latestSource)) {
                        return@withKey null
                    }
                    // Response/decoder scripts may update cookies or variables. Keep the original cache partition.
                    val accepted = if (context.storageKey != null) disk.writeValidatedImage(folder, key, decoded) else decoded
                    currentCoroutineContext().ensureActive()
                    Base64.encode(accepted)
                }
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            // URL rules, headers and decoder failures may contain credentials; do not record their raw errors.
            throw RecoverableSharedException("RssArticleThumbnailFacade.image", "RSS image unavailable")
        }
    }

    private data class Context(val configuration: String, val storageKey: String?)

    private suspend fun cacheContext(article: RssArticle, source: RssSource?, image: String): Context {
        val partition = cookies.imageCachePartition()
        val context = listOf(
            "rss-thumbnail-v1", article.origin, article.link, image, article.variable,
            imageConfiguration(source),
            source?.let { state.getSourceVariable(it.sourceUrl) },
            source?.let {
                Json.encodeToString(state.getSourceVariableMap(it.sourceUrl).entries.sortedBy { entry -> entry.key }
                    .associate { entry -> entry.key to entry.value })
            },
            source?.let { state.getLoginHeader(it.sourceUrl) },
            source?.let { state.getLoginInfo(it.sourceUrl) },
            gateway.defaultUserAgent(),
        )
        currentCoroutineContext().ensureActive()
        val configuration = Json.encodeToString(context).encodeUtf8().sha256().hex()
        return Context(configuration, partition?.let {
            Json.encodeToString(listOf(configuration, it)).encodeUtf8().sha256().hex()
        })
    }

    // Presentation does not reach the image transport's BookSource shim; credentials and rules still do.
    private fun imageConfiguration(source: RssSource?): String? =
        source?.let { Json.encodeToString(it.copy(articleStyle = 0)) }
}
