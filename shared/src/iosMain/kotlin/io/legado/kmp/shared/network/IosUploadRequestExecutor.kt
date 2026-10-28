package io.legado.kmp.shared.network

import io.ktor.client.HttpClient
import io.ktor.client.call.body
import io.ktor.client.request.forms.MultiPartFormDataContent
import io.ktor.client.request.forms.formData
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse as KtorHttpResponse
import io.ktor.http.Headers
import io.ktor.http.HttpHeaders

class IosUploadRequestExecutor : UploadRequestExecutor {
    private val client = LegadoHttpClient.createDefaultHttpClient()
    private val noRedirectClient = LegadoHttpClient.createDefaultHttpClient(followRedirects = false)

    override suspend fun execute(context: SourceExecutionContext, upload: MultipartUploadRequest): HttpResponse {
        val proxy = context.proxy?.takeIf { it.isNotBlank() }
        val requestClient = proxy?.let {
            createIosProxyHttpClient(parseProxy(it), followRedirects = context.requestConfig.followRedirects).withUserAgentPolicy()
        } ?: if (context.requestConfig.followRedirects) client else noRedirectClient
        try {
            val response = requestClient.post(upload.url) {
                context.requestConfig.headers.forEach { (key, value) ->
                    if (!key.equals(HttpHeaders.ContentType, ignoreCase = true)) {
                        header(key, value)
                    }
                }
                setBody(upload.toMultipartContent())
            }
            return response.toLegadoHttpResponse()
        } finally {
            if (proxy != null) {
                requestClient.close()
            }
        }
    }
}

private fun MultipartUploadRequest.toMultipartContent(): MultiPartFormDataContent {
    return MultiPartFormDataContent(
        formData {
            parts.forEach { part ->
                when (part) {
                    is MultipartFormField -> append(part.name, part.value)
                    is MultipartFileField -> append(
                        key = part.name,
                        value = part.fileData,
                        headers = Headers.build {
                            append(
                                HttpHeaders.ContentDisposition,
                                "form-data; name=\"${part.name}\"; filename=\"${part.fileName}\""
                            )
                            append(HttpHeaders.ContentType, part.contentType)
                        }
                    )
                }
            }
        }
    )
}

private suspend fun KtorHttpResponse.toLegadoHttpResponse(): HttpResponse {
    val bodyBytes = body<ByteArray>()
    val bodyText = bodyBytes.decodeToString()
    val allHeaders = headers.names().associateWith { name -> headers.getAll(name).orEmpty() }.withSplitSetCookieHeaders()
    return HttpResponse(
        statusCode = status.value,
        statusText = status.description,
        headers = allHeaders.mapValues { it.value.firstOrNull() ?: "" },
        allHeaders = allHeaders,
        body = bodyBytes,
        bodyText = bodyText,
        url = call.request.url.toString(),
        errorBodyText = bodyText.takeIf { status.value !in 200..299 }
    )
}
