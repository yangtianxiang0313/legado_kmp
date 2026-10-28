package io.legado.kmp.shared.domain.rss

import io.legado.kmp.shared.domain.repository.CacheRepository
import io.legado.kmp.shared.model.Cache
import io.legado.kmp.shared.model.RssSource
import io.legado.kmp.shared.source.SourceStateStore
import io.legado.kmp.shared.util.md5Hex
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

internal class RssSortCache(
    private val sourceStateStore: SourceStateStore,
    private val cacheRepository: CacheRepository?
) {
    private val guard = Mutex()
    private val entries = linkedMapOf<String, Entry>()
    private val loaders = mutableMapOf<String, Loader>()

    suspend fun getOrLoad(
        source: RssSource,
        sortRule: String,
        produce: suspend () -> String
    ): String {
        val sourceKey = source.sourceUrl
        val (loader, generation) = guard.withLock {
            val loader = loaders.getOrPut(sourceKey) { Loader() }
            loader.users++
            loader to loader.generation
        }
        try {
            return loader.mutex.withLock {
                val fingerprint = fingerprint(source, sortRule)
                val inMemory = guard.withLock {
                    entries[sourceKey]?.takeIf { it.fingerprint == fingerprint }?.also {
                        entries.remove(sourceKey)
                        entries[sourceKey] = it
                    }
                }
                if (inMemory != null) return@withLock inMemory.payload

                val persisted = cacheRepository?.getValue(persistentKey(sourceKey))?.let { value ->
                    runCatching { json.decodeFromString<Entry>(value) }.getOrNull()
                }?.takeIf { it.fingerprint == fingerprint && it.payload.isNotBlank() }
                val payload = persisted?.payload ?: produce()
                guard.withLock {
                    // Clear and publication share the guard, but never wait for JS/network here.
                    if (loader.generation == generation && payload.isNotBlank()) {
                        val entry = Entry(fingerprint, payload)
                        if (persisted == null) {
                            cacheRepository?.insert(Cache(persistentKey(sourceKey), json.encodeToString(entry), 0L))
                        }
                        removeLegacyEntries(source)
                        entries.remove(sourceKey)
                        entries[sourceKey] = entry
                        while (entries.size > MAX_ENTRIES) {
                            entries.remove(entries.keys.first())
                        }
                    }
                }
                payload
            }
        } finally {
            withContext(NonCancellable) {
                guard.withLock {
                    loader.users--
                    if (loader.users == 0) loaders.remove(sourceKey)
                }
            }
        }
    }

    suspend fun clear(source: RssSource) {
        guard.withLock {
            loaders[source.sourceUrl]?.let { it.generation++ }
            entries.remove(source.sourceUrl)
            cacheRepository?.delete(persistentKey(source.sourceUrl))
            removeLegacyEntries(source)
        }
    }

    private suspend fun fingerprint(source: RssSource, sortRule: String): String {
        val variables = sourceStateStore.getSourceVariableMap(source.sourceUrl)
            .entries.sortedBy { it.key }.associate { it.key to it.value }
        return json.encodeToString(
            Fingerprint(
                source = source.copy(sortUrl = sortRule),
                sourceVariable = sourceStateStore.getSourceVariable(source.sourceUrl),
                sourceVariables = variables,
                loginHeader = sourceStateStore.getLoginHeader(source.sourceUrl),
                loginInfo = sourceStateStore.getLoginInfo(source.sourceUrl)
            )
        ).md5Hex()
    }

    private suspend fun removeLegacyEntries(source: RssSource) {
        // Android stored an unversioned payload; neither raw nor trimmed keys prove its configuration.
        listOf(
            (source.sourceUrl + source.sortUrl).md5Hex(),
            (source.sourceUrl + source.sortUrl.orEmpty().trim()).md5Hex()
        ).distinct().forEach { cacheRepository?.delete(it) }
    }

    private fun persistentKey(sourceKey: String): String = "rssSort:v2:${sourceKey.md5Hex()}"

    private class Loader {
        val mutex = Mutex()
        var users = 0
        var generation = 0L
    }

    @Serializable
    private data class Entry(val fingerprint: String, val payload: String)

    @Serializable
    private data class Fingerprint(
        val source: RssSource,
        val sourceVariable: String?,
        val sourceVariables: Map<String, String>,
        val loginHeader: String?,
        val loginInfo: String?
    )

    private companion object {
        const val MAX_ENTRIES = 64
        val json = Json { ignoreUnknownKeys = true }
    }
}
