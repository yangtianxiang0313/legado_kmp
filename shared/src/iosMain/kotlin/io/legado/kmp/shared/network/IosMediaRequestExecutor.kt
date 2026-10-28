package io.legado.kmp.shared.network

class IosMediaRequestExecutor(
    private val proxyRequestExecutor: ProxyRequestExecutor = IosProxyRequestExecutor(),
) : MediaRequestExecutor {
    private val client = LegadoHttpClient()

    override suspend fun execute(context: SourceExecutionContext): HttpResponse {
        val response = context.proxy?.takeIf { it.isNotBlank() }?.let { proxy ->
            proxyRequestExecutor.executeText(context, proxy)
        } ?: client.execute(context.requestConfig)
        return encodeMediaBodyAsHex(response)
    }
}
