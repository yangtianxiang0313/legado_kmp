package io.legado.kmp.shared.facade

import io.ktor.client.call.body
import io.ktor.client.plugins.HttpTimeout
import io.ktor.client.request.header
import io.ktor.client.request.request
import io.ktor.client.request.setBody
import io.ktor.client.request.url
import io.ktor.http.HttpMethod
import io.ktor.http.URLBuilder
import io.ktor.http.appendPathSegments
import io.legado.kmp.shared.model.BookProgress
import io.legado.kmp.shared.network.createPlatformHttpClient
import io.legado.kmp.shared.preferences.AppRuntimeConfig
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.Json

/** Progress has stricter missing/error semantics than an optional backup listing. */
internal class ReaderProgressWebDav {
    private val client by lazy {
        createPlatformHttpClient {
            expectSuccess = false
            // Never forward WebDAV credentials to a redirected host.
            followRedirects = false
            install(HttpTimeout) { requestTimeoutMillis = 20_000; connectTimeoutMillis = 10_000 }
        }
    }
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    data class Endpoint(val root: String, val account: String, val password: String) {
        val directory: String get() = URLBuilder(root).apply { appendPathSegments("bookProgress", "") }.buildString()

        fun file(name: String, author: String): String = URLBuilder(directory).apply {
            appendPathSegments(progressFileName(name, author))
        }.buildString()
    }

    data class Document(val progress: BookProgress?, val etag: String?)

    suspend fun read(endpoint: Endpoint, name: String, author: String): Document {
        val response = client.request {
            method = HttpMethod.Get
            url(endpoint.file(name, author))
            header("Authorization", authorization(endpoint))
            header("Accept", "application/json")
            header("Cache-Control", "no-cache")
        }
        currentCoroutineContext().ensureActive()
        if (response.status.value == 404) return Document(null, null)
        requireSuccess(response.status.value, "获取云端进度")
        val bytes = response.body<ByteArray>()
        if (bytes.isEmpty() || bytes.size > 262_144) {
            throw RecoverableSharedException("PROGRESS_INVALID", "云端进度为空或超过大小限制")
        }
        val progress = try {
            json.decodeFromString(BookProgress.serializer(), bytes.decodeToString())
        } catch (error: Exception) {
            currentCoroutineContext().ensureActive()
            throw RecoverableSharedException("PROGRESS_INVALID", "无法解析云端阅读进度")
        }
        if (progress.name != name || progress.author != author || progress.durChapterIndex < 0 ||
            progress.durChapterPos < 0 || progress.durChapterTime < 0
        ) {
            throw RecoverableSharedException("PROGRESS_INVALID", "云端进度与当前书籍不匹配或位置无效")
        }
        return Document(progress, response.headers["ETag"]?.takeIf { !it.startsWith("W/") })
    }

    suspend fun write(endpoint: Endpoint, progress: BookProgress, compared: Document? = null) {
        val payload = json.encodeToString(BookProgress.serializer(), progress).encodeToByteArray()
        suspend fun put(): Int = client.request {
            method = HttpMethod.Put
            url(endpoint.file(progress.name, progress.author))
            header("Authorization", authorization(endpoint))
            header("Content-Type", "application/json")
            if (compared != null) {
                if (compared.progress == null) header("If-None-Match", "*")
                else compared.etag?.let { header("If-Match", it) }
            }
            setBody(payload)
        }.status.value
        var status = put()
        // A new account may not have created the progress collection yet.
        if (status == 404 || status == 409) {
            ensureDirectory(endpoint, endpoint.root)
            ensureDirectory(endpoint, endpoint.directory)
            currentCoroutineContext().ensureActive()
            status = put()
        }
        currentCoroutineContext().ensureActive()
        requireSuccess(status, "上传阅读进度")
    }

    private suspend fun ensureDirectory(endpoint: Endpoint, directory: String) {
        val response = client.request {
            method = HttpMethod("MKCOL")
            url(directory)
            header("Authorization", authorization(endpoint))
        }
        currentCoroutineContext().ensureActive()
        if (response.status.value == 405) {
            // 405 is only an existing collection after a successful probe, not blanket success.
            val probe = client.request {
                method = HttpMethod("PROPFIND")
                url(directory)
                header("Authorization", authorization(endpoint))
                header("Depth", "0")
            }
            requireSuccess(probe.status.value, "检查进度目录")
        } else {
            requireSuccess(response.status.value, "创建进度目录")
        }
    }

    @OptIn(ExperimentalEncodingApi::class)
    private fun authorization(endpoint: Endpoint): String =
        "Basic " + Base64.encode("${endpoint.account}:${endpoint.password}".encodeToByteArray())

    private fun requireSuccess(status: Int, action: String) {
        if (status in 200..299) return
        when (status) {
            401, 403 -> throw RecoverableSharedException("WEBDAV_AUTH", "WebDAV 认证失败，请检查账号和密码")
            412 -> throw RecoverableSharedException("PROGRESS_CONFLICT", "云端进度已改变，请重新同步后确认")
            else -> throw RecoverableSharedException("WEBDAV_HTTP_$status", "$action 失败（HTTP $status），可稍后重试")
        }
    }

    companion object {
        fun endpoint(config: AppRuntimeConfig): Endpoint? {
            val account = config.webDavAccount?.takeIf { it.isNotBlank() } ?: return null
            val password = config.webDavPassword?.takeIf { it.isNotBlank() } ?: return null
            val root = (config.webDavUrl?.trim()?.takeIf { it.isNotEmpty() }
                ?: SettingsWebDavSupport.DEFAULT_WEBDAV_URL)
                .replace("davs://", "https://").replace("dav://", "http://")
            val url = try {
                URLBuilder(root)
            } catch (_: IllegalArgumentException) {
                throw RecoverableSharedException("WEBDAV_URL", "WebDAV 地址无效")
            }
            if (url.protocol.name !in setOf("http", "https") || url.host.isBlank() ||
                url.user != null || url.password != null || url.parameters.names().isNotEmpty() || url.fragment.isNotEmpty()
            ) {
                throw RecoverableSharedException("WEBDAV_URL", "WebDAV 地址无效")
            }
            val parts = config.webDavDir.trim().trim('/').split('/').filter { it.isNotEmpty() }
            if (parts.any { it == "." || it == ".." || it.any { c -> c.isISOControl() || c == '\\' } }) {
                throw RecoverableSharedException("WEBDAV_DIR", "WebDAV 目录无效")
            }
            if (parts.isNotEmpty()) url.appendPathSegments(parts)
            url.appendPathSegments("")
            return Endpoint(url.buildString(), account, password)
        }

        fun progressFileName(name: String, author: String): String =
            "${name}_${author}".replace(Regex("[\\\\/:*?\"<>|]"), "_") + ".json"
    }
}
