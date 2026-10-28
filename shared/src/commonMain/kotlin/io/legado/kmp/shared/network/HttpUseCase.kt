package io.legado.kmp.shared.network

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

/**
 * Use case for HTTP operations
 * Provides a high-level API for making HTTP requests
 */
class HttpUseCase(
    private val httpClient: LegadoHttpClient = LegadoHttpClient()
) {

    suspend fun execute(config: HttpRequestConfig): Result<HttpResponse> {
        return try {
            Result.success(httpClient.execute(config))
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun executeAsString(config: HttpRequestConfig): Result<String> {
        return execute(config).fold(
            onSuccess = { response ->
                if (response.isSuccessful) {
                    Result.success(response.bodyText)
                } else {
                    Result.failure(HttpException(response.statusCode, response.statusText))
                }
            },
            onFailure = { Result.failure(it) }
        )
    }

    /**
     * GET request that returns text
     *
     * @param url The URL to request
     * @param headers Optional headers
     * @param parameters Optional query parameters
     * @return Response text
     */
    suspend fun getAsString(
        url: String,
        headers: Map<String, String> = emptyMap(),
        parameters: Map<String, String> = emptyMap()
    ): Result<String> {
        return try {
            val response = httpClient.get(url, headers, parameters)
            if (response.isSuccessful) {
                Result.success(response.bodyText)
            } else {
                Result.failure(HttpException(response.statusCode, response.statusText))
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    /**
     * GET request that returns bytes
     *
     * @param url The URL to request
     * @param headers Optional headers
     * @param parameters Optional query parameters
     * @return Response bytes
     */
    suspend fun getAsBytes(
        url: String,
        headers: Map<String, String> = emptyMap(),
        parameters: Map<String, String> = emptyMap()
    ): Result<ByteArray> {
        return try {
            val response = httpClient.get(url, headers, parameters)
            if (response.isSuccessful) {
                Result.success(response.body)
            } else {
                Result.failure(HttpException(response.statusCode, response.statusText))
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    /**
     * POST request
     *
     * @param url The URL to request
     * @param body Request body
     * @param headers Optional headers
     * @return Response text
     */
    suspend fun postAsString(
        url: String,
        body: String? = null,
        headers: Map<String, String> = emptyMap()
    ): Result<String> {
        return try {
            val response = httpClient.post(url, body, headers)
            if (response.isSuccessful) {
                Result.success(response.bodyText)
            } else {
                Result.failure(HttpException(response.statusCode, response.statusText))
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    /**
     * POST request with bytes
     *
     * @param url The URL to request
     * @param bodyBytes Request body as bytes
     * @param headers Optional headers
     * @return Response text
     */
    suspend fun postBytes(
        url: String,
        bodyBytes: ByteArray,
        headers: Map<String, String> = emptyMap()
    ): Result<String> {
        return try {
            val response = httpClient.postBytes(url, bodyBytes, headers)
            if (response.isSuccessful) {
                Result.success(response.bodyText)
            } else {
                Result.failure(HttpException(response.statusCode, response.statusText))
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    /**
     * Get content length without downloading
     *
     * @param url The URL to check
     * @return Content length in bytes, or null if not available
     */
    suspend fun getContentLength(url: String): Long? {
        return httpClient.getContentLength(url)
    }

    /**
     * Stream download as chunks
     *
     * @param url The URL to download from
     * @param headers Optional headers
     * @param chunkSize Size of chunks
     * @return Flow of byte arrays
     */
    fun streamDownload(
        url: String,
        headers: Map<String, String> = emptyMap(),
        chunkSize: Int = 8192
    ): Flow<ByteArray> {
        return httpClient.stream(url, headers, chunkSize)
    }

    /**
     * Batch GET requests
     *
     * @param urls List of URLs to request
     * @param headers Optional headers
     * @return Map of URL to response text
     */
    suspend fun batchGet(
        urls: List<String>,
        headers: Map<String, String> = emptyMap()
    ): Map<String, Result<String>> {
        return urls.associateWith { url ->
            getAsString(url, headers)
        }
    }

    /**
     * Try GET with fallback URLs
     *
     * @param urls List of URLs to try in order
     * @param headers Optional headers
     * @return First successful response or last error
     */
    suspend fun getWithFallback(
        urls: List<String>,
        headers: Map<String, String> = emptyMap()
    ): Result<String> {
        var lastError: Throwable? = null

        for (url in urls) {
            val result = getAsString(url, headers)
            if (result.isSuccess) {
                return result
            }
            lastError = result.exceptionOrNull()
        }

        return Result.failure(lastError ?: HttpException(0, "No URLs provided"))
    }
}

/**
 * HTTP exception
 */
class HttpException(
    val statusCode: Int,
    override val message: String
) : Exception("HTTP $statusCode: $message")

/**
 * Network exception
 */
class NetworkException(
    override val message: String,
    override val cause: Throwable? = null
) : Exception(message, cause)

/**
 * Timeout exception
 */
class TimeoutException(
    override val message: String,
    val duration: kotlin.time.Duration
) : Exception("Timeout after ${duration.inWholeSeconds}s: $message")
