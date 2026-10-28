package io.legado.kmp.shared.facade

import io.ktor.client.plugins.HttpTimeout
import io.ktor.client.request.header
import io.ktor.client.request.prepareRequest
import io.ktor.client.request.setBody
import io.ktor.client.request.url
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsChannel
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import io.ktor.http.encodeURLPathPart
import io.ktor.utils.io.readAvailable
import io.legado.kmp.shared.network.createPlatformHttpClient
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import okio.Buffer

/** One immutable credential snapshot per operation. No redirect following or global auth/cookie cache. */
internal class WebDavBackupStore(private val config: CloudBackupConfiguration) {
    private val client = createPlatformHttpClient {
        followRedirects = false
        expectSuccess = false
        install(HttpTimeout) {
            connectTimeoutMillis = 20_000L
            socketTimeoutMillis = 60_000L
            requestTimeoutMillis = 300_000L
        }
    }

    @OptIn(ExperimentalEncodingApi::class)
    private val authorization = "Basic " + Base64.encode("${config.account}:${config.password}".encodeToByteArray())

    fun close() = client.close()

    suspend fun list(): List<CloudBackupFile> = properties(config.root, depth = 1)
        .filter { !it.isCollection && it.name?.isBackupName() == true }
        .map { CloudBackupFile(requireNotNull(it.name), it.size, it.lastModified) }
        .sortedWith(compareByDescending<CloudBackupFile> { it.lastModified }.thenByDescending { it.name })

    suspend fun metadata(name: String): CloudBackupFile {
        val resource = properties(config.fileUrl(name), depth = 0)
            .singleOrNull { it.name == name && !it.isCollection } ?: invalidDavResponse()
        if (resource.size > MAX_ARCHIVE_BYTES) cloudBackupError("CLOUD_BACKUP_LIMIT", "云端备份超过 128 MB，未下载")
        return CloudBackupFile(name, resource.size, resource.lastModified)
    }

    suspend fun ensureDirectory(checkConfiguration: () -> Unit) {
        suspend fun ensure(parts: List<String>) {
            // Do not demand permission to list / when the configured DAV collection already exists.
            val path = config.origin + "/" + parts.joinToString("/") { it.encodeURLPathPart() } +
                if (parts.isEmpty()) "" else "/"
            currentCoroutineContext().ensureActive()
            checkConfiguration()
            if (collectionExists(path)) return
            if (parts.isEmpty()) davHttpFailure(404)
            suspend fun create(): Int {
                currentCoroutineContext().ensureActive()
                checkConfiguration()
                return request(HttpMethod("MKCOL"), path) { it.status.value }
            }
            var status = create()
            if (status == 409) {
                // Only a missing-parent response warrants walking up configured same-origin paths.
                ensure(parts.dropLast(1))
                status = create()
            }
            if (status !in listOf(200, 201, 204, 405)) davHttpFailure(status)
            checkConfiguration()
            // 405 means "exists" only after proving this exact resource is a collection.
            if (!collectionExists(path)) invalidDavResponse()
        }
        ensure(config.pathSegments)
    }

    suspend fun upload(name: String, bytes: ByteArray, checkConfiguration: () -> Unit) {
        if (bytes.isEmpty() || bytes.size > MAX_ARCHIVE_BYTES) {
            cloudBackupError("CLOUD_BACKUP_LIMIT", "备份 ZIP 为空或超过 128 MB，未上传")
        }
        currentCoroutineContext().ensureActive()
        checkConfiguration()
        request(HttpMethod.Put, config.fileUrl(name), bytes, "application/zip") { response ->
            if (response.status.value !in 200..299 || response.status.value == 202 || response.status.value == 207) {
                davHttpFailure(response.status.value)
            }
        }
    }

    suspend fun download(name: String): ByteArray = request(HttpMethod.Get, config.fileUrl(name)) { response ->
        if (response.status.value !in 200..299 || response.status.value in listOf(202, 204, 206, 207)) {
            davHttpFailure(response.status.value)
        }
        readBounded(response, MAX_ARCHIVE_BYTES)
    }

    private suspend fun collectionExists(path: String): Boolean = request(HttpMethod("PROPFIND"), path,
        PROPFIND.encodeToByteArray(), "application/xml; charset=utf-8", depth = 0,
    ) { response ->
        if (response.status.value == 404) return@request false
        requireMultistatus(response)
        val resources = parseWebDavBackups(
            readBounded(response, MAX_XML_BYTES).decodeToString(throwOnInvalidSequence = true), configurationFor(path),
        )
        resources.singleOrNull { it.name == null }?.isCollection ?: invalidDavResponse()
    }

    private suspend fun properties(path: String, depth: Int): List<WebDavBackupResource> =
        request(HttpMethod("PROPFIND"), path, PROPFIND.encodeToByteArray(), "application/xml; charset=utf-8", depth) { response ->
            requireMultistatus(response)
            parseWebDavBackups(readBounded(response, MAX_XML_BYTES).decodeToString(throwOnInvalidSequence = true), config)
        }

    private fun configurationFor(path: String): CloudBackupConfiguration = CloudBackupConfiguration(
        config.snapshot.copy(webDavUrl = path, webDavDir = ""),
    )

    private fun requireMultistatus(response: HttpResponse) {
        if (response.status.value != 207) {
            if (response.status.value in 200..299) invalidDavResponse()
            davHttpFailure(response.status.value)
        }
    }

    private suspend fun <T> request(
        method: HttpMethod,
        address: String,
        data: ByteArray? = null,
        contentType: String? = null,
        depth: Int? = null,
        handle: suspend (HttpResponse) -> T,
    ): T = client.prepareRequest {
        this.method = method
        url(address)
        header(HttpHeaders.Authorization, authorization)
        header(HttpHeaders.AcceptEncoding, "identity")
        header(HttpHeaders.CacheControl, "no-cache")
        contentType?.let { header(HttpHeaders.ContentType, it) }
        depth?.let { header("Depth", it.toString()) }
        data?.let { setBody(it) }
    }.execute(handle)

    private suspend fun readBounded(response: HttpResponse, maximum: Int): ByteArray {
        val encoding = response.headers[HttpHeaders.ContentEncoding]
        if (encoding != null && !encoding.equals("identity", true)) invalidDavResponse()
        val declared = response.headers[HttpHeaders.ContentLength]?.let {
            it.toLongOrNull()?.takeIf { length -> length >= 0 } ?: invalidDavResponse()
        }
        if (declared != null && declared > maximum) cloudBackupError("CLOUD_BACKUP_LIMIT", "云备份响应超过允许大小")
        val channel = response.bodyAsChannel()
        val result = Buffer()
        val buffer = ByteArray(64 * 1024)
        try {
            while (true) {
                currentCoroutineContext().ensureActive()
                val count = channel.readAvailable(buffer)
                if (count < 0) break
                if (count == 0) continue
                if (result.size + count > maximum) cloudBackupError("CLOUD_BACKUP_LIMIT", "云备份响应超过允许大小")
                result.write(buffer, 0, count)
            }
            if (declared != null && result.size != declared) {
                cloudBackupError("CLOUD_BACKUP_TRUNCATED", "云备份传输不完整，未恢复任何数据")
            }
            return result.readByteArray()
        } finally {
            channel.cancel(null)
            result.clear()
        }
    }

    private fun String.isBackupName(): Boolean = startsWith("backup", true) &&
        (endsWith(".zip", true) || endsWith(".json", true))

    companion object {
        const val MAX_ARCHIVE_BYTES = 128 * 1024 * 1024
        private const val MAX_XML_BYTES = 4 * 1024 * 1024
        private const val PROPFIND = """<?xml version="1.0" encoding="utf-8"?>
<d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/></d:prop></d:propfind>"""
    }
}
