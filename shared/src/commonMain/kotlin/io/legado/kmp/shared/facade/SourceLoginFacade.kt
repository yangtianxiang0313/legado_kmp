package io.legado.kmp.shared.facade

import io.legado.kmp.shared.domain.repository.CookieRepository
import io.legado.kmp.shared.domain.repository.RssSourceRepository
import io.legado.kmp.shared.domain.rss.asBookSourceShim
import io.legado.kmp.shared.domain.usecase.ExecuteLoginUrlUseCase
import io.legado.kmp.shared.domain.usecase.GetBookSourcesUseCase
import io.legado.kmp.shared.domain.usecase.LoginAction
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.model.StoredHttpCookie
import io.legado.kmp.shared.model.CookieHostSnapshot
import io.legado.kmp.shared.network.SourceHeaderResolver
import io.legado.kmp.shared.scripting.JsResult
import io.legado.kmp.shared.source.SourceStateStore
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlin.coroutines.cancellation.CancellationException

class SourceLoginFacade private constructor(
    private val getBookSourcesUseCase: GetBookSourcesUseCase,
    private val sourceStateStore: SourceStateStore,
    private val executeLoginUrlUseCase: ExecuteLoginUrlUseCase,
    private val sourceHeaderResolver: SourceHeaderResolver,
    private val cookieRepository: CookieRepository,
    private val rssSourceRepository: RssSourceRepository,
    private val rssSource: Boolean,
) {
    constructor(
        getBookSourcesUseCase: GetBookSourcesUseCase,
        sourceStateStore: SourceStateStore,
        executeLoginUrlUseCase: ExecuteLoginUrlUseCase,
        sourceHeaderResolver: SourceHeaderResolver,
        cookieRepository: CookieRepository,
        rssSourceRepository: RssSourceRepository,
    ) : this(
        getBookSourcesUseCase,
        sourceStateStore,
        executeLoginUrlUseCase,
        sourceHeaderResolver,
        cookieRepository,
        rssSourceRepository,
        rssSource = false,
    )

    fun forRssSources(): SourceLoginFacade = if (rssSource) this else SourceLoginFacade(
        getBookSourcesUseCase,
        sourceStateStore,
        executeLoginUrlUseCase,
        sourceHeaderResolver,
        cookieRepository,
        rssSourceRepository,
        rssSource = true,
    )

    fun loadRequest(sourceUrl: String, onResult: (SourceLoginRequestResult) -> Unit): FlowSubscription =
        SourceLoginRequest.start("loadRequest", { SourceLoginRequestResult(configuration = load(sourceUrl), completed = true) }, onResult)

    fun submitRequest(sourceUrl: String, valuesJson: String, onResult: (SourceLoginRequestResult) -> Unit): FlowSubscription =
        SourceLoginRequest.start("submitRequest", {
            SourceLoginRequestResult(loginResult = submit(sourceUrl, valuesJson), completed = true)
        }, onResult)

    fun runActionRequest(
        sourceUrl: String,
        rowIndex: Int,
        valuesJson: String,
        onResult: (SourceLoginRequestResult) -> Unit,
    ): FlowSubscription = SourceLoginRequest.start("runActionRequest", {
        SourceLoginRequestResult(loginResult = runAction(sourceUrl, rowIndex, valuesJson), completed = true)
    }, onResult)

    fun loadCookiesRequest(
        sourceUrl: String,
        targetUrl: String,
        onResult: (SourceLoginRequestResult) -> Unit,
    ): FlowSubscription = SourceLoginRequest.start("loadCookiesRequest", {
        SourceLoginRequestResult(cookies = loadCookies(sourceUrl, targetUrl), completed = true)
    }, onResult)

    fun saveCookiesRequest(
        sourceUrl: String,
        cookies: List<StoredHttpCookie>,
        onResult: (SourceLoginRequestResult) -> Unit,
    ): FlowSubscription {
        val snapshot = cookies.toList()
        return SourceLoginRequest.start("saveCookiesRequest", {
            saveCookies(sourceUrl, snapshot)
            SourceLoginRequestResult(completed = true)
        }, onResult)
    }

    fun loadLoginHeaderRequest(sourceUrl: String, onResult: (SourceLoginRequestResult) -> Unit): FlowSubscription =
        SourceLoginRequest.start("loadLoginHeaderRequest", {
            SourceLoginRequestResult(loginHeader = loadLoginHeader(sourceUrl), completed = true)
        }, onResult)

    fun loadWebCookieSeedRequest(
        sourceUrl: String, targetUrl: String, onResult: (SourceLoginRequestResult) -> Unit,
    ): FlowSubscription = SourceLoginRequest.start("loadWebCookieSeedRequest", {
        SourceLoginRequestResult(cookieSeed = loadWebCookieSeed(sourceUrl, targetUrl), completed = true)
    }, onResult)

    fun saveWebCookiesRequest(
        sourceUrl: String, snapshots: List<CookieHostSnapshot>, onResult: (SourceLoginRequestResult) -> Unit,
    ): FlowSubscription {
        val captured = snapshots.map { it.copy(cookies = it.cookies.toList()) }
        return SourceLoginRequest.start("saveWebCookiesRequest", {
            saveWebCookies(sourceUrl, captured)
            SourceLoginRequestResult(completed = true)
        }, onResult)
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun loadWebCookieSeed(sourceUrl: String, targetUrl: String): SourceLoginCookieSeed = operation("loadWebCookieSeed") {
        source(sourceUrl)
        SourceLoginWebCookies(cookieRepository).seed(targetUrl)
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun saveWebCookies(sourceUrl: String, snapshots: List<CookieHostSnapshot>): Unit = operation("saveWebCookies") {
        source(sourceUrl)
        SourceLoginWebCookies(cookieRepository).save(snapshots)
    }

    fun clearLoginHeaderRequest(sourceUrl: String, onResult: (SourceLoginRequestResult) -> Unit): FlowSubscription =
        SourceLoginRequest.start("clearLoginHeaderRequest", {
            clearLoginHeader(sourceUrl)
            SourceLoginRequestResult(completed = true)
        }, onResult)

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun load(sourceUrl: String): SourceLoginConfiguration = operation("load") {
        val source = source(sourceUrl)
        val hasForm = !source.loginUi.isNullOrBlank()
        val rows = SourceLoginFormCodec.rows(source.loginUi)
        val saved = sourceStateStore.getLoginInfoMap(source.bookSourceUrl).orEmpty()
        val values = rows.filter { it.type == "text" || it.type == "password" }
            .associate { it.name to saved[it.name].orEmpty() }
        SourceLoginConfiguration(
            name = source.bookSourceName,
            webUrl = if (hasForm) null else executeLoginUrlUseCase.webLoginUrl(source),
            rows = rows,
            valuesJson = SourceLoginFormCodec.encode(values),
            headersJson = SourceLoginFormCodec.encode(headers(source, includeLoginHeader = true)),
            hasForm = hasForm,
        )
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun submit(sourceUrl: String, valuesJson: String): SourceLoginResult = operation("submit") {
        val source = source(sourceUrl)
        require(!source.loginUi.isNullOrBlank()) { "Login form unavailable" }
        val values = SourceLoginFormCodec.values(SourceLoginFormCodec.rows(source.loginUi), valuesJson)
        currentCoroutineContext().ensureActive()
        if (values.isEmpty()) {
            sourceStateStore.removeLoginInfo(source.bookSourceUrl)
            return@operation SourceLoginResult()
        }
        val saved = sourceStateStore.putLoginInfo(source.bookSourceUrl, SourceLoginFormCodec.encode(values))
        currentCoroutineContext().ensureActive()
        check(saved) {
            "Secure login storage unavailable"
        }
        currentCoroutineContext().ensureActive()
        executeLoginUrlUseCase.executeFormLogin(source, values) { headers(source, it) }
            .getOrThrow().toLoginResult()
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun runAction(sourceUrl: String, rowIndex: Int, valuesJson: String): SourceLoginResult = operation("runAction") {
        val source = source(sourceUrl)
        val rows = SourceLoginFormCodec.rows(source.loginUi)
        val row = rows.getOrNull(rowIndex) ?: throw IllegalArgumentException("Login row unavailable")
        require(row.type == "button") { "Not a login button" }
        val values = SourceLoginFormCodec.values(rows, valuesJson)
        val action = row.action?.trim()?.takeIf { it.isNotEmpty() } ?: return@operation SourceLoginResult()
        if (action.startsWith("http://", true) || action.startsWith("https://", true)) {
            // URL actions are navigation, not authentication and not a reason to persist unsaved fields.
            SourceLoginCookieScope(action)
            return@operation SourceLoginResult(webUrl = action)
        }
        executeLoginUrlUseCase.executeFormAction(source, action, values) { headers(source, it) }
            .getOrThrow().toLoginResult()
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun loadCookies(sourceUrl: String, targetUrl: String): List<StoredHttpCookie> = operation("loadCookies") {
        val source = source(sourceUrl)
        val scope = SourceLoginCookieScope(source.bookSourceUrl)
        val targetHost = scope.relatedTargetHost(targetUrl) ?: return@operation emptyList()
        cookieRepository.getCookiesForHost(targetUrl).filter { scope.accepts(it, targetHost) }
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun saveCookies(sourceUrl: String, cookies: List<StoredHttpCookie>): Unit = operation("saveCookies") {
        val source = source(sourceUrl)
        val scope = SourceLoginCookieScope(source.bookSourceUrl)
        val snapshot = cookies.toList().filter { scope.accepts(it) }
        currentCoroutineContext().ensureActive()
        cookieRepository.replaceCookiesForHost(source.bookSourceUrl, snapshot, persistSession = true)
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun loadLoginHeader(sourceUrl: String): String? = operation("loadLoginHeader") {
        val source = source(sourceUrl)
        sourceStateStore.getLoginHeader(source.bookSourceUrl)
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun clearLoginHeader(sourceUrl: String): Unit = operation("clearLoginHeader") {
        val source = source(sourceUrl)
        sourceStateStore.removeLoginHeader(source.bookSourceUrl)
    }

    private suspend fun source(sourceUrl: String): BookSource {
        val key = sourceUrl.trim()
        // Source kind is explicit: an identical URL must never select a row from the other repository.
        return if (rssSource) {
            rssSourceRepository.getByKey(key)?.asBookSourceShim()
                ?: throw IllegalArgumentException("RSS source unavailable")
        } else {
            getBookSourcesUseCase.getByUrl(key) ?: throw IllegalArgumentException("Book source unavailable")
        }
    }

    private suspend fun headers(source: BookSource, includeLoginHeader: Boolean): Map<String, String> {
        val rule = source.header?.trim().orEmpty()
        val script = when {
            rule.startsWith("@js:", true) -> rule.substring(4)
            rule.startsWith("<js>", true) -> rule.substring(4, rule.lastIndexOf("</js>", ignoreCase = true).takeIf { it >= 4 } ?: rule.length)
            else -> null
        }
        val resolved = if (script == null) {
            sourceHeaderResolver.resolve(source.header).toMutableMap()
        } else {
            when (val value = executeLoginUrlUseCase.evaluateScript(source, script)) {
                is JsResult.JsObject -> value.value.mapValues { (_, entry) ->
                    entry as? String ?: throw IllegalArgumentException("Invalid source header")
                }.toMutableMap()
                is JsResult.JsString -> {
                    val root = Json.parseToJsonElement(value.value) as? JsonObject
                        ?: throw IllegalArgumentException("Invalid source headers")
                    root.mapValues { (_, entry) ->
                        (entry as? JsonPrimitive)?.content ?: throw IllegalArgumentException("Invalid source header")
                    }.toMutableMap()
                }
                else -> throw IllegalArgumentException("Invalid source headers")
            }
        }
        if (includeLoginHeader) {
            sourceStateStore.getLoginHeaderMap(source.bookSourceUrl).orEmpty().forEach { (name, value) ->
                resolved.keys.firstOrNull { it.equals(name, true) }?.let { resolved.remove(it) }
                resolved[name] = value
            }
        }
        if (resolved.keys.none { it.equals("User-Agent", true) }) {
            resolved["User-Agent"] = sourceHeaderResolver.defaultUserAgent()
        }
        return resolved
    }

    private fun LoginAction.toLoginResult(): SourceLoginResult = when (this) {
        LoginAction.None -> SourceLoginResult()
        is LoginAction.JsExecuted -> SourceLoginResult(loginHeader = loginHeader, executedJs = true)
        is LoginAction.WebView -> SourceLoginResult(webUrl = url)
    }

    // Do not use runRecoverable: its CrashCollector records raw exceptions, potentially containing credentials.
    private suspend fun <T> operation(name: String, block: suspend () -> T): T {
        return try {
            currentCoroutineContext().ensureActive()
            val result = block()
            currentCoroutineContext().ensureActive()
            result
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            throw RecoverableSharedException("SourceLoginFacade.$name", "书源登录操作失败，请检查登录配置后重试")
        }
    }
}
