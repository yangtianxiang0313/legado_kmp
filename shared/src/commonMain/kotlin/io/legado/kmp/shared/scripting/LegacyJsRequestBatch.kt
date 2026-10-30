package io.legado.kmp.shared.scripting

import io.legado.kmp.shared.network.SourceResponse
import io.legado.kmp.shared.platform.ConsumerConcurrencyPolicy
import io.legado.kmp.shared.preferences.AppPreferencesStore
import io.legado.kmp.shared.preferences.AppRuntimeConfig
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.koin.mp.KoinPlatformTools

internal suspend fun connectLegacyJsRequestBatch(
    urlRules: List<String>,
    headerJson: String?,
    connect: suspend (urlRule: String, headerJson: String?) -> SourceResponse,
    concurrencyProvider: () -> Int = ::legacyJsRequestConcurrency,
): List<SourceResponse> {
    currentCoroutineContext().ensureActive()
    if (urlRules.isEmpty()) return emptyList()

    // Snapshot once per batch, like Android JsExtensions.ajaxAll's AppConfig.threadCount.
    val workerCount = ConsumerConcurrencyPolicy.workerCount(concurrencyProvider(), urlRules.size)
    val responses = arrayOfNulls<SourceResponse>(urlRules.size)
    val workMutex = Mutex()
    var nextIndex = 0
    coroutineScope {
        val workers = List(workerCount) {
            async {
                while (true) {
                    currentCoroutineContext().ensureActive()
                    val index = workMutex.withLock {
                        if (nextIndex >= urlRules.size) return@async
                        nextIndex++
                    }
                    val response = connect(urlRules[index], headerJson)
                    currentCoroutineContext().ensureActive()
                    responses[index] = response
                }
            }
        }
        // A worker's own cancellation also fails the batch; the scope cancels and joins all workers.
        workers.awaitAll()
    }
    return responses.map { checkNotNull(it) }
}

private fun legacyJsRequestConcurrency(): Int {
    // Resolve the existing store at invocation time, without starting the runtime or caching preferences.
    return KoinPlatformTools.defaultContext().getOrNull()
        ?.getOrNull<AppPreferencesStore>()
        ?.runtimeConfig?.value?.threadCount
        ?: AppRuntimeConfig().threadCount
}
