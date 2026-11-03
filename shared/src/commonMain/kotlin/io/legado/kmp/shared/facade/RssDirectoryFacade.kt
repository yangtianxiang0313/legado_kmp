package io.legado.kmp.shared.facade

import io.legado.kmp.shared.bootstrap.SharedBootstrap
import io.legado.kmp.shared.domain.repository.CacheRepository
import io.legado.kmp.shared.domain.repository.CookieRepository
import io.legado.kmp.shared.domain.repository.RssArticleRepository
import io.legado.kmp.shared.domain.repository.RssSourceRepository
import io.legado.kmp.shared.domain.rss.rssDirectoryCachePrefix
import io.legado.kmp.shared.domain.usecase.FetchRssArticlesUseCase
import io.legado.kmp.shared.domain.usecase.GetRssReadRecordsUseCase
import io.legado.kmp.shared.domain.usecase.MarkRssArticleReadUseCase
import io.legado.kmp.shared.model.RssArticle
import io.legado.kmp.shared.model.RssReadRecord
import io.legado.kmp.shared.model.RssSource
import io.legado.kmp.shared.network.LegacyJsConnectGateway
import io.legado.kmp.shared.source.SourceStateStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.koin.mp.KoinPlatformTools
import kotlin.coroutines.cancellation.CancellationException

data class RssDirectoryResult(
    val articles: List<RssArticle>,
    val nextPageUrl: String?,
    val cacheRetained: Boolean,
) {
    override fun toString(): String = "RssDirectoryResult(redacted)"
}

class RssDirectoryFacade(
    private val sources: RssSourceRepository,
    cache: CacheRepository,
    state: SourceStateStore,
    cookies: CookieRepository,
    gateway: LegacyJsConnectGateway,
    private val fetchRssArticles: FetchRssArticlesUseCase,
    private val markRssArticleRead: MarkRssArticleReadUseCase,
    private val getRssReadRecords: GetRssReadRecordsUseCase,
    private val articleRepository: RssArticleRepository,
) {
    private val directories = RssDirectoryCacheSupport(cache, state, cookies, gateway)

    companion object {
        private const val MAX_ACTIVE_DIRECTORIES = 256
        private val publication = Mutex()
        private val activeGenerations = linkedMapOf<String, Any>()

        @Throws(RecoverableSharedException::class, CancellationException::class)
        fun create(): RssDirectoryFacade = try {
            SharedBootstrap.startOrThrow()
            val koin = KoinPlatformTools.defaultContext().get()
            RssDirectoryFacade(
                koin.get(), koin.get(), koin.get(), koin.get(),
                koin.get(), koin.get(), koin.get(), koin.get(),
                koin.get(),
            )
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            throw RecoverableSharedException("RssDirectoryFacade.create", "RSS directory service unavailable")
        }

        fun cacheKeyPrefix(sourceUrl: String): String = rssDirectoryCachePrefix(sourceUrl)

        private suspend fun beginGeneration(key: String): Any = publication.withLock {
            currentCoroutineContext().ensureActive()
            activeGenerations.remove(key)
            if (activeGenerations.size >= MAX_ACTIVE_DIRECTORIES) {
                activeGenerations.remove(activeGenerations.keys.first())
            }
            Any().also { activeGenerations[key] = it }
        }

        private suspend fun finishGeneration(key: String, generation: Any) {
            withContext(NonCancellable) {
                publication.withLock {
                    if (activeGenerations[key] === generation) activeGenerations.remove(key)
                }
            }
        }
    }

    /** Read the retained directory once, using the original category URL rather than a next-page rule. */
    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun cachedArticles(source: RssSource, sortName: String, sortUrl: String): List<RssArticle> =
        directoryOperation("cachedArticles") {
            publication.withLock {
                currentCoroutineContext().ensureActive()
                if (!configurationMatches(source)) return@withLock emptyList()
                val fingerprint = directories.fingerprint(source, sortName, sortUrl)
                    ?: return@withLock emptyList()
                val key = rssDirectoryCacheKey(source.sourceUrl, sortName, sortUrl)
                val articles = directories.cached(key, fingerprint)
                if (articles.isEmpty()) return@withLock emptyList()
                if (articles.any { it.origin != source.sourceUrl || it.sort != sortName }) {
                    return@withLock emptyList()
                }
                val readArticles = overlayReadRecords(articles)
                if (fingerprint != directories.fingerprint(source, sortName, sortUrl) ||
                    !configurationMatches(source)
                ) return@withLock emptyList()
                readArticles
            }
        }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun loadArticles(
        source: RssSource,
        sortName: String,
        sortUrl: String,
        categoryUrl: String,
        page: Int,
    ): RssDirectoryResult = directoryOperation("loadArticles") {
        require(page >= 1) { "Invalid RSS directory page" }
        val key = rssDirectoryCacheKey(source.sourceUrl, sortName, categoryUrl)
        val generation = beginGeneration(key)
        try {
            requireCurrentConfiguration(source)
            val captured = directories.capture(key, source, sortName, categoryUrl)
            currentCoroutineContext().ensureActive()
            // sortUrl is the caller's actual page rule; categoryUrl is only the original cache identity.
            val (articles, nextPageUrl) = fetchRssArticles(sortName, sortUrl, source, page).getOrThrow()
            require(articles.all { it.origin == source.sourceUrl && it.sort == sortName })
            currentCoroutineContext().ensureActive()
            publication.withLock {
                if (activeGenerations[key] !== generation) {
                    throw CancellationException("RSS directory request superseded")
                }
                requireCurrentConfiguration(source)
                // Store raw rows, never a historical read overlay.
                // Response scripts may change cookies/variables; retain only in the original partition.
                val retained = directories.retain(captured, page, articles, source.ruleNextPage.isNullOrEmpty())
                val readArticles = overlayReadRecords(retained.articles)
                requireCurrentConfiguration(source)
                currentCoroutineContext().ensureActive()
                RssDirectoryResult(readArticles, nextPageUrl, retained.cacheRetained)
            }
        } finally {
            finishGeneration(key, generation)
        }
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun clearArticles(source: RssSource): Unit = directoryOperation("clearArticles") {
        publication.withLock {
            currentCoroutineContext().ensureActive()
            requireCurrentConfiguration(source)
            val prefix = rssDirectoryCachePrefix(source.sourceUrl)
            // Invalidate every category before deleting, including requests that captured no cache row.
            activeGenerations.keys.removeAll { it.startsWith(prefix) }
            articleRepository.delete(source.sourceUrl)
            currentCoroutineContext().ensureActive()
        }
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun readRecords(): List<RssReadRecord> = directoryOperation("readRecords") {
        getRssReadRecords()
    }

    fun watchReadRecords(onUpdate: (List<RssReadRecord>) -> Unit): FlowSubscription =
        watchFlow(getRssReadRecords.observe(), onUpdate, label = "RssDirectoryFacade.readRecords")

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun markRead(article: RssArticle): Unit = directoryOperation("markRead") {
        markRssArticleRead(article)
        currentCoroutineContext().ensureActive()
    }

    private suspend fun overlayReadRecords(articles: List<RssArticle>): List<RssArticle> {
        currentCoroutineContext().ensureActive()
        val readLinks = getRssReadRecords().filter { it.read }.map { it.record }.toSet()
        currentCoroutineContext().ensureActive()
        return articles.map { it.copy(read = it.link in readLinks) }
    }

    private suspend fun configurationMatches(source: RssSource): Boolean {
        currentCoroutineContext().ensureActive()
        val current = sources.getByKey(source.sourceUrl) ?: return false
        return rssDirectorySourceConfiguration(source) == rssDirectorySourceConfiguration(current)
    }

    private suspend fun requireCurrentConfiguration(source: RssSource) {
        if (!configurationMatches(source)) throw SourceChanged()
    }

    private class SourceChanged : Exception()

    private suspend fun <T> directoryOperation(method: String, block: suspend () -> T): T {
        return try {
            withContext(Dispatchers.Default) {
                currentCoroutineContext().ensureActive()
                val result = block()
                currentCoroutineContext().ensureActive()
                result
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: SourceChanged) {
            throw RecoverableSharedException("RssDirectoryFacade.sourceChanged", "RSS source configuration changed")
        } catch (_: Exception) {
            // Rules, request URLs and source state may carry secrets; never retain their raw failures.
            throw RecoverableSharedException("RssDirectoryFacade.$method", "RSS directory unavailable")
        }
    }
}
