package io.legado.kmp.shared.network

import io.ktor.http.URLBuilder
import io.ktor.http.encodeURLPathPart
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.scripting.JsResult
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive

private const val CONTENT_TYPE = "Content-Type"


class AnalyzeUrl(
    private val jsExecutor: JsExecutor = JsExecutor.Default,
    private val legacyContext: AnalyzeUrlLegacyContext? = null,
) {

    private val variables = LinkedHashMap<String, UrlVariable>()
    private val writtenVariables = LinkedHashMap<String, String>()

    fun set(name: String, value: Any?, type: VariableType = VariableType.STRING): AnalyzeUrl {
        variables[name] = UrlVariable(name, value, type)
        return this
    }

    fun setString(name: String, value: String?): AnalyzeUrl = set(name, value, VariableType.STRING)

    fun setInt(name: String, value: Int?): AnalyzeUrl = set(name, value, VariableType.INT)

    fun setUrlEncoded(name: String, value: String?): AnalyzeUrl = set(name, value, VariableType.URL_ENCODED)

    fun setVariables(vars: Map<String, Any?>): AnalyzeUrl {
        vars.forEach { (name, value) ->
            when (value) {
                is Int -> setInt(name, value)
                is Long -> set(name, value, VariableType.INT)
                is String -> setString(name, value)
                else -> set(name, value)
            }
        }
        return this
    }

    fun clear(): AnalyzeUrl {
        variables.clear()
        writtenVariables.clear()
        return this
    }

    /**
     * Store a variable in the chain (aligned with original's put/get).
     * Used by JS scripts within URL rules.
     */
    fun put(key: String, value: String) {
        variables[key] = UrlVariable(key, value, VariableType.STRING)
        writtenVariables[key] = value
    }

    // Seeded URL inputs are transient; only script writes belong to the next RuleData.
    fun getWrittenVariables(): Map<String, String> = writtenVariables.toMap()

    /**
     * Get a variable from the chain.
     */
    fun get(key: String): String {
        return variables[key]?.value?.toString() ?: ""
    }

    suspend fun build(urlTemplate: String, baseUrl: String = ""): BuiltUrl {
        val normalizedBaseUrl = splitLegacyUrlOptions(stripUrlOption(baseUrl)).first
        var ruleUrl = analyzeJs(urlTemplate, normalizedBaseUrl)
        ruleUrl = replaceInnerExpressions(ruleUrl, normalizedBaseUrl)
        ruleUrl = replacePageTokens(ruleUrl)

        val (optionRawUrl, optionText) = splitRuleAndOption(ruleUrl)
        val (rawUrl, legacyOption) = splitLegacyUrlOptions(optionRawUrl)
        var absoluteUrl = resolveUrl(normalizedBaseUrl, rawUrl)
        val resolvedBaseUrl = getBaseUrl(absoluteUrl).ifBlank { normalizedBaseUrl }

        val option = mergeUrlOptions(
            legacyOption,
            optionText?.let(::parseUrlOption) ?: ParsedUrlOption()
        ).resolveLegacyOptionAliases()
        val headers = LinkedHashMap<String, String>()
        option?.headers?.let(headers::putAll)

        val urlAfterOptionJs = option?.js?.takeIf { it.isNotBlank() }?.let { script ->
            evalJs(script, resolvedBaseUrl, absoluteUrl, absoluteUrl)
        } ?: absoluteUrl
        absoluteUrl = urlAfterOptionJs

        val charset = option?.charset
        val body = option?.body?.takeIf { it.isNotBlank() }
        val method = option?.method?.uppercase()?.let {
            runCatching { HttpMethod.valueOf(it) }.getOrNull()
        } ?: if (!body.isNullOrBlank()) {
            HttpMethod.POST
        } else {
            HttpMethod.GET
        }

        var urlNoQuery = absoluteUrl
        var encodedQuery: String? = null
        var encodedForm: String? = null

        if (method == HttpMethod.GET) {
            val queryStart = absoluteUrl.indexOf('?')
            if (queryStart >= 0) {
                urlNoQuery = absoluteUrl.substring(0, queryStart)
                encodedQuery = encodeParams(
                    params = absoluteUrl.substring(queryStart + 1),
                    charset = charset,
                    isQuery = true
                )
            }
        } else if (!body.isNullOrBlank() && !body.isJsonOrXmlPayload() && !headers.hasHeader(CONTENT_TYPE)) {
            encodedForm = encodeParams(
                params = body,
                charset = charset,
                isQuery = false
            )
        }

        return BuiltUrl(
            ruleUrl = ruleUrl,
            url = absoluteUrl,
            urlNoQuery = urlNoQuery,
            baseUrl = getBaseUrl(urlNoQuery).ifBlank { resolvedBaseUrl },
            method = method,
            headers = headers,
            body = body,
            encodedForm = encodedForm,
            encodedQuery = encodedQuery,
            rawBody = option?.rawBody ?: false,
            charset = charset,
            retry = option?.retry ?: 0,
            type = option?.type,
            useWebView = option?.useWebView ?: false,
            webJs = option?.webJs,
            sourceRegex = option?.sourceRegex,
            requestJs = option?.js,
            serverId = option?.serverId,
            proxy = option?.proxy,
            webViewDelayTime = (option?.webViewDelayTime ?: 0L).coerceAtLeast(0L),
            usedVariables = variables.mapValues { it.value.value }
        )
    }

    suspend fun buildAbsolute(urlTemplate: String, baseUrl: String): String {
        return build(urlTemplate, baseUrl).url
    }

    private suspend fun analyzeJs(input: String, baseUrl: String): String {
        var start = 0
        var result = input
        val matches = jsPattern.findAll(input).toList()
        for (match in matches) {
            if (match.range.first > start) {
                input.substring(start, match.range.first).trim().takeIf { it.isNotEmpty() }?.let {
                    result = it.replace("@result", result)
                }
            }
            val script = match.groups[1]?.value ?: match.groups[2]?.value.orEmpty()
            result = evalJs(script, baseUrl, result, result)
            start = match.range.last + 1
        }
        if (input.length > start) {
            input.substring(start).trim().takeIf { it.isNotEmpty() }?.let {
                result = it.replace("@result", result)
            }
        }
        return result
    }

    private suspend fun replaceInnerExpressions(input: String, baseUrl: String): String {
        val builder = StringBuilder()
        var index = 0
        while (index < input.length) {
            val start = input.indexOf("{{", index)
            if (start < 0) {
                builder.append(replaceVariableTokens(input.substring(index)))
                break
            }
            builder.append(replaceVariableTokens(input.substring(index, start)))
            val end = findInlineExpressionEnd(input, start)
            if (end < 0) {
                builder.append(replaceVariableTokens(input.substring(start)))
                break
            }
            val expression = input.substring(start + 2, end).trim()
            val inlineResolved = resolveLegacyInlineExpression(expression, baseUrl)
            if (inlineResolved != null) {
                builder.append(inlineResolved)
            } else {
                builder.append(evalInlineJs(expression, baseUrl, builder.toString()))
            }
            index = end + 2
        }
        return builder.toString()
    }

    private fun findInlineExpressionEnd(input: String, start: Int): Int {
        var quote: Char? = null
        var escaped = false
        var depth = 0
        var index = start + 2
        while (index < input.length - 1) {
            val char = input[index]
            if (escaped) {
                escaped = false
                index++
                continue
            }
            if (quote != null) {
                if (char == '\\') {
                    escaped = true
                } else if (char == quote) {
                    quote = null
                }
                index++
                continue
            }
            when (char) {
                '\'', '"', '`' -> quote = char
                '(', '[', '{' -> depth++
                ')', ']', '}' -> {
                    if (char == '}' && depth == 0 && input[index + 1] == '}') {
                        return index
                    }
                    if (depth > 0) depth--
                }
            }
            index++
        }
        return -1
    }

    private fun replaceVariableTokens(text: String): String {
        val replaced = variableTokenPattern.replace(text) { match ->
            val key = match.groups[1]?.value.orEmpty()
            val variable = variables[key] ?: return@replace match.value
            variableToString(variable)
        }
        return applyLegacySearchAliases(replaced)
    }

    private fun applyLegacySearchAliases(text: String): String {
        var output = replaceOutsideLegacyStrings(text) { chunk ->
            legacySearchPageArithmeticPattern.replace(chunk) { match ->
                val variable = variables["searchPage"] ?: variables["page"] ?: return@replace match.value
                val baseValue = variable.value?.toString()?.toIntOrNull() ?: return@replace match.value
                val delta = match.groupValues[2].toIntOrNull() ?: return@replace match.value
                val resolved = if (match.groupValues[1] == "-") {
                    baseValue - delta
                } else {
                    baseValue + delta
                }
                resolved.toString()
            }
        }
        val legacyAliases = listOf(
            "searchKey" to (variables["searchKey"] ?: variables["key"]),
            "searchPage" to (variables["searchPage"] ?: variables["page"])
        )
        for ((name, variable) in legacyAliases) {
            val resolved = variable?.let(::variableToString) ?: continue
            val aliasPattern = Regex("\\b$name\\b")
            output = replaceOutsideLegacyStrings(output) { chunk ->
                aliasPattern.replace(chunk, resolved)
            }
        }
        return output
    }

    private fun replaceOutsideLegacyStrings(text: String, transform: (String) -> String): String {
        val result = StringBuilder(text.length)
        var quote: Char? = null
        var escaped = false
        var chunkStart = 0
        var index = 0
        while (index < text.length) {
            val char = text[index]
            if (escaped) {
                escaped = false
                index++
                continue
            }
            if (quote != null) {
                if (char == '\\') {
                    escaped = true
                } else if (char == quote) {
                    quote = null
                }
                index++
                continue
            }
            if (char == '\'' || char == '"' || char == '`') {
                if (chunkStart < index) {
                    result.append(transform(text.substring(chunkStart, index)))
                }
                val quotedStart = index
                quote = char
                index++
                while (index < text.length && quote != null) {
                    val quotedChar = text[index]
                    if (escaped) {
                        escaped = false
                    } else if (quotedChar == '\\') {
                        escaped = true
                    } else if (quotedChar == quote) {
                        quote = null
                    }
                    index++
                }
                result.append(text.substring(quotedStart, index))
                chunkStart = index
                escaped = false
                continue
            }
            index++
        }
        if (chunkStart < text.length) {
            result.append(transform(text.substring(chunkStart)))
        }
        return result.toString()
    }

    private fun replacePageTokens(input: String): String {
        val page = variables["page"]?.value?.toString()?.toIntOrNull() ?: return input
        return pageTokenPattern.replace(input) { match ->
            val token = match.groupValues[1]
            if (!isLegacyPageToken(token)) {
                match.value
            } else {
                val pages = token.split(",").map { it.trim() }
                val pageIndex = (page - 1).coerceIn(0, pages.lastIndex)
                pages[pageIndex]
            }
        }
    }

    private fun isLegacyPageToken(token: String): Boolean {
        return token.contains(',') &&
                token.none { char ->
                    char.isWhitespace() ||
                            char == '/' ||
                            char == '<' ||
                            char == '>' ||
                            char == '{' ||
                            char == '}' ||
                            char == '"' ||
                            char == '\''
                } &&
                token.split(",").all { it.isNotBlank() }
    }

    private fun resolveLegacyInlineExpression(expression: String, baseUrl: String): String? {
        if (expression.isBlank()) {
            return ""
        }
        val trimmed = expression.trim()

        if (simpleIdentifierPattern.matches(trimmed)) {
            return resolveLegacyVariable(trimmed, baseUrl)?.let(::variableToString) ?: ""
        }

        val arithmetic = legacyArithmeticPattern.matchEntire(trimmed) ?: return null
        val variable = resolveLegacyVariable(arithmetic.groupValues[1], baseUrl) ?: return ""
        val baseValue = variable.value?.toString()?.toIntOrNull() ?: return ""
        val delta = arithmetic.groupValues[3].toIntOrNull() ?: return ""
        val resolved = if (arithmetic.groupValues[2] == "-") {
            baseValue - delta
        } else {
            baseValue + delta
        }
        return resolved.toString()
    }

    private fun resolveLegacyVariable(name: String, baseUrl: String): UrlVariable? {
        return when (name) {
            "searchKey" -> variables["searchKey"] ?: variables["key"]
            "searchPage" -> variables["searchPage"] ?: variables["page"]
            "baseUrl" -> UrlVariable(name = "baseUrl", value = baseUrl)
            else -> variables[name]
        }
    }

    private fun splitRuleAndOption(ruleUrl: String): Pair<String, String?> {
        val delimiter = findUrlOptionDelimiter(ruleUrl) ?: return ruleUrl to null
        return ruleUrl.substring(0, delimiter.first) to ruleUrl.substring(delimiter.second)
    }

    private fun stripUrlOption(url: String): String {
        val delimiter = findUrlOptionDelimiter(url) ?: return url
        return url.substring(0, delimiter.first)
    }

    private fun splitLegacyUrlOptions(ruleUrl: String): Pair<String, ParsedUrlOption> {
        var rawUrl = ruleUrl
        var option = ParsedUrlOption()
        var changed = true
        while (changed) {
            changed = false
            val headerSuffix = findLegacyHeaderSuffix(rawUrl)
            if (headerSuffix != null) {
                rawUrl = rawUrl.substring(0, headerSuffix.first)
                option = option.copy(headers = headerSuffix.second)
                changed = true
                continue
            }
            val charsetMatch = legacyCharsetSuffixPattern.find(rawUrl)
            if (charsetMatch != null) {
                val charset = charsetMatch.groupValues[1].trim().takeIf { it.isNotBlank() }
                rawUrl = rawUrl.substring(0, charsetMatch.range.first)
                option = option.copy(charset = charset)
                changed = true
            }
        }
        val postDelimiter = findLegacyPostDelimiter(rawUrl)
        if (postDelimiter > 0) {
            val body = rawUrl.substring(postDelimiter + 1).trim().takeIf { it.isNotBlank() }
            rawUrl = rawUrl.substring(0, postDelimiter)
            option = option.copy(method = "POST", body = body)
        }
        return rawUrl to option
    }

    private fun findLegacyHeaderSuffix(ruleUrl: String): Pair<Int, Map<String, String>>? {
        val match = legacyHeaderLabelPattern.findAll(ruleUrl).lastOrNull() ?: return null
        val headerJson = normalizeLegacyHeaderJson(ruleUrl.substring(match.range.last + 1))
        if (!isUrlOptionJsonObject(headerJson)) return null
        val headers = parseLegacyHeaderJson(headerJson)
        if (headers.isEmpty()) return null
        return match.range.first to headers
    }

    private fun normalizeLegacyHeaderJson(raw: String): String {
        val trimmed = raw.trim()
        return if (
            trimmed.length >= 2 &&
            (trimmed.first() == '"' || trimmed.first() == '\'') &&
            trimmed.last() == trimmed.first()
        ) {
            trimmed.substring(1, trimmed.lastIndex).trim()
        } else {
            trimmed
        }
    }

    private fun findLegacyPostDelimiter(ruleUrl: String): Int {
        var searchStart = 0
        while (searchStart < ruleUrl.length) {
            val delimiter = ruleUrl.indexOf('@', searchStart)
            if (delimiter < 0) return -1
            if (delimiter > 0 && delimiter < ruleUrl.lastIndex && !isUrlAuthorityAt(ruleUrl, delimiter)) {
                val body = ruleUrl.substring(delimiter + 1).trim()
                if (!body.startsWith("header:", ignoreCase = true) && body.looksLikeLegacyPostBody()) {
                    return delimiter
                }
            }
            searchStart = delimiter + 1
        }
        return -1
    }

    private fun isUrlAuthorityAt(url: String, atIndex: Int): Boolean {
        val schemeIndex = url.indexOf("://")
        if (schemeIndex < 0 || atIndex < schemeIndex + 3) return false
        val authorityStart = schemeIndex + 3
        val authorityEnd = url.indexOfAny(charArrayOf('/', '?', '#'), authorityStart)
            .let { if (it < 0) url.length else it }
        return atIndex < authorityEnd
    }

    private fun mergeUrlOptions(
        legacy: ParsedUrlOption,
        explicit: ParsedUrlOption
    ): ParsedUrlOption {
        val mergedHeaders = LinkedHashMap<String, String>().apply {
            putAllUserAgentAware(legacy.headers)
            putAllUserAgentAware(explicit.headers)
        }
        return explicit.copy(
            method = explicit.method ?: legacy.method,
            charset = explicit.charset ?: legacy.charset,
            headers = mergedHeaders,
            body = explicit.body ?: legacy.body
        )
    }

    private fun ParsedUrlOption.resolveLegacyOptionAliases(): ParsedUrlOption {
        val resolvedHeaders = headers.mapValues { (_, value) ->
            applyLegacyFieldSearchAliases(value)
        }
        return copy(
            headers = resolvedHeaders,
            body = body?.let(::applyLegacyBodySearchAliases)
        )
    }

    private fun applyLegacyBodySearchAliases(body: String): String {
        return replaceLegacyAliasesInJsonText(body) ?: applyLegacyFieldSearchAliases(body)
    }

    private fun replaceLegacyAliasesInJsonText(text: String): String? {
        val trimmed = text.trim()
        if (!trimmed.startsWith("{") && !trimmed.startsWith("[")) return null
        val element = runCatching {
            json.decodeFromString(JsonElement.serializer(), trimmed)
        }.getOrNull() ?: return null
        return replaceLegacyAliasesInJsonElement(element).toString()
    }

    private fun replaceLegacyAliasesInJsonElement(element: JsonElement): JsonElement {
        return when (element) {
            JsonNull -> JsonNull
            is JsonPrimitive -> {
                if (!element.isString) return element
                val content = element.contentOrNull ?: return element
                JsonPrimitive(applyLegacyFieldSearchAliases(content))
            }
            is JsonArray -> JsonArray(element.map(::replaceLegacyAliasesInJsonElement))
            is JsonObject -> JsonObject(element.mapValues { (_, value) ->
                replaceLegacyAliasesInJsonElement(value)
            })
        }
    }

    private fun applyLegacyFieldSearchAliases(text: String): String {
        var output = legacySearchPageArithmeticPattern.replace(text) { match ->
            val variable = variables["searchPage"] ?: variables["page"] ?: return@replace match.value
            val baseValue = variable.value?.toString()?.toIntOrNull() ?: return@replace match.value
            val delta = match.groupValues[2].toIntOrNull() ?: return@replace match.value
            val resolved = if (match.groupValues[1] == "-") {
                baseValue - delta
            } else {
                baseValue + delta
            }
            resolved.toString()
        }
        val legacyAliases = listOf(
            "searchKey" to (variables["searchKey"] ?: variables["key"]),
            "searchPage" to (variables["searchPage"] ?: variables["page"])
        )
        for ((name, variable) in legacyAliases) {
            val resolved = variable?.let(::variableToString) ?: continue
            output = Regex("\\b$name\\b").replace(output, resolved)
        }
        return output
    }

    private fun findUrlOptionDelimiter(text: String): Pair<Int, Int>? {
        var searchStart = 0
        while (searchStart < text.length) {
            val comma = text.indexOf(',', searchStart)
            if (comma < 0) return null
            var optionStart = comma + 1
            while (optionStart < text.length && text[optionStart].isWhitespace()) {
                optionStart++
            }
            if (optionStart < text.length && text[optionStart] == '{') {
                val optionText = text.substring(optionStart)
                if (isUrlOptionJsonObject(optionText)) {
                    var delimiterStart = comma
                    while (delimiterStart > 0 && text[delimiterStart - 1].isWhitespace()) {
                        delimiterStart--
                    }
                    return delimiterStart to optionStart
                }
            }
            searchStart = comma + 1
        }
        return null
    }

    private fun isUrlOptionJsonObject(optionText: String): Boolean {
        return decodeLegacyUrlOptionObject(optionText) != null
    }

    private suspend fun evalJs(script: String, baseUrl: String, result: String?, fallback: String?): String {
        return formatJsResult(
            jsResult = evaluateJs(script, baseUrl, result),
            fallback = fallback,
            inlineWholeNumberCompat = false,
        )
    }

    private suspend fun evalInlineJs(script: String, baseUrl: String, result: String?): String {
        return formatJsResult(
            jsResult = evaluateJs(script, baseUrl, result),
            fallback = null,
            inlineWholeNumberCompat = true,
        )
    }

    private suspend fun evaluateJs(script: String, baseUrl: String, result: String?): JsResult {
        val legacy = executeLegacyJsResult(script, baseUrl, result)
        if (legacy != null) {
            return legacy
        }
        return jsExecutor.execute(
            code = script,
            variables = buildJsVariables(baseUrl, result),
        )
    }

    private fun formatJsResult(
        jsResult: JsResult,
        fallback: String?,
        inlineWholeNumberCompat: Boolean,
    ): String {
        return when (jsResult) {
            is JsResult.JsError -> {
                when (val error = jsResult.exception) {
                    is SharedCapabilityException -> throw error
                    else -> throw IllegalStateException(jsResult.message, error)
                }
            }
            is JsResult.JsNumber -> {
                val value = if (inlineWholeNumberCompat && jsResult.value % 1.0 == 0.0) {
                    jsResult.value.toLong().toString()
                } else {
                    jsResult.value.toString()
                }
                if (value.isNotBlank()) value else (fallback ?: "")
            }
            else -> {
                val value = jsResult.asString()
                if (value.isNotBlank()) value else (fallback ?: "")
            }
        }
    }

    private suspend fun executeLegacyJsResult(
        script: String,
        baseUrl: String,
        result: String?,
        variablesOverride: Map<String, Any?>? = null,
        ruleDataOverride: Map<String, Any?>? = null,
    ): JsResult? {
        val context = legacyContext ?: return null
        val runtime = legacySourceJsRuntime(
            sourceJsRuntime = context.sourceJsRuntime,
            sourceStateStore = context.sourceStateStore,
            cookieRepository = context.cookieRepository
        )
        val effectiveVariables = variablesOverride ?: buildJsVariables(baseUrl, result)
        val effectiveRuleData = ruleDataOverride ?: buildLegacyRuleData(baseUrl, result)
        return runtime.execute(
            script = script,
            source = context.source,
            variables = effectiveVariables,
            connect = { urlRule, headerJson ->
                context.gateway.executeForLegacyJs(
                    urlRule = urlRule,
                    source = context.source,
                    headerJson = headerJson,
                    baseUrl = baseUrl.ifBlank { context.source.bookSourceUrl },
                    ruleData = effectiveRuleData,
                    chapter = context.chapter,
                )
            },
            rawConnect = { urlRule, headerJson ->
                context.gateway.executeForLegacyJsRaw(
                    urlRule = urlRule,
                    source = context.source,
                    headerJson = headerJson,
                    baseUrl = baseUrl.ifBlank { context.source.bookSourceUrl },
                    ruleData = effectiveRuleData,
                    chapter = context.chapter,
                )
            },
            getSourceHeaders = { includeLoginHeader ->
                resolveLegacySourceHeaders(baseUrl, result, includeLoginHeader)
            },
            startBrowser = { url, title ->
                context.gateway.startBrowserForLegacyJs(context.source, url, title)
            },
            startBrowserAwait = { url, title, refetchAfterSuccess ->
                context.gateway.startBrowserAwaitForLegacyJs(context.source, url, title, refetchAfterSuccess)
            },
            getVerificationCode = { imageUrl ->
                context.gateway.getVerificationCodeForLegacyJs(context.source, imageUrl)
            },
            openUrl = { url, mimeType ->
                context.gateway.openUrlForLegacyJs(context.source, url, mimeType)
            },
            webView = { html, url, js ->
                context.gateway.executeWebViewForLegacyJs(
                    source = context.source,
                    url = url,
                    html = html,
                    javaScript = js,
                )
            },
            webViewGetSource = { html, url, js, sourceRegex ->
                context.gateway.executeWebViewForLegacyJs(
                    source = context.source,
                    url = url,
                    html = html,
                    javaScript = js,
                    sourceRegex = sourceRegex,
                )
            },
            webViewGetOverrideUrl = { html, url, js, overrideUrlRegex ->
                context.gateway.executeWebViewForLegacyJs(
                    source = context.source,
                    url = url,
                    html = html,
                    javaScript = js,
                    overrideUrlRegex = overrideUrlRegex,
                )
            },
            readLocalScript = { path ->
                context.gateway.readLocalScriptForLegacyJs(path)
            },
            host = io.legado.kmp.shared.scripting.LegacyJsHostSurface.fromCallbacks(
                source = context.source,
                jsoupExecute = context.gateway::executeJsoupForLegacyJs,
                connect = { urlRule, headerJson ->
                    context.gateway.executeForLegacyJs(
                        urlRule = urlRule,
                        source = context.source,
                        headerJson = headerJson,
                        baseUrl = baseUrl.ifBlank { context.source.bookSourceUrl },
                        ruleData = effectiveRuleData,
                        chapter = context.chapter,
                    )
                },
                rawConnect = { urlRule, headerJson ->
                    context.gateway.executeForLegacyJsRaw(
                        urlRule = urlRule,
                        source = context.source,
                        headerJson = headerJson,
                        baseUrl = baseUrl.ifBlank { context.source.bookSourceUrl },
                        ruleData = effectiveRuleData,
                        chapter = context.chapter,
                    )
                },
                getSourceHeaders = { includeLoginHeader ->
                    resolveLegacySourceHeaders(baseUrl, result, includeLoginHeader)
                },
                startBrowser = { url, title ->
                    context.gateway.startBrowserForLegacyJs(context.source, url, title)
                },
                startBrowserAwait = { url, title, refetchAfterSuccess ->
                    context.gateway.startBrowserAwaitForLegacyJs(context.source, url, title, refetchAfterSuccess)
                },
                getVerificationCode = { imageUrl ->
                    context.gateway.getVerificationCodeForLegacyJs(context.source, imageUrl)
                },
                openUrl = { url, mimeType ->
                    context.gateway.openUrlForLegacyJs(context.source, url, mimeType)
                },
                showToast = { message, long ->
                    context.gateway.showToastForLegacyJs(context.source, message, long)
                },
                webView = { html, url, js ->
                    context.gateway.executeWebViewForLegacyJs(
                        source = context.source,
                        url = url,
                        html = html,
                        javaScript = js,
                    )
                },
                webViewGetSource = { html, url, js, sourceRegex ->
                    context.gateway.executeWebViewForLegacyJs(
                        source = context.source,
                        url = url,
                        html = html,
                        javaScript = js,
                        sourceRegex = sourceRegex,
                    )
                },
                webViewGetOverrideUrl = { html, url, js, overrideUrlRegex ->
                    context.gateway.executeWebViewForLegacyJs(
                        source = context.source,
                        url = url,
                        html = html,
                        javaScript = js,
                        overrideUrlRegex = overrideUrlRegex,
                    )
                },
                readLocalScript = { path ->
                    context.gateway.readLocalScriptForLegacyJs(path)
                },
                downloadFile = { urlRule ->
                    context.gateway.downloadFileForLegacyJs(
                        source = context.source,
                        urlRule = urlRule,
                        baseUrl = baseUrl.ifBlank { context.source.bookSourceUrl },
                        ruleData = effectiveRuleData,
                        chapter = context.chapter,
                    )
                },
                writeHexFile = { contentHex, urlRule ->
                    context.gateway.writeHexFileForLegacyJs(
                        source = context.source,
                        contentHex = contentHex,
                        urlRule = urlRule,
                        baseUrl = baseUrl.ifBlank { context.source.bookSourceUrl },
                        ruleData = effectiveRuleData,
                        chapter = context.chapter,
                    )
                },
                readFile = { path ->
                    context.gateway.readFileForLegacyJs(path)
                },
                readTextFile = { path, charsetName ->
                    context.gateway.readTextFileForLegacyJs(path, charsetName)
                },
                deleteFile = { path ->
                    context.gateway.deleteFileForLegacyJs(path)
                },
                getTextInFolder = { path ->
                    context.gateway.getTextInFolderForLegacyJs(path)
                },
                getZipByteArrayContent = { url, path ->
                    context.gateway.getZipByteArrayContentForLegacyJs(
                        source = context.source,
                        url = url,
                        path = path,
                        baseUrl = baseUrl.ifBlank { context.source.bookSourceUrl },
                        ruleData = effectiveRuleData,
                        chapter = context.chapter,
                    )
                },
                getZipStringContent = { url, path, charsetName ->
                    context.gateway.getZipStringContentForLegacyJs(
                        source = context.source,
                        url = url,
                        path = path,
                        charsetName = charsetName,
                        baseUrl = baseUrl.ifBlank { context.source.bookSourceUrl },
                        ruleData = effectiveRuleData,
                        chapter = context.chapter,
                    )
                },
                legacyGet = { key ->
                    get(key)
                },
                legacyPut = { key, value ->
                    put(key, value ?: "")
                },
                legacyDelete = { key ->
                    put(key, "")
                },
            ),
        )
    }

    private fun buildLegacyRuleData(baseUrl: String, result: String?): Map<String, Any?> {
        val context = legacyContext ?: return buildJsVariables(baseUrl, result)
        return linkedMapOf<String, Any?>().apply {
            putAll(context.ruleData)
            putAll(buildJsVariables(baseUrl, result))
        }
    }

    private suspend fun buildLegacyHeaderVariables(baseUrl: String, result: String?): Map<String, Any?> {
        val context = legacyContext ?: return buildJsVariables(baseUrl, result)
        val sourceKey = context.source.bookSourceUrl
        return linkedMapOf<String, Any?>().apply {
            putAll(context.ruleData)
            putAll(buildJsVariables(baseUrl, result))
            put("url", result?.takeIf { it.isNotBlank() } ?: baseUrl.ifBlank { sourceKey })
            put("sourceVariable", context.sourceStateStore?.getSourceVariable(sourceKey))
            put("sourceVariableMap", context.sourceStateStore?.getSourceVariableMap(sourceKey).orEmpty())
            remove("source")
        }
    }

    private suspend fun resolveLegacySourceHeaders(
        baseUrl: String,
        result: String?,
        includeLoginHeader: Boolean,
    ): Map<String, String> {
        val context = legacyContext ?: return emptyMap()
        val source = context.source
        val headerRule = source.header?.trim().orEmpty()
        val headerVariables = if (
            headerRule.startsWith("@js:", ignoreCase = true) ||
            headerRule.startsWith("<js>", ignoreCase = true)
        ) {
            buildLegacyHeaderVariables(baseUrl, result)
        } else {
            emptyMap()
        }
        val resolved = when {
            headerRule.isBlank() -> emptyMap()
            headerRule.startsWith("@js:", ignoreCase = true) -> {
                parseLegacyHeaderJson(
                    formatJsResult(
                        jsResult = executeLegacyJsResult(
                            script = headerRule.substring(4).trim(),
                            baseUrl = baseUrl,
                            result = result,
                            variablesOverride = headerVariables,
                            ruleDataOverride = headerVariables,
                        ) ?: return emptyMap(),
                        fallback = "",
                        inlineWholeNumberCompat = false,
                    ),
                )
            }
            headerRule.startsWith("<js>", ignoreCase = true) && headerRule.endsWith("</js>", ignoreCase = true) -> {
                parseLegacyHeaderJson(
                    formatJsResult(
                        jsResult = executeLegacyJsResult(
                            script = headerRule.substring(4, headerRule.length - 5).trim(),
                            baseUrl = baseUrl,
                            result = result,
                            variablesOverride = headerVariables,
                            ruleDataOverride = headerVariables,
                        ) ?: return emptyMap(),
                        fallback = "",
                        inlineWholeNumberCompat = false,
                    ),
                )
            }
            else -> parseLegacyHeaderJson(headerRule)
        }
        return LinkedHashMap<String, String>().apply {
            putAllUserAgentAware(resolved)
            putDefaultUserAgent { context.gateway.defaultUserAgent() }
            if (includeLoginHeader) {
                putAllUserAgentAware(context.sourceStateStore?.getLoginHeaderMap(source.bookSourceUrl).orEmpty())
            }
        }
    }

    private fun parseLegacyHeaderJson(content: String): Map<String, String> {
        val trimmed = content.trim()
        if (!trimmed.startsWith("{")) return emptyMap()
        return runCatching {
            val root = json.parseToJsonElement(trimmed) as? JsonObject ?: return emptyMap()
            root.entries.mapNotNull { (key, value) ->
                value.jsonPrimitive.contentOrNull?.let { key to it }
            }.toMap(LinkedHashMap())
        }.getOrElse { emptyMap() }
    }

    private fun buildJsVariables(baseUrl: String, result: String?): Map<String, Any?> {
        val jsVars = LinkedHashMap<String, Any?>()
        variables.forEach { (name, variable) ->
            jsVars[name] = variable.value
        }
        jsVars["baseUrl"] = baseUrl
        jsVars["result"] = result
        return jsVars
    }

    private fun parseUrlOption(optionText: String): ParsedUrlOption {
        val obj = decodeLegacyUrlOptionObject(optionText) ?: return ParsedUrlOption()
        return ParsedUrlOption(
            method = obj.urlOptionString("method"),
            charset = obj.urlOptionString("charset"),
            headers = obj.urlOptionMap("headers", "header"),
            body = obj.urlOptionValueToString("body"),
            rawBody = obj.urlOptionBooleanLike("rawBody"),
            retry = obj.urlOptionIntLike("retry") ?: 0,
            type = obj.urlOptionString("type"),
            useWebView = obj.urlOptionBooleanLike("webView", "useWebView"),
            webJs = obj.urlOptionString("webJs"),
            sourceRegex = obj.urlOptionString("sourceRegex"),
            js = obj.urlOptionString("js"),
            serverId = obj.urlOptionLongLike("serverID", "serverId"),
            proxy = obj.urlOptionString("proxy"),
            webViewDelayTime = obj.urlOptionLongLike("webViewDelayTime", "webViewDelay")
        )
    }

    private fun encodeParams(params: String, charset: String?, isQuery: Boolean): String =
        encodeLegacyUrlParameters(params, charset, isQuery)

    private fun variableToString(variable: UrlVariable): String {
        val value = variable.value ?: return ""
        return when (variable.type) {
            VariableType.STRING,
            VariableType.INT -> value.toString()
            VariableType.URL_ENCODED,
            VariableType.URL_COMPONENT -> value.toString().encodeURLPathPart()
        }
    }

    companion object {
        private val json = Json {
            ignoreUnknownKeys = true
            isLenient = true
        }
        private val dataUriPattern = Regex("^data:([^;]*);base64,(.*)$")
        val paramPattern = Regex("\\s*,\\s*(?=\\{)")
        private val pageTokenPattern = Regex("<(.*?)>")
        private val variableTokenPattern = Regex("\\$\\{([^}]+)\\}")
        private val jsPattern = Regex("(?is)<js>(.*?)</js>|@js:([\\w\\W]*)")
        private val simpleIdentifierPattern = Regex("[A-Za-z_][A-Za-z0-9_]*")
        private val legacyArithmeticPattern = Regex("([A-Za-z_][A-Za-z0-9_]*)\\s*([+-])\\s*(\\d+)")
        private val legacySearchPageArithmeticPattern = Regex("\\bsearchPage\\s*([+-])\\s*(\\d+)\\b")
        private val legacyCharsetSuffixPattern = Regex("""\|\s*(?:char|charset)\s*=\s*([^|,]+)\s*$""", RegexOption.IGNORE_CASE)
        private val legacyHeaderLabelPattern = Regex("""@\s*headers?\s*:\s*""", RegexOption.IGNORE_CASE)
        suspend fun build(
            urlTemplate: String,
            block: suspend AnalyzeUrl.() -> Unit
        ): BuiltUrl {
            val analyzer = AnalyzeUrl()
            block(analyzer)
            return analyzer.build(urlTemplate)
        }

        suspend fun build(
            urlTemplate: String,
            baseUrl: String,
            block: suspend AnalyzeUrl.() -> Unit
        ): BuiltUrl {
            val analyzer = AnalyzeUrl()
            block(analyzer)
            return analyzer.build(urlTemplate, baseUrl)
        }

        fun buildQuick(
            urlTemplate: String,
            variables: Map<String, Any?>
        ): String {
            val analyzer = AnalyzeUrl()
            analyzer.setVariables(variables)
            return analyzer.replaceVariableTokens(urlTemplate)
        }

        fun join(base: String, relative: String): String {
            return resolveLegacyNetworkUrl(base, relative)
        }

        fun getBaseUrl(url: String): String {
            return try {
                val builder = URLBuilder(url)
                val defaultPort = builder.protocol.defaultPort
                val portSuffix = if (builder.port == defaultPort || builder.port == 0) "" else ":${builder.port}"
                "${builder.protocol.name}://${builder.host}$portSuffix"
            } catch (_: Throwable) {
                ""
            }
        }

        fun getPath(url: String): String {
            return try {
                URLBuilder(url).build().encodedPath
            } catch (_: Throwable) {
                "/"
            }
        }

        private fun resolveUrl(baseUrl: String, ruleUrl: String): String {
            if (ruleUrl.startsWith("http://") || ruleUrl.startsWith("https://")) return ruleUrl
            if (baseUrl.isBlank()) return ruleUrl
            return join(baseUrl, ruleUrl)
        }

        /**
         * Parse data: URI and base64-decode the payload.
         * Returns null if the URL is not a data URI.
         */
        @OptIn(kotlin.io.encoding.ExperimentalEncodingApi::class)
        fun getByteArrayIfDataUri(url: String): ByteArray? {
            val match = dataUriPattern.find(url) ?: return null
            val base64Data = match.groupValues[2]
            return runCatching {
                kotlin.io.encoding.Base64.decode(base64Data)
            }.getOrNull()
        }

        /**
         * Patch XML response body that's missing XML declaration.
         * Some servers return XML content-type but omit the declaration.
         */
        fun patchXmlDeclaration(body: String, contentType: String?): String {
            if (contentType == null) return body
            if (!contentType.contains("xml", ignoreCase = true)) return body
            val trimmed = body.trimStart()
            if (trimmed.startsWith("<?xml", ignoreCase = true)) return body
            if (trimmed.startsWith("<")) {
                return "<?xml version=\"1.0\"?>\n$body"
            }
            return body
        }
    }
}


private fun String.isJsonOrXmlPayload(): Boolean {
    val trimmed = trim()
    return (trimmed.startsWith("{") && trimmed.endsWith("}")) ||
        (trimmed.startsWith("[") && trimmed.endsWith("]")) ||
        (trimmed.startsWith("<") && trimmed.endsWith(">"))
}

private fun String.looksLikeLegacyPostBody(): Boolean {
    val trimmed = trim()
    if (trimmed.isJsonOrXmlPayload()) return true
    val equalsIndex = trimmed.indexOf('=')
    if (equalsIndex <= 0) return false
    val key = trimmed.substring(0, equalsIndex).trim()
    if (key.isEmpty()) return false
    return key.none { it == '&' || it == '?' || it == '#' || it == '/' }
}

private fun Map<String, String>.hasHeader(name: String): Boolean {
    return keys.any { it.equals(name, ignoreCase = true) }
}

private fun MutableMap<String, String>.setHeaderIfMissing(name: String, value: String) {
    if (!hasHeader(name)) {
        this[name] = value
    }
}


suspend fun String.buildUrl(
    baseUrl: String = "",
    block: suspend AnalyzeUrl.() -> Unit = {}
): BuiltUrl {
    return AnalyzeUrl.build(this, baseUrl, block)
}

fun String.buildUrlWithVariables(variables: Map<String, Any?>): String {
    return AnalyzeUrl.buildQuick(this, variables)
}

fun String.joinUrl(relative: String): String {
    return AnalyzeUrl.join(this, relative)
}

object UrlVars {
    const val BOOK_NAME = "bookName"
    const val AUTHOR = "author"
    const val CHAPTER_INDEX = "chapterIndex"
    const val PAGE = "page"
    const val KEYWORD = "key"
    const val QUERY = "query"
    const val PAGE_SIZE = "pageSize"
}

fun buildMultipartUploadParts(
    body: String?,
    fileName: String,
    fileData: ByteArray,
    contentType: String
): List<MultipartUploadPart> = buildAnalyzeUrlMultipartParts(body, fileName, fileData, contentType)
