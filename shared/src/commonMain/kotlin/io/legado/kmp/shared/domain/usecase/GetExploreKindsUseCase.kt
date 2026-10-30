package io.legado.kmp.shared.domain.usecase

import io.legado.kmp.shared.domain.repository.CacheRepository
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.model.Cache
import io.legado.kmp.shared.model.ExploreKind
import io.legado.kmp.shared.network.LegacyJsConnectGateway
import io.legado.kmp.shared.scripting.JsResult
import io.legado.kmp.shared.scripting.LegacyJsHostSurface
import io.legado.kmp.shared.scripting.LegacySourceJsRuntime
import io.legado.kmp.shared.scripting.SourceJsRuntime
import io.legado.kmp.shared.source.SourceStateStore
import io.legado.kmp.shared.util.splitLegacyPayloadItems
import io.legado.kmp.shared.util.md5Hex
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.Json

class GetExploreKindsUseCase(
    private val connectGateway: LegacyJsConnectGateway? = null,
    private val sourceStateStore: SourceStateStore? = null,
    private val cacheRepository: CacheRepository? = null,
    private val sourceJsRuntime: SourceJsRuntime? = null
) {

    suspend operator fun invoke(source: BookSource): Result<List<ExploreKind>> = runCatching {
        val exploreUrl = source.exploreUrl?.trim().orEmpty()
        if (exploreUrl.isBlank()) {
            return@runCatching emptyList()
        }

        val cacheKey = source.getExploreKindsKey()
        getInMemory(cacheKey)?.let { return@runCatching it }

        val mutex = getMutex(source.bookSourceUrl)
        mutex.withLock {
            getInMemory(cacheKey)?.let { return@withLock it }
            val kinds = parseExploreKinds(source, exploreUrl, cacheKey)
            putInMemory(cacheKey, kinds)
            kinds
        }
    }

    suspend fun clearCache(source: BookSource) {
        val key = source.getExploreKindsKey()
        getMutex(source.bookSourceUrl).withLock {
            cacheRepository?.delete(key)
            cacheGuard.withLock {
                exploreKindsMap.remove(key)
            }
        }
    }

    private suspend fun parseExploreKinds(
        source: BookSource,
        exploreUrl: String,
        cacheKey: String
    ): List<ExploreKind> {
        val payload = when {
            isJsExploreRule(exploreUrl) -> getOrComputeJsPayload(source, exploreUrl, cacheKey)
            else -> exploreUrl
        }
        return parsePayload(payload)
    }

    private suspend fun getOrComputeJsPayload(
        source: BookSource,
        exploreUrl: String,
        cacheKey: String
    ): String {
        cacheRepository?.getValue(cacheKey)?.let { cached ->
            if (cached.isNotBlank()) return cached
        }

        val executor = checkNotNull(connectGateway) {
            "JS-based explore kinds require LegacyJsConnectGateway"
        }
        val script = extractJsScript(exploreUrl)
        val payload = when (val result = (sourceJsRuntime ?: LegacySourceJsRuntime(sourceStateStore)).execute(
            script = script,
            source = source,
            connect = { urlRule, headerJson ->
                executor.executeForLegacyJs(urlRule, source, headerJson)
            },
            rawConnect = { urlRule, headerJson ->
                executor.executeForLegacyJsRaw(urlRule, source, headerJson)
            },
            host = LegacyJsHostSurface.fromCallbacks(
                source = source,
                connect = { urlRule, headerJson -> executor.executeForLegacyJs(urlRule, source, headerJson) },
                jsoupExecute = executor::executeJsoupForLegacyJs,
            ),
        )) {
            is JsResult.JsString -> result.value
            is JsResult.JsError -> throw IllegalStateException(result.message, result.exception)
            else -> result.asString()
        }.trim()

        if (payload.isNotBlank()) {
            cacheRepository?.insert(Cache(key = cacheKey, value = payload, deadline = 0L))
        }
        return payload
    }

    private fun parsePayload(payload: String): List<ExploreKind> {
        val content = payload.trim()
        if (content.isBlank()) return emptyList()
        return if (content.startsWith("[")) {
            json.decodeFromString(content)
        } else {
            splitLegacyPayloadItems(content)
                .mapNotNull { line ->
                    val trimmed = line.trim()
                    if (trimmed.isBlank()) {
                        null
                    } else {
                        val parts = trimmed.split("::", limit = 2)
                        ExploreKind(
                            title = parts.first().trim(),
                            url = parts.getOrNull(1)?.trim()?.takeIf { it.isNotBlank() }
                        )
                    }
                }
        }
    }

    private fun extractJsScript(exploreUrl: String): String {
        val trimmed = exploreUrl.trim()
        return when {
            trimmed.startsWith("@js:", ignoreCase = true) -> trimmed.substring(4).trim()
            trimmed.startsWith("<js>", ignoreCase = true) &&
                trimmed.endsWith("</js>", ignoreCase = true) -> {
                trimmed.substring(4, trimmed.length - 5).trim()
            }
            else -> trimmed
        }
    }

    private fun isJsExploreRule(exploreUrl: String): Boolean {
        return exploreUrl.startsWith("@js:", ignoreCase = true) ||
            exploreUrl.startsWith("<js>", ignoreCase = true)
    }

    private suspend fun getInMemory(key: String): List<ExploreKind>? {
        return cacheGuard.withLock { exploreKindsMap[key] }
    }

    private suspend fun putInMemory(key: String, kinds: List<ExploreKind>) {
        cacheGuard.withLock {
            exploreKindsMap[key] = kinds
        }
    }

    private suspend fun getMutex(sourceKey: String): Mutex {
        return cacheGuard.withLock {
            mutexMap.getOrPut(sourceKey) { Mutex() }
        }
    }

    private fun BookSource.getExploreKindsKey(): String {
        return (bookSourceUrl + (exploreUrl ?: "")).md5Hex()
    }

    private companion object {
        private val json = Json {
            ignoreUnknownKeys = true
            isLenient = true
        }
        private val cacheGuard = Mutex()
        private val mutexMap = mutableMapOf<String, Mutex>()
        private val exploreKindsMap = mutableMapOf<String, List<ExploreKind>>()
    }
}
