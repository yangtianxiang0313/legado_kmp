package io.legado.kmp.shared.network

internal data class LegacyJsoupTransportRequest(
    val url: String,
    val method: String,
    val headers: Map<String, String>,
    val body: ByteArray?,
    val timeoutMillis: Int,
    val maxBodySize: Int,
)

internal data class LegacyJsoupTransportHead(
    val url: String,
    val statusCode: Int,
    val allHeaders: Map<String, List<String>>,
)

internal data class LegacyJsoupTransportResponse(val head: LegacyJsoupTransportHead, val body: ByteArray)

internal expect suspend fun legacyJsoupTransport(
    request: LegacyJsoupTransportRequest,
    acceptBody: (LegacyJsoupTransportHead) -> Boolean,
): LegacyJsoupTransportResponse
