package io.legado.kmp.shared.domain.usecase

import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.network.AnalyzeUrl
import io.legado.kmp.shared.network.JsExecutor
import io.legado.kmp.shared.network.LegacyJsConnectGateway
import io.legado.kmp.shared.network.resolveLegacyNetworkUrl
import io.legado.kmp.shared.scripting.JsResult
import io.legado.kmp.shared.scripting.LegacyJsHostSurface
import io.legado.kmp.shared.scripting.LegacySourceJsLibrarySupport
import io.legado.kmp.shared.scripting.LegacySourceJsRuntime
import io.legado.kmp.shared.scripting.SourceJsRuntime
import io.legado.kmp.shared.source.SourceStateStore
import io.ktor.http.Url
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlin.coroutines.cancellation.CancellationException

sealed interface LoginAction {
    data object None : LoginAction
    data class WebView(val url: String) : LoginAction
    data class JsExecuted(val loginHeader: String?) : LoginAction
}

class ExecuteLoginUrlUseCase(
    private val sourceStateStore: SourceStateStore,
    private val connectGateway: LegacyJsConnectGateway,
    private val sourceJsRuntime: SourceJsRuntime? = null,
    private val jsExecutor: JsExecutor = JsExecutor.Default
) {
    private val librarySupport = LegacySourceJsLibrarySupport(sourceStateStore)

    suspend operator fun invoke(source: BookSource): Result<LoginAction> = loginResult {
        val loginUrl = source.loginUrl?.trim().orEmpty()
        if (loginUrl.isBlank()) {
            return@loginResult LoginAction.None
        }

        if (isJsLoginRule(loginUrl)) {
            executeFormLogin(source).getOrThrow()
        } else {
            val absoluteUrl = AnalyzeUrl(jsExecutor).buildAbsolute(loginUrl, source.bookSourceUrl)
            LoginAction.WebView(absoluteUrl)
        }
    }

    // Loading a login screen must not evaluate loginUrl, including embedded URL-rule JavaScript.
    fun webLoginUrl(source: BookSource): String? {
        val rule = source.loginUrl?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        if (isJsLoginRule(rule)) return null
        val absolute = resolveLegacyNetworkUrl(source.bookSourceUrl, rule)
        val url = Url(absolute)
        require(url.protocol.name in listOf("http", "https") && url.host.isNotBlank())
        require(url.user.isNullOrEmpty() && url.password.isNullOrEmpty())
        return absolute
    }

    internal suspend fun executeFormLogin(
        source: BookSource,
        values: Map<String, String> = emptyMap(),
        headers: suspend (Boolean) -> Map<String, String> = { emptyMap() },
    ): Result<LoginAction> = loginResult {
        val loginScript = extractLoginScript(source.loginUrl.orEmpty())
        if (loginScript.isBlank()) return@loginResult LoginAction.None
        val result = evaluateScript(
            source,
            "$loginScript\n;if (typeof login === 'function') { login.apply(this); } " +
                "else { throw new Error('Login function unavailable'); }",
            mapOf("result" to values),
            headers,
        )
        check(result !is JsResult.JsBoolean || result.value) { "Source login was rejected" }
        LoginAction.JsExecuted(sourceStateStore.getLoginHeader(source.bookSourceUrl))
    }

    internal suspend fun executeFormAction(
        source: BookSource,
        action: String,
        values: Map<String, String>,
        headers: suspend (Boolean) -> Map<String, String> = { emptyMap() },
    ): Result<LoginAction> = loginResult {
        evaluateScript(
            source,
            "${extractLoginScript(source.loginUrl.orEmpty())}\n;$action",
            mapOf("result" to values),
            headers,
            allowLogin = true,
        )
        LoginAction.JsExecuted(sourceStateStore.getLoginHeader(source.bookSourceUrl))
    }

    internal suspend fun evaluateScript(
        source: BookSource,
        script: String,
        variables: Map<String, Any?> = emptyMap(),
        headers: suspend (Boolean) -> Map<String, String> = { emptyMap() },
        allowLogin: Boolean = false,
    ): JsResult {
        val requestContext = currentCoroutineContext()
        requestContext.ensureActive()
        suspend fun <T> inRequest(block: suspend () -> T): T {
            requestContext.ensureActive()
            val value = block()
            requestContext.ensureActive()
            return value
        }
        val runtime = sourceJsRuntime ?: LegacySourceJsRuntime(sourceStateStore)
        val libraryHost = LegacyJsHostSurface.fromCallbacks(
            source = source,
            connect = { url, header -> inRequest { connectGateway.executeForLegacyJs(url, source, header) } },
            jsoupExecute = { requestJson -> inRequest { connectGateway.executeJsoupForLegacyJs(requestJson) } },
        )
        val library = source.jsLib?.takeIf { it.isNotBlank() }
            ?.let { librarySupport.load(it, source.bookSourceUrl, libraryHost) }.orEmpty()
        // Install before jsLib too: library initialization can inspect saved credentials and call java.log.
        val privateSource = source.copy(jsLib = """
            ;(function() {
              var silent = function(value) { return value; };
              Object.defineProperty(globalThis, '__legacyLog', { value: silent, writable: false, configurable: false });
              if (typeof console === 'object' && console) {
                ['log', 'debug', 'info', 'warn', 'error', 'trace'].forEach(function(key) { console[key] = silent; });
              }
            })();
        """.trimIndent() + "\n" + library)
        val result = runtime.execute(
            script = script,
            source = privateSource,
            variables = variables,
            connect = { urlRule, headerJson ->
                inRequest {
                    connectGateway.executeForLegacyJs(
                        urlRule, source, headerJson, source.bookSourceUrl, variables,
                    )
                }
            },
            rawConnect = { urlRule, headerJson ->
                inRequest {
                    connectGateway.executeForLegacyJsRaw(
                        urlRule, source, headerJson, source.bookSourceUrl, variables,
                    )
                }
            },
            // A button can explicitly call source.login(); it still sees saved loginInfo, not unsaved inputs.
            login = {
                check(allowLogin) { "Recursive login is unavailable" }
                inRequest { executeFormLogin(source, headers = headers).getOrThrow() }
            },
            getSourceHeaders = { includeLoginHeader -> inRequest { headers(includeLoginHeader) } },
            webViewUserAgent = { inRequest { connectGateway.defaultUserAgent() } },
            startBrowser = { url, title -> inRequest { connectGateway.startBrowserForLegacyJs(source, url, title) } },
            startBrowserAwait = { url, title, refetch ->
                inRequest { connectGateway.startBrowserAwaitForLegacyJs(source, url, title, refetch) }
            },
            getVerificationCode = { image -> inRequest { connectGateway.getVerificationCodeForLegacyJs(source, image) } },
            openUrl = { url, mimeType -> inRequest { connectGateway.openUrlForLegacyJs(source, url, mimeType) } },
            webView = { html, url, js -> inRequest { connectGateway.executeWebViewForLegacyJs(source, url, html, js) } },
            webViewGetSource = { html, url, js, regex ->
                inRequest { connectGateway.executeWebViewForLegacyJs(source, url, html, js, sourceRegex = regex) }
            },
            webViewGetOverrideUrl = { html, url, js, regex ->
                inRequest { connectGateway.executeWebViewForLegacyJs(source, url, html, js, overrideUrlRegex = regex) }
            },
            readLocalScript = { path -> inRequest { connectGateway.readLocalScriptForLegacyJs(path) } },
            host = libraryHost,
        )
        currentCoroutineContext().ensureActive()
        if (result is JsResult.JsError) {
            (result.exception as? CancellationException)?.let { throw it }
            // A script exception can include passwords, response bodies or tokens. Never retain its cause.
            throw IllegalStateException("Source login script failed")
        }
        return result
    }

    private suspend fun <T> loginResult(block: suspend () -> T): Result<T> {
        return try {
            currentCoroutineContext().ensureActive()
            val result = block()
            currentCoroutineContext().ensureActive()
            Result.success(result)
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            Result.failure(IllegalStateException("Source login execution failed"))
        }
    }

    private fun isJsLoginRule(loginUrl: String): Boolean {
        val trimmed = loginUrl.trim()
        if (trimmed.startsWith("@js:", ignoreCase = true) || trimmed.startsWith("<js>", ignoreCase = true)) {
            return true
        }
        if (trimmed.startsWith("http://", ignoreCase = true) ||
            trimmed.startsWith("https://", ignoreCase = true) ||
            trimmed.startsWith("/", ignoreCase = true)
        ) {
            return false
        }
        return trimmed.contains('\n') ||
            trimmed.contains("function") ||
            trimmed.contains("var ") ||
            trimmed.contains("source.") ||
            trimmed.contains("java.")
    }

    private fun extractLoginScript(loginUrl: String): String {
        val trimmed = loginUrl.trim()
        return when {
            trimmed.startsWith("@js:", ignoreCase = true) -> trimmed.substring(4).trim()
            trimmed.startsWith("<js>", ignoreCase = true) &&
                trimmed.endsWith("</js>", ignoreCase = true) -> {
                trimmed.substring(4, trimmed.length - 5).trim()
            }
            else -> trimmed
        }
    }
}
