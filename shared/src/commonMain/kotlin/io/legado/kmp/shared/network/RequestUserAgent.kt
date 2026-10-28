package io.legado.kmp.shared.network

import io.ktor.client.HttpClient
import io.ktor.client.request.HttpSendPipeline
import io.ktor.http.HttpHeaders
import io.ktor.util.AttributeKey
import io.legado.kmp.shared.preferences.AppPreferencesStore
import io.legado.kmp.shared.preferences.AppRuntimeConfig
import kotlinx.coroutines.flow.first

internal suspend fun configuredUserAgent(preferencesStore: AppPreferencesStore?): String =
    preferencesStore?.runtimeConfig?.first()?.userAgent?.takeIf { it.isNotBlank() }
        ?: AppRuntimeConfig.DEFAULT_USER_AGENT

internal fun MutableMap<String, String>.putAllUserAgentAware(headers: Map<String, String>) {
    headers.forEach { (name, value) ->
        if (name.equals(HttpHeaders.UserAgent, ignoreCase = true)) {
            keys.filter { it.equals(HttpHeaders.UserAgent, ignoreCase = true) }.forEach(::remove)
        }
        put(name, value)
    }
}

internal suspend fun MutableMap<String, String>.putDefaultUserAgent(
    defaultUserAgent: suspend () -> String,
) {
    if (keys.none { it.equals(HttpHeaders.UserAgent, ignoreCase = true) }) {
        put(HttpHeaders.UserAgent, defaultUserAgent())
    }
}

internal fun Map<String, String>.withoutNullUserAgent(): Map<String, String> = filterNot { (name, value) ->
    name.equals(HttpHeaders.UserAgent, ignoreCase = true) && value.equals("null", ignoreCase = true)
}

private val userAgentPolicyInstalled = AttributeKey<Unit>("LegadoUserAgentPolicyInstalled")
private val requestUserAgent = AttributeKey<String>("LegadoRequestUserAgent")

internal fun HttpClient.withUserAgentPolicy(preferencesStore: AppPreferencesStore? = null): HttpClient = apply {
    if (attributes.contains(userAgentPolicyInstalled)) return@apply
    attributes.put(userAgentPolicyInstalled, Unit)
    sendPipeline.intercept(HttpSendPipeline.State) {
        // Keep the choice across redirects and remove the sentinel only after client defaults.
        val value = context.attributes.getOrNull(requestUserAgent)
            ?: context.headers[HttpHeaders.UserAgent]
            ?: configuredUserAgent(preferencesStore)
        context.attributes.put(requestUserAgent, value)
        context.headers.remove(HttpHeaders.UserAgent)
        if (!value.equals("null", ignoreCase = true)) {
            context.headers.append(HttpHeaders.UserAgent, value)
        }
    }
}
