package io.legado.kmp.shared.facade

import io.legado.kmp.shared.domain.repository.CacheRepository
import io.legado.kmp.shared.domain.repository.CookieRepository
import io.legado.kmp.shared.domain.rss.rssDirectoryCachePrefix
import io.legado.kmp.shared.model.Cache
import io.legado.kmp.shared.model.RssArticle
import io.legado.kmp.shared.model.RssSource
import io.legado.kmp.shared.network.LegacyJsConnectGateway
import io.legado.kmp.shared.source.SourceStateStore
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import okio.ByteString.Companion.encodeUtf8
import kotlin.coroutines.cancellation.CancellationException

internal fun rssDirectoryCacheKey(sourceUrl: String, sortName: String, categoryUrl: String): String =
    rssDirectoryCachePrefix(sourceUrl) +
        Json.encodeToString(listOf(sortName, categoryUrl)).encodeUtf8().sha256().hex()

internal fun rssDirectorySourceConfiguration(source: RssSource): String =
    Json.encodeToString(source.copy(articleStyle = 0))

internal class RssDirectoryCacheSupport(
    private val repository: CacheRepository,
    private val state: SourceStateStore,
    private val cookies: CookieRepository,
    private val gateway: LegacyJsConnectGateway,
) {
    internal class Captured(
        val key: String,
        val fingerprint: String,
        val previous: Cache?,
        val origin: String,
        val sortName: String,
    ) {
        override fun toString(): String = "RssDirectoryCacheContext(redacted)"
    }

    @Serializable
    private data class Snapshot(
        val fingerprint: String,
        val lastPage: Int,
        val articles: List<RssArticle>,
    ) {
        override fun toString(): String = "RssDirectorySnapshot(redacted)"
    }

    suspend fun fingerprint(source: RssSource, sortName: String, categoryUrl: String): String? {
        currentCoroutineContext().ensureActive()
        val partition = cookies.imageCachePartition() ?: return null
        val context = listOf(
            "rss-directory-v1", source.sourceUrl, sortName, categoryUrl,
            rssDirectorySourceConfiguration(source),
            state.getSourceVariable(source.sourceUrl),
            Json.encodeToString(
                state.getSourceVariableMap(source.sourceUrl).entries.sortedBy { it.key }
                    .associate { it.key to it.value }
            ),
            state.getLoginHeader(source.sourceUrl),
            state.getLoginInfo(source.sourceUrl),
            gateway.defaultUserAgent(),
        )
        currentCoroutineContext().ensureActive()
        val configuration = Json.encodeToString(context).encodeUtf8().sha256().hex()
        return Json.encodeToString(listOf(configuration, partition)).encodeUtf8().sha256().hex()
    }

    suspend fun capture(
        key: String,
        source: RssSource,
        sortName: String,
        categoryUrl: String,
    ): Captured? {
        return try {
            val fingerprint = fingerprint(source, sortName, categoryUrl) ?: return null
            currentCoroutineContext().ensureActive()
            Captured(key, fingerprint, repository.get(key), source.sourceUrl, sortName)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            // Cache/state storage is optional for an otherwise successful online request.
            null
        }
    }

    suspend fun cached(key: String, fingerprint: String): List<RssArticle> {
        currentCoroutineContext().ensureActive()
        return decode(repository.get(key), fingerprint)?.articles.orEmpty()
    }

    suspend fun retain(captured: Captured?, page: Int, articles: List<RssArticle>): Boolean {
        if (captured == null) return false
        return try {
            currentCoroutineContext().ensureActive()
            val previous = captured.previous
            val existing = if (page == 1) null else decode(previous, captured.fingerprint)?.takeIf { snapshot ->
                snapshot.articles.all { it.origin == captured.origin && it.sort == captured.sortName }
            }
            // Never advertise a later page without the complete, contiguous prefix starting at page 1.
            if (page > 1 && (existing == null || existing.lastPage != page - 1)) return false
            val merged = (existing?.articles.orEmpty() + articles).distinctBy { it.origin to it.link }
            val value = Json.encodeToString(Snapshot(captured.fingerprint, page, merged))
            currentCoroutineContext().ensureActive()
            when {
                previous == null -> repository.insertIfAbsent(Cache(captured.key, value, 0L))
                previous.deadline != 0L -> false
                else -> repository.replaceValueIfUnchanged(previous, value)
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            false
        }
    }

    private fun decode(cache: Cache?, fingerprint: String): Snapshot? {
        if (cache == null || cache.deadline != 0L) return null
        val value = cache.value ?: return null
        return try {
            Json.decodeFromString<Snapshot>(value)
                .takeIf { it.fingerprint == fingerprint && it.lastPage >= 1 }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            null
        }
    }
}
