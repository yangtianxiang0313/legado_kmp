package io.legado.kmp.shared.network

import io.ktor.client.HttpClient
import io.ktor.client.HttpClientConfig
import io.ktor.http.Url
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

internal expect fun createSourcePlatformHttpClient(
    sourceUrl: String,
    proxy: String?,
    allowCertificateCompatibility: Boolean,
    maxConcurrent: Int,
    block: HttpClientConfig<*>.() -> Unit,
): HttpClient

/** An engine is scoped to its source, not a header or a URL shared by unrelated sources. */
internal class SourceHttpClientPool {
    private data class Key(val source: String, val origin: String, val proxy: String?, val compatibility: Boolean,
        val trustRevision: String, val maxConcurrent: Int)
    private class Entry(val client: HttpClient, var users: Int = 0)
    private val mutex = Mutex()
    private val clients = linkedMapOf<Key, Entry>()

    suspend fun <T> use(config: HttpRequestConfig, block: suspend (HttpClient) -> T): T {
        val target = Url(config.url)
        val origin = "${target.protocol.name}://${target.host.lowercase()}:${target.port}"
        val source = requireNotNull(config.sourceNetworkKey)
        val trustRevision = SourceNetworkPolicy.certificateGrants(source).filter { it.host == target.host.lowercase() && it.port == target.port }
            .joinToString(";") { "${it.fingerprint}:${it.expiresAt}" }
        val key = Key(source, origin, config.sourceNetworkProxy, config.allowSourceCertificateCompatibility, trustRevision,
            SourceNetworkPolicy.effective(source).maxConcurrent ?: 6)
        val entry = mutex.withLock {
            val entry = clients.remove(key) ?: Entry(createSourcePlatformHttpClient(key.source, key.proxy, key.compatibility, key.maxConcurrent) {
                followRedirects = false
                install(io.ktor.client.plugins.HttpTimeout) {
                    requestTimeoutMillis = 300_000; connectTimeoutMillis = 30_000; socketTimeoutMillis = 300_000
                }
                expectSuccess = false
            })
            entry.users++
            clients[key] = entry
            trim()
            entry
        }
        return try { block(entry.client) } finally {
            withContext(NonCancellable) { mutex.withLock { entry.users--; trim() } }
        }
    }

    private fun trim() {
        while (clients.size > 32) {
            val idle = clients.entries.firstOrNull { it.value.users == 0 } ?: return
            clients.remove(idle.key)
            idle.value.client.close()
        }
    }
}
