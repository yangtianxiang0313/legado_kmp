package io.legado.kmp.shared.network

import io.ktor.client.call.body
import io.ktor.client.request.header
import io.ktor.client.request.request
import io.ktor.client.request.setBody
import io.ktor.client.request.url
import io.ktor.http.HttpMethod as KtorHttpMethod
import kotlinx.serialization.Serializable
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi

/**
 * WebDAV file metadata returned from PROPFIND.
 */
@Serializable
data class WebDavFile(
    val path: String,
    val displayName: String,
    val size: Long = 0,
    val contentType: String = "",
    val resourceType: String = "",
    val lastModify: Long = 0
) {
    val isDir: Boolean
        get() = contentType == "httpd/unix-directory"
                || resourceType.lowercase().contains("collection")
}

open class WebDavException(message: String, cause: Throwable? = null) : Exception(message, cause)
class ObjectNotFoundException(message: String) : WebDavException(message)

/**
 * Lightweight WebDAV client using Ktor HttpClient directly (not LegadoHttpClient)
 * because WebDAV requires real PROPFIND/MKCOL HTTP methods.
 */
class WebDavClient {

    companion object {
        private const val DIR_PROPFIND = """<?xml version="1.0"?>
<a:propfind xmlns:a="DAV:">
  <a:prop>
    <a:displayname/>
    <a:resourcetype/>
    <a:getcontentlength/>
    <a:creationdate/>
    <a:getlastmodified/>
  </a:prop>
</a:propfind>"""

        private const val EXISTS_PROPFIND = """<?xml version="1.0"?>
<propfind xmlns="DAV:">
  <prop><resourcetype/></prop>
</propfind>"""

        private val PROPFIND = KtorHttpMethod("PROPFIND")
        private val MKCOL = KtorHttpMethod("MKCOL")
    }

    // Lazily create a Ktor client for WebDAV (separate from the app's main client)
    private val client by lazy {
        createPlatformHttpClient {
            // no special plugins needed
        }
    }

    @OptIn(ExperimentalEncodingApi::class)
    private fun basicAuth(username: String, password: String): String {
        val credentials = "$username:$password"
        return "Basic ${Base64.encode(credentials.encodeToByteArray())}"
    }

    private fun normalizeUrl(url: String): String {
        return url.replace("davs://", "https://")
            .replace("dav://", "http://")
    }

    /**
     * Check whether the credentials are valid (returns false on 401).
     */
    suspend fun check(url: String, username: String, password: String): Boolean {
        return try {
            val response = client.request {
                this.method = PROPFIND
                url(normalizeUrl(url))
                header("Authorization", basicAuth(username, password))
                header("Depth", "0")
                header("Content-Type", "application/xml")
                setBody(EXISTS_PROPFIND)
            }
            response.status.value != 401
        } catch (_: Exception) {
            true
        }
    }

    /**
     * Check if a resource exists.
     */
    suspend fun exists(url: String, username: String, password: String): Boolean {
        return try {
            val response = client.request {
                this.method = PROPFIND
                url(normalizeUrl(url))
                header("Authorization", basicAuth(username, password))
                header("Depth", "0")
                header("Content-Type", "application/xml")
                setBody(EXISTS_PROPFIND)
            }
            response.status.value in 200..299 || response.status.value == 207
        } catch (_: Exception) {
            false
        }
    }

    /**
     * List files under a directory (Depth: 1 PROPFIND).
     */
    suspend fun listFiles(url: String, username: String, password: String): List<WebDavFile> {
        val normalizedUrl = normalizeUrl(url)
        val response = client.request {
            this.method = PROPFIND
            url(normalizedUrl)
            header("Authorization", basicAuth(username, password))
            header("Depth", "1")
            header("Content-Type", "text/plain")
            setBody(DIR_PROPFIND)
        }
        val status = response.status.value
        if (status !in 200..299 && status != 207) {
            throw WebDavException("PROPFIND failed: $status")
        }
        val body = response.body<ByteArray>().decodeToString()
        return parsePropfindResponse(body, normalizedUrl)
            .filter { it.path != normalizedUrl && it.path != normalizedUrl.trimEnd('/') }
    }

    /**
     * Create a directory (MKCOL).
     */
    suspend fun makeDir(url: String, username: String, password: String): Boolean {
        if (exists(url, username, password)) return true
        return try {
            val response = client.request {
                this.method = MKCOL
                url(normalizeUrl(url))
                header("Authorization", basicAuth(username, password))
            }
            response.status.value in listOf(200, 201, 204, 405)
        } catch (_: Exception) {
            false
        }
    }

    /**
     * Upload bytes via PUT.
     */
    suspend fun upload(
        url: String,
        username: String,
        password: String,
        data: ByteArray,
        contentType: String = "application/octet-stream"
    ) {
        val response = client.request {
            this.method = KtorHttpMethod.Put
            url(normalizeUrl(url))
            header("Authorization", basicAuth(username, password))
            header("Content-Type", contentType)
            setBody(data)
        }
        val status = response.status.value
        if (status !in 200..299 && status != 201 && status != 204) {
            throw WebDavException("PUT failed: $status")
        }
    }

    /**
     * Download a file as bytes (GET).
     */
    suspend fun download(url: String, username: String, password: String): ByteArray {
        val response = client.request {
            this.method = KtorHttpMethod.Get
            url(normalizeUrl(url))
            header("Authorization", basicAuth(username, password))
        }
        if (response.status.value !in 200..299) {
            throw WebDavException("GET failed: ${response.status.value}")
        }
        return response.body<ByteArray>()
    }

    /**
     * WC-01: Upload with streaming support.
     * Accepts a suspend lambda that provides the bytes, enabling chunked/streaming upload
     * from platform-specific sources (file streams, etc.).
     */
    suspend fun uploadStreaming(
        url: String,
        username: String,
        password: String,
        contentType: String = "application/octet-stream",
        dataProvider: suspend () -> ByteArray
    ) {
        val data = dataProvider()
        upload(url, username, password, data, contentType)
    }

    /**
     * WC-02: Download to a callback (streaming download).
     * Downloads the file and passes bytes to the provided callback,
     * enabling platform-specific handling (write to file, etc.).
     */
    suspend fun downloadTo(
        url: String,
        username: String,
        password: String,
        handler: suspend (ByteArray) -> Unit
    ) {
        val bytes = download(url, username, password)
        handler(bytes)
    }

    /**
     * WC-03: Move/rename a WebDAV resource.
     * Uses HTTP MOVE method with Destination header.
     */
    suspend fun move(
        fromUrl: String,
        toUrl: String,
        username: String,
        password: String,
        overwrite: Boolean = true
    ): Boolean {
        return try {
            val response = client.request {
                this.method = KtorHttpMethod("MOVE")
                url(normalizeUrl(fromUrl))
                header("Authorization", basicAuth(username, password))
                header("Destination", normalizeUrl(toUrl))
                header("Overwrite", if (overwrite) "T" else "F")
            }
            response.status.value in listOf(200, 201, 204)
        } catch (_: Exception) {
            false
        }
    }

    /**
     * WC-04: Copy a WebDAV resource.
     * Uses HTTP COPY method with Destination header.
     */
    suspend fun copy(
        fromUrl: String,
        toUrl: String,
        username: String,
        password: String,
        overwrite: Boolean = true
    ): Boolean {
        return try {
            val response = client.request {
                this.method = KtorHttpMethod("COPY")
                url(normalizeUrl(fromUrl))
                header("Authorization", basicAuth(username, password))
                header("Destination", normalizeUrl(toUrl))
                header("Overwrite", if (overwrite) "T" else "F")
            }
            response.status.value in listOf(200, 201, 204)
        } catch (_: Exception) {
            false
        }
    }

    /**
     * Delete a resource.
     */
    suspend fun delete(url: String, username: String, password: String): Boolean {
        return try {
            val response = client.request {
                this.method = KtorHttpMethod.Delete
                url(normalizeUrl(url))
                header("Authorization", basicAuth(username, password))
            }
            response.status.value in listOf(200, 204, 404)
        } catch (_: Exception) {
            false
        }
    }

    // ── XML parsing ─────────────────────────────────────────────────

    private fun parsePropfindResponse(xml: String, baseUrl: String): List<WebDavFile> {
        val files = mutableListOf<WebDavFile>()
        val responsePattern = Regex(
            """<(?:[a-zA-Z]+:)?response[^>]*>([\s\S]*?)</(?:[a-zA-Z]+:)?response>"""
        )
        for (match in responsePattern.findAll(xml)) {
            val block = match.groupValues[1]
            val href = extractTag(block, "href") ?: continue
            val displayName = extractTag(block, "displayname")
                ?: decodePercent(href.trimEnd('/').substringAfterLast('/'))
            val contentLength = extractTag(block, "getcontentlength")?.toLongOrNull() ?: 0
            val contentType = extractTag(block, "getcontenttype") ?: ""
            val resourceType = extractTagContent(block, "resourcetype") ?: ""
            val lastModified = extractTag(block, "getlastmodified")
            val lastModifyMs = parseHttpDate(lastModified)

            val fullPath = if (href.startsWith("http://") || href.startsWith("https://")) {
                href
            } else {
                val base = baseUrl.substringBefore("://") + "://" +
                        baseUrl.substringAfter("://").substringBefore("/")
                base + href
            }

            val isDir = contentType == "httpd/unix-directory"
                    || resourceType.lowercase().contains("collection")

            files.add(
                WebDavFile(
                    path = if (isDir && !fullPath.endsWith("/")) "$fullPath/" else fullPath,
                    displayName = decodePercent(displayName),
                    size = contentLength,
                    contentType = contentType,
                    resourceType = resourceType,
                    lastModify = lastModifyMs
                )
            )
        }
        return files
    }

    private fun extractTag(xml: String, tagName: String): String? {
        val pattern = Regex(
            """<(?:[a-zA-Z]+:)?$tagName[^>]*>([\s\S]*?)</(?:[a-zA-Z]+:)?$tagName>"""
        )
        return pattern.find(xml)?.groupValues?.get(1)?.trim()
    }

    private fun extractTagContent(xml: String, tagName: String): String? {
        val pattern = Regex(
            """<(?:[a-zA-Z]+:)?$tagName[^>]*>([\s\S]*?)</(?:[a-zA-Z]+:)?$tagName>"""
        )
        return pattern.find(xml)?.groupValues?.get(1)
    }

    private fun parseHttpDate(dateStr: String?): Long {
        if (dateStr.isNullOrBlank()) return 0
        return try {
            val months = mapOf(
                "Jan" to 1, "Feb" to 2, "Mar" to 3, "Apr" to 4,
                "May" to 5, "Jun" to 6, "Jul" to 7, "Aug" to 8,
                "Sep" to 9, "Oct" to 10, "Nov" to 11, "Dec" to 12
            )
            val parts = dateStr.replace(",", "").split(Regex("\\s+"))
            if (parts.size >= 5) {
                val day = parts[1].toIntOrNull() ?: return 0
                val month = months[parts[2]] ?: return 0
                val year = parts[3].toIntOrNull() ?: return 0
                val timeParts = parts[4].split(":")
                val hour = timeParts.getOrNull(0)?.toIntOrNull() ?: 0
                val minute = timeParts.getOrNull(1)?.toIntOrNull() ?: 0
                val second = timeParts.getOrNull(2)?.toIntOrNull() ?: 0
                val daysFromEpoch = daysSinceEpoch(year, month, day)
                (daysFromEpoch * 86400L + hour * 3600L + minute * 60L + second) * 1000L
            } else 0
        } catch (_: Exception) {
            0
        }
    }

    private fun daysSinceEpoch(year: Int, month: Int, day: Int): Long {
        var y = year; var m = month
        if (m <= 2) { y--; m += 12 }
        val era = (if (y >= 0) y else y - 399) / 400
        val yoe = y - era * 400
        val doy = (153 * (m - 3) + 2) / 5 + day - 1
        val doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return (era * 146097L + doe - 719468)
    }

    private fun decodePercent(s: String): String {
        return try {
            val sb = StringBuilder()
            var i = 0
            val bytes = mutableListOf<Byte>()
            while (i < s.length) {
                if (s[i] == '%' && i + 2 < s.length) {
                    val hex = s.substring(i + 1, i + 3)
                    bytes.add(hex.toInt(16).toByte())
                    i += 3
                } else {
                    if (bytes.isNotEmpty()) {
                        sb.append(bytes.toByteArray().decodeToString())
                        bytes.clear()
                    }
                    sb.append(s[i])
                    i++
                }
            }
            if (bytes.isNotEmpty()) {
                sb.append(bytes.toByteArray().decodeToString())
            }
            sb.toString()
        } catch (_: Exception) {
            s
        }
    }
}
