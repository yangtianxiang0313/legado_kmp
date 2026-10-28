package io.legado.kmp.shared.analyze

import io.legado.kmp.shared.analyze.parser.CssRuleParser
import io.legado.kmp.shared.analyze.parser.JsRuleParser
import io.legado.kmp.shared.analyze.parser.RegexRuleParser
import io.legado.kmp.shared.analyze.parser.XPathParser
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.network.HttpUseCase
import io.legado.kmp.shared.network.HtmlParser
import io.legado.kmp.shared.network.JsExecutor
import io.legado.kmp.shared.network.LegacyJsConnectGateway
import io.legado.kmp.shared.network.SourceHeaderResolver
import io.legado.kmp.shared.source.SourceStateStore
import io.legado.kmp.shared.scripting.SourceJsRuntime
import io.legado.kmp.shared.util.unescapeHtml4
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.Json

private data class RuleCacheKey(
    val rule: String,
    val isJson: Boolean,
    val isRegex: Boolean
)

private data class LegacyGetReplacement(
    val value: String,
    val endIndex: Int
)

/**
 * Rule data interface
 * Provides context for rule evaluation with variable storage
 */
interface RuleDataInterface {
    val bookSource: BookSource?

    /**
     * Variable storage map
     */
    val variableMap: MutableMap<kotlin.String, kotlin.String>

    /**
     * Store a variable.
     * Aligned with legado's RuleDataInterface.putVariable:
     * - null: remove from both variableMap and big variable
     * - value.length < 10000: store in variableMap, clear big variable
     * - value.length >= 10000: store as big variable, remove from variableMap
     */
    fun putVariable(key: kotlin.String, value: kotlin.String?): kotlin.Boolean {
        val keyExist = variableMap.contains(key)
        return when {
            value == null -> {
                variableMap.remove(key)
                putBigVariable(key, null)
                keyExist
            }
            value.length < 10000 -> {
                putBigVariable(key, null)
                variableMap[key] = value
                true
            }
            else -> {
                variableMap.remove(key)
                putBigVariable(key, value)
                keyExist
            }
        }
    }

    /**
     * Store a big variable (values >= 10000 chars).
     * Transient RuleData stores the original key, as Android RuleData does.
     * Aligned with legado's RuleDataInterface.putBigVariable.
     */
    fun putBigVariable(key: kotlin.String, value: kotlin.String?) {
        if (value == null) {
            variableMap.remove(key)
        } else {
            variableMap[key] = value
        }
    }

    /**
     * Get a big variable.
     * Transient values are already in variableMap; model-backed implementations read persistence.
     * Aligned with legado's RuleDataInterface.getBigVariable.
     */
    fun getBigVariable(key: kotlin.String): kotlin.String? {
        return null
    }

    /**
     * Get a variable.
     * Aligned with legado: checks variableMap first, then big variable.
     * Returns empty string (not null) to match legado RuleDataInterface.getVariable().
     */
    fun getVariable(key: kotlin.String): kotlin.String =
        variableMap[key] ?: getBigVariable(key) ?: ""

    /**
     * Get all variables
     */
    fun getVariables(): Map<kotlin.String, kotlin.String> = variableMap.toMap()

    /**
     * Serialize the variable map to a JSON string for persistence.
     * Aligned with legado's variable JSON serialization (D3).
     */
    fun getVariableJson(): kotlin.String =
        io.legado.kmp.shared.model.serializeVariableMap(variableMap.toMap())
}

/**
 * Simple rule data implementation
 */
class SimpleRuleData(
    override val bookSource: BookSource? = null,
    initialVariables: Map<kotlin.String, kotlin.String> = emptyMap()
) : RuleDataInterface {
    override val variableMap: MutableMap<kotlin.String, kotlin.String> = mutableMapOf()
    init {
        variableMap.putAll(initialVariables)
    }
}

/**
 * Rule type enum
 */
enum class RuleType {
    CSS,        // CSS selector (@css:, or default)
    XPATH,      // XPath expression (@xpath:, or starts with /)
    JSONPATH,   // JSONPath ($. or @json:)
    REGEX,      // Regular expression (##)
    JS,         // JavaScript (@js: or <js>)
    JSON,       // JSON processing (@json:)
}

/**
 * AnalyzeRule engine
 * Core rule parsing and evaluation engine for Legado
 *
 * Supports:
 * - CSS/XPath selectors (via ksoup)
 * - Regular expressions
 * - JSONPath
 * - JavaScript expressions
 * - Rule chains (@@, &&, ||)
 * - Variable system (@get:{key}, @put:{key,value})
 * - Nested rules ({{js}}, {$rule})
 */
class AnalyzeRule(
    private val source: BookSource? = null,
    private val sourceStateStore: SourceStateStore? = null,
    private val httpUseCase: HttpUseCase = HttpUseCase(),
    private val htmlParser: HtmlParser = HtmlParser(),
    private val jsExecutor: JsExecutor = JsExecutor.Default,
    private val connectGateway: LegacyJsConnectGateway? = null,
    private val headerResolver: SourceHeaderResolver? = null,
    private val sourceJsRuntime: SourceJsRuntime? = null,
    private val legacyReGetBook: (suspend () -> Book)? = null,
    private val legacyRefreshTocUrl: (suspend () -> Book)? = null
) {
    private val pipelineSupport = AnalyzeRulePipelineSupport(
        getContent = { content },
        getBaseUrl = { baseUrl },
        getCssParser = ::getCssParser,
        getRegexParser = ::getRegexParser,
        getJsonPathParser = ::getJsonPathParser,
        getXPathParser = ::getXPathParser,
        splitSourceRule = { splitSourceRule(it) },
        splitSourceRuleForContent = ::splitSourceRuleForContent,
        applyPutMap = ::applyPutMap,
        resolveLegacySourceRule = ::resolveLegacySourceRule,
        parseJsRule = ::parseJsRule
    )

    private val structuredJson = Json {
        ignoreUnknownKeys = true
        isLenient = true
    }

    private var content: Any? = null
    private var baseUrl: kotlin.String? = null
    private var redirectUrl: kotlin.String? = null
    private var isJSON: kotlin.Boolean = false
    private var isRegex: kotlin.Boolean = false
    private var ruleData: RuleDataInterface? = null
    private var currentBook: Book? = null
    private var currentChapter: BookChapter? = null
    private var nextChapterUrl: kotlin.String? = null
    private var bigVariableSupport = AnalyzeRuleBigVariableSupport(source, sourceStateStore)

    /**
     * Flag to avoid repeated warnings for non-standard JSON in @put rules.
     * Aligned with legado AnalyzeRule.loggedNonStandardJSON.
     */
    private var loggedNonStandardJSON: kotlin.Boolean = false

    private val variables: MutableMap<kotlin.String, kotlin.String> = mutableMapOf()
    private val stringRuleCache = hashMapOf<RuleCacheKey, List<SourceRule>>()
    private var cssParser: CssRuleParser? = null
    private var regexParser: RegexRuleParser? = null
    private val jsonPathSupport = AnalyzeRuleJsonSupport { content }
    private var xPathParser: XPathParser? = null
    private var jsParser: JsRuleParser? = null
    private val jsContextBindings: MutableMap<String, Any?> = mutableMapOf()
    private val legacyJsSupport = AnalyzeRuleLegacyJsSupport(
        analyzeRule = this,
        source = source,
        sourceStateStore = sourceStateStore,
        jsExecutor = jsExecutor,
        connectGateway = connectGateway,
        headerResolver = headerResolver,
        sourceJsRuntime = sourceJsRuntime,
        jsContextBindings = jsContextBindings,
        getBaseUrl = { baseUrl },
        getRedirectUrl = { redirectUrl },
        getCurrentChapter = { currentChapter },
        copyVariablesTo = { bindings ->
            bindings.putAll(getVariables())
        },
        legacyReGetBook = legacyReGetBook,
        legacyRefreshTocUrl = legacyRefreshTocUrl
    )

    /**
     * Set content for analysis
     */
    fun setContent(content: Any?, baseUrl: kotlin.String? = null): AnalyzeRule {
        if (content == null) {
            throw IllegalArgumentException("Content cannot be null")
        }
        this.content = content
        isJSON = isContentJson(content)
        this.baseUrl = baseUrl
        if (baseUrl == null) {
            jsContextBindings.remove("baseUrl")
        } else {
            jsContextBindings["baseUrl"] = baseUrl
        }
        cssParser = null
        regexParser = null
        jsonPathSupport.reset()
        xPathParser = null
        jsParser = null
        return this
    }

    /**
     * Check if content is JSON.
     * Aligned with legado: Node/Element types always return false,
     * otherwise calls isJson() which checks trimmed start AND end characters.
     */
    private fun isContentJson(content: Any?): kotlin.Boolean {
        return when (content) {
            is com.fleeksoft.ksoup.nodes.Node -> false
            is com.fleeksoft.ksoup.select.Elements -> false
            is JsonObject, is JsonArray, is Map<*, *> -> true
            is AnalyzeJsArrayValues, is AnalyzeJsonArrayValues -> true
            is List<*> -> content.none { it is com.fleeksoft.ksoup.nodes.Node } &&
                content.toString().isJsonContent()
            else -> content?.toString()?.isJsonContent() ?: false
        }
    }

    /**
     * Aligned with legado's String?.isJson(): checks that trimmed string
     * starts with { and ends with }, or starts with [ and ends with ].
     */
    private fun kotlin.String.isJsonContent(): kotlin.Boolean {
        val str = this.trim()
        return when {
            str.startsWith("{") && str.endsWith("}") -> true
            str.startsWith("[") && str.endsWith("]") -> true
            else -> false
        }
    }

    /**
     * Set base URL
     */
    fun setBaseUrl(url: kotlin.String?): AnalyzeRule {
        baseUrl = url
        if (url == null) {
            jsContextBindings.remove("baseUrl")
        } else {
            jsContextBindings["baseUrl"] = url
        }
        return this
    }

    /**
     * Set redirect URL for URL resolution
     * Aligned with original's setRedirectUrl(url: String): URL?
     */
    fun setRedirectUrl(url: kotlin.String): AnalyzeRule {
        redirectUrl = url
        return this
    }

    fun setBookContext(book: Book?): AnalyzeRule {
        currentBook = book
        bigVariableSupport.setBook(book, ruleData?.getVariables())
        if (book == null) {
            jsContextBindings.remove("book")
        } else {
            jsContextBindings["book"] = linkedMapOf<String, Any?>(
                "bookUrl" to book.bookUrl,
                "tocUrl" to book.tocUrl,
                "name" to book.name,
                "author" to book.author,
                "kind" to book.kind,
                "coverUrl" to book.displayCoverUrl,
                "intro" to book.displayIntro,
                "wordCount" to book.wordCount,
                "latestChapterTitle" to book.latestChapterTitle,
                "origin" to book.origin,
                "originName" to book.originName,
                "originOrder" to book.originOrder,
                "type" to book.type,
                "totalChapterNum" to book.totalChapterNum,
                "variable" to book.variableMap
            )
        }
        return this
    }

    fun setRuleData(ruleData: RuleDataInterface?): AnalyzeRule {
        if (this.ruleData !== ruleData) {
            bigVariableSupport.reset()
            bigVariableSupport.setBook(currentBook)
            bigVariableSupport.setChapter(currentChapter)
        }
        this.ruleData = ruleData
        return this
    }

    fun setChapterContext(chapter: BookChapter?): AnalyzeRule {
        currentChapter = chapter
        bigVariableSupport.setChapter(chapter)
        if (chapter == null) {
            jsContextBindings.remove("chapter")
        } else {
            jsContextBindings["chapter"] = linkedMapOf<String, Any?>(
                "index" to chapter.index,
                "title" to chapter.title,
                "url" to chapter.url,
                "baseUrl" to chapter.baseUrl,
                "bookUrl" to chapter.bookUrl,
                "variable" to chapter.variableMap
            )
        }
        return this
    }

    fun getBookContext(): Book? = currentBook?.let { book ->
        bigVariableSupport.bookVariables?.let { book.copy(variable = io.legado.kmp.shared.model.serializeVariableMap(it)) }
            ?: book
    }

    internal fun prepareVariableBindings(context: kotlin.coroutines.CoroutineContext): kotlin.String {
        bigVariableSupport.executionContext = context
        return bigVariableSupport.bindingPreamble()
    }

    internal fun inheritBookVariableState(parent: AnalyzeRule) {
        bigVariableSupport.inheritBookState(parent.bigVariableSupport)
    }

    fun setNextChapterUrl(url: kotlin.String?): AnalyzeRule {
        nextChapterUrl = url
        if (url == null) {
            jsContextBindings.remove("nextChapterUrl")
        } else {
            jsContextBindings["nextChapterUrl"] = url
        }
        return this
    }

    // ==================== Variable System ====================

    /**
     * Store a variable.
     * Returns the value (matching original's return type).
     *
     * Aligned with original legado: put flows through chapter -> book -> ruleData -> source.
     * Immutable model snapshots retain small values; large values are persisted outside their JSON.
     */
    fun put(key: kotlin.String, value: kotlin.String?): kotlin.String {
        val v = value ?: ""
        if (bigVariableSupport.putBindingValue(key, value)) {
            if (currentChapter == null && currentBook != null) {
                ruleData?.variableMap?.let { map ->
                    map.clear()
                    map.putAll(bigVariableSupport.activeData?.getVariables().orEmpty())
                }
            }
            return v
        }
        val scopedData = bigVariableSupport.activeData
        if (scopedData != null) {
            scopedData.putVariable(key, value)
            variables.remove(key)
            if (currentChapter == null) {
                // Search parsing still exports the explicit RuleData supplied by its caller.
                ruleData?.variableMap?.let { map ->
                    map.remove("__big__$key")
                    if (value == null || value.length >= 10000) map.remove(key) else map[key] = value
                }
            }
        } else if (ruleData != null) {
            ruleData?.putVariable(key, value)
        } else {
            if (value == null) variables.remove(key) else variables[key] = value
        }
        sourceStateKey()?.takeIf { currentChapter == null && currentBook == null && ruleData == null }?.let { sourceKey ->
            // BaseSource.put/get already persist arbitrary source cache values independently.
            runBlocking {
                sourceStateStore?.putStoredValue(sourceKey, key, value)
            }
        }
        return v
    }

    /**
     * Get a variable.
     * Aligned with original's get(): uses isNotEmpty() instead of isNotBlank(),
     * checks local variables -> chapter -> book chain.
     */
    fun getVariable(key: kotlin.String): kotlin.String? {
        bigVariableSupport.getBindingValue(key)?.let { return it }
        when (key) {
            "bookName" -> currentBook?.let { return it.name }
            "title" -> currentChapter?.let { return it.title }
            "loginHeader" -> sourceStateKey()?.let { sourceKey ->
                return runBlocking { sourceStateStore?.getLoginHeader(sourceKey) }?.takeIf { it.isNotEmpty() }
            }
            "sourceVariable" -> sourceStateKey()?.let { sourceKey ->
                return runBlocking { sourceStateStore?.getSourceVariable(sourceKey) }?.takeIf { it.isNotEmpty() }
            }
        }
        return variables[key]?.takeIf { it.isNotEmpty() }
            ?: bigVariableSupport.getChapterVariable(key)?.takeIf { it.isNotEmpty() }
            ?: bigVariableSupport.getBookVariable(key)?.takeIf { it.isNotEmpty() }
            ?: ruleData?.takeIf { bigVariableSupport.activeData == null }
                ?.getVariable(key)?.takeIf { it.isNotEmpty() }
            ?: getStoredSourceValue(key)?.takeIf { it.isNotEmpty() }
            ?: bigVariableSupport.getSourceBigVariable(key)?.takeIf { it.isNotEmpty() }
            ?: when (key) {
                "nextChapterUrl" -> nextChapterUrl
                "baseUrl" -> baseUrl
                "result" -> when (val current = content) {
                    null -> null
                    is String -> current
                    else -> current.toString()
                }
                else -> null
            }
    }

    /**
     * Get all variables
     */
    fun getVariables(): Map<kotlin.String, kotlin.String> = buildMap {
        ruleData?.takeIf { bigVariableSupport.activeData == null }?.getVariables()?.forEach { (key, value) ->
            put(key, value)
        }
        variables.forEach { (key, value) ->
            put(key, value)
        }
        putAll(bigVariableSupport.bindingVariables())
    }

    private fun sourceStateKey(): kotlin.String? = source?.bookSourceUrl?.takeIf { it.isNotBlank() }

    private fun getStoredSourceValue(key: kotlin.String): kotlin.String? {
        val sourceKey = sourceStateKey() ?: return null
        return runBlocking {
            sourceStateStore?.getStoredValue(sourceKey, key)
        }
    }

    // ==================== Core Parsing Methods ====================

    /**
     * Get string result from rule with explicit unescape parameter.
     * Aligned with legado's getString(ruleStr, unescape) 2-arg overload.
     * This avoids Java/JVM interop issues with default parameters.
     */
    suspend fun getString(rule: kotlin.String?, unescape: kotlin.Boolean): kotlin.String {
        return getString(rule, mContent = null, isUrl = false, unescape = unescape)
    }

    /**
     * Get string result from rule.
     *
     * @param rule Rule string
     * @param mContent Optional override content (used by BookList for per-item parsing)
     * @param isUrl Whether to resolve as URL
     * @param unescape Whether to apply HTML entity unescaping (default true, matching original)
     */
    suspend fun getString(
        rule: kotlin.String?,
        mContent: Any? = null,
        isUrl: kotlin.Boolean = false,
        unescape: kotlin.Boolean = true
    ): kotlin.String {
        if (rule.isNullOrBlank()) {
            return if (isUrl) baseUrl ?: "" else ""
        }
        val parsed = parseStringResult(rule, mContent)
        if (isUrl) {
            return AnalyzeRuleUrlSupport.getString(parsed, baseUrl, redirectUrl, unescape)
        }
        val resultStr = parsed.asString()
        return if (unescape && '&' in resultStr) {
            unescapeHtml4(resultStr)
        } else {
            resultStr
        }
    }

    internal suspend fun getUrlWithoutFallback(rule: kotlin.String): kotlin.String {
        if (rule.isBlank()) return ""
        return AnalyzeRuleUrlSupport.getString(
            parseStringResult(rule, null), baseUrl, redirectUrl, unescape = true, fallbackToBase = false
        )
    }

    private suspend fun parseStringResult(rule: kotlin.String, mContent: Any?): AnalyzeResult {
        val chainRules = splitRuleChain(rule, "@@")
        return if (chainRules.size > 1) {
            parseStringRuleChain(chainRules, mContent, JsonPathResultMode.STRING)
        } else {
            pipelineSupport.parseWithRuleList(splitSourceRuleCacheString(rule), mContent, JsonPathResultMode.STRING)
        }
    }

    /**
     * Get string list result from rule.
     *
     * @param rule Rule string
     * @param mContent Optional override content
     * @param isUrl Whether to resolve as URLs
     */
    suspend fun getStringList(
        rule: kotlin.String?,
        mContent: Any? = null,
        isUrl: kotlin.Boolean = false
    ): List<kotlin.String> {
        if (rule.isNullOrBlank()) {
            return emptyList()
        }
        val chainRules = splitRuleChain(rule, "@@")
        val parsed = if (chainRules.size > 1) {
            parseStringRuleChain(chainRules, mContent, JsonPathResultMode.STRING_LIST)
        } else {
            val ruleList = splitSourceRuleCacheString(rule)
            pipelineSupport.parseWithRuleList(ruleList, mContent, JsonPathResultMode.STRING_LIST)
        }
        if (isUrl) {
            return AnalyzeRuleUrlSupport.getStringList(parsed, baseUrl, redirectUrl)
        }
        // Aligned with original: if result is a single String, split by "\n" into list
        return when (parsed) {
            is AnalyzeResult.StringList -> parsed.values
            is AnalyzeResult.StringVal -> parsed.value.split("\n")
            is AnalyzeResult.Elements -> parsed.values.map { it.toString() }
            else -> emptyList()
        }
    }

    /**
     * Get elements from rule (returns list of element objects).
     * Aligned with original: uses splitSourceRule(ruleStr, allInOne=true) for rule splitting,
     * supporting @put maps and Regex element mode.
     */
    suspend fun getElements(rule: kotlin.String?): List<Any> {
        if (rule.isNullOrBlank()) {
            return content?.let { listOf(it) } ?: emptyList()
        }

        val chainRules = splitRuleChain(rule, "@@")
        var result: Any? = content
        for (rulePart in chainRules) {
            result = pipelineSupport.parseElementsFrom(rulePart, result)
            if (result == null) {
                return emptyList()
            }
        }
        return rawToElementList(result)
    }

    /**
     * Get single element from rule
     */
    suspend fun getElement(rule: kotlin.String?): Any? {
        if (rule.isNullOrBlank()) {
            return content
        }
        val ruleList = splitSourceRule(rule, allInOne = true)
        if (
            ruleList.size == 1 &&
            ruleList.first().type == RuleType.REGEX &&
            ruleList.first().replaceRegex.isEmpty()
        ) {
            val regs = splitRegexRules(ruleList.first().cleanRule)
            if (regs.isNotEmpty()) {
                return getRegexParser().getElement(content?.toString().orEmpty(), regs)
            }
        }
        val chainRules = splitRuleChain(rule, "@@")
        if (chainRules.size > 1) {
            return parseElementRuleChain(chainRules)
        }
        if (rule.contains("@put:", ignoreCase = true) ||
            rule.contains("@get:", ignoreCase = true) ||
            rule.contains("{{")
        ) {
            return when (val result = parse(rule)) {
                is AnalyzeResult.Elements -> result.values.unwrapLegacySingleElement()
                is AnalyzeResult.StringVal -> result.value.takeIf { it.isNotBlank() } ?: content
                is AnalyzeResult.StringList -> result.values.unwrapLegacySingleElement()
                is AnalyzeResult.IntVal -> result.value
                is AnalyzeResult.LongVal -> result.value
                is AnalyzeResult.FloatVal -> result.value
                is AnalyzeResult.BoolVal -> result.value
                is AnalyzeResult.Null -> null
            }
        }
        return parseElementRuleChain(chainRules)
    }

    private suspend fun parseElementRuleChain(chainRules: List<kotlin.String>): Any? {
        var result: Any? = content
        for (rule in chainRules) {
            result = pipelineSupport.parseElementsFrom(rule, result, singleElement = true)
            if (result == null) {
                return null
            }
        }
        return if (result is List<*>) result.unwrapLegacySingleElement() else result
    }

    private fun List<*>.unwrapLegacySingleElement(): Any? {
        if (isStructuredArray() || legacyHtmlResultKind(this) == LegacyHtmlResultKind.ELEMENTS) return this
        return when (size) {
            0 -> null
            1 -> first()
            else -> this
        }
    }

    private suspend fun parseStringRuleChain(
        chainRules: List<kotlin.String>,
        initialContent: Any?,
        resultMode: JsonPathResultMode
    ): AnalyzeResult {
        if (chainRules.isEmpty()) return AnalyzeResult.Null
        var current: Any? = initialContent ?: content
        for (index in 0 until chainRules.lastIndex) {
            current = pipelineSupport.parseElementsFrom(chainRules[index], current)
            if (current == null) {
                return AnalyzeResult.Null
            }
        }
        val finalRule = chainRules.lastOrNull().orEmpty()
        val ruleList = splitSourceRuleForContent(finalRule, current)
        return pipelineSupport.parseWithRuleList(ruleList, current, resultMode)
    }

    private fun splitSourceRuleForContent(
        rule: kotlin.String?,
        ruleContent: Any?,
        allInOne: kotlin.Boolean = false
    ): List<SourceRule> {
        val oldIsJson = isJSON
        val oldIsRegex = isRegex
        if (ruleContent != null) {
            isJSON = isContentJson(ruleContent)
        }
        return try {
            splitSourceRule(rule, allInOne = allInOne)
        } finally {
            isJSON = oldIsJson
            isRegex = oldIsRegex
        }
    }

    @Suppress("UNCHECKED_CAST")
    private fun rawToElementList(value: Any?): List<Any> {
        return when (value) {
            null -> emptyList()
            is AnalyzeJsArrayValues -> value
            is AnalyzeJsonArrayValues -> value
            is JsonArray -> AnalyzeJsonArrayValues(value)
            is List<*> -> value.filterNotNull() as List<Any>
            else -> listOf(value)
        }
    }

    // ==================== Rule Caching ====================

    /**
     * Cache-aware rule splitting for getString/getStringList
     * Aligned with original's splitSourceRuleCacheString
     */
    fun splitSourceRuleCacheString(ruleStr: kotlin.String?): List<SourceRule> {
        if (ruleStr.isNullOrEmpty()) return emptyList()
        val cacheKey = RuleCacheKey(
            rule = ruleStr,
            isJson = isJSON,
            isRegex = isRegex
        )
        return stringRuleCache.getOrPut(cacheKey) {
            splitSourceRule(ruleStr)
        }
    }

    /**
     * Split rule string into SourceRule list.
     * Aligned with original's splitSourceRule(ruleStr, allInOne).
     *
     * @param ruleStr Rule string to split
     * @param allInOne When true and rule starts with ":", enables Regex mode
     */
    fun splitSourceRule(ruleStr: kotlin.String?, allInOne: kotlin.Boolean = false): List<SourceRule> {
        if (ruleStr.isNullOrEmpty()) return emptyList()
        var start = 0
        var defaultType = RuleType.CSS

        // allInOne mode: colon prefix sets Regex mode
        if (allInOne && ruleStr.startsWith(":")) {
            defaultType = RuleType.REGEX
            isRegex = true
            start = 1
        } else if (isRegex) {
            defaultType = RuleType.REGEX
        }
        // Aligned with original legado AnalyzeRule line 568:
        // isJSON || ruleStr.startsWith("$.") || ruleStr.startsWith("$[")
        // JSON content takes precedence over slash XPath inference, but not explicit prefixes.
        if (isJSON && defaultType == RuleType.CSS) {
            defaultType = RuleType.JSONPATH
        }

        val result = mutableListOf<SourceRule>()
        val matches = findLegacyJsRuleMatches(ruleStr, start)

        for (match in matches) {
            if (match.startIndex > start) {
                val plainRule = ruleStr.substring(start, match.startIndex).trim()
                if (plainRule.isNotEmpty()) {
                    result += parseSourceRuleWithDefaultType(plainRule, defaultType)
                }
            }
            val jsRule = match.script
            if (jsRule.isNotBlank()) {
                result += SourceRule(
                    rule = "@js:${jsRule.trim()}",
                    type = RuleType.JS,
                    rawRule = jsRule.trim()
                )
            }
            start = match.endIndex
        }

        if (ruleStr.length > start) {
            val tailRule = ruleStr.substring(start).trim()
            if (tailRule.isNotEmpty()) {
                result += parseSourceRuleWithDefaultType(tailRule, defaultType)
            }
        }

        return result
    }

    /**
     * Apply regex mode first, then explicit prefixes, then JSON content before slash XPath inference.
     */
    private fun parseSourceRuleWithDefaultType(ruleStr: kotlin.String, defaultType: RuleType): SourceRule {
        val parsed = SourceRule.parse(ruleStr)
        val type = when {
            defaultType == RuleType.REGEX || parsed.type == RuleType.REGEX -> RuleType.REGEX
            ruleStr.startsWith("@CSS:", ignoreCase = true) || ruleStr.startsWith("@@") -> RuleType.CSS
            ruleStr.startsWith("@XPath:", ignoreCase = true) ||
                ruleStr.startsWith("@Json:", ignoreCase = true) ||
                parsed.type == RuleType.JS -> parsed.type
            defaultType == RuleType.JSONPATH -> RuleType.JSONPATH
            else -> parsed.type
        }
        return if (type == parsed.type) parsed else parsed.copy(type = type)
    }

    // ==================== Rule Parsing ====================

    /**
     * Parse rule and return result
     */
    private suspend fun parse(rule: kotlin.String): AnalyzeResult {
        if (rule.isBlank()) {
            return AnalyzeResult.Null
        }

        // Split rule chain before variable replacement so @get values containing @@ stay literal.
        val rules = splitRuleChain(rule, "@@")
        if (rules.isEmpty()) {
            return AnalyzeResult.Null
        }

        var currentResult = analyzeResultFromRaw(content)
        var currentInput = content

        for ((index, rulePart) in rules.withIndex()) {
            currentResult = pipelineSupport.parseSingleRule(
                rulePart.trim(), currentResult, JsonPathResultMode.RAW, currentInput
            )
            if (currentResult is AnalyzeResult.Null && index < rules.size - 1) {
                break
            }
            currentInput = currentResult.jsonPathRawInput()
        }

        return currentResult
    }

    private suspend fun parseJsRule(rule: kotlin.String, previousResult: AnalyzeResult): AnalyzeResult {
        val contextObj = previousResult.asString()
        if (shouldUseLegacyJsRuntime()) {
            return legacyJsSupport.execute(rule, contextObj, previousResult)
        }
        val parser = getJsParser()
        parser.setVariables(variables)
        val result = parser.evaluate(rule, contextObj, baseUrl, legacyJsSupport.buildTransientBindings(previousResult))
        parser.getCustomBindings().forEach { (key, value) ->
            put(
                key,
                when (value) {
                    null -> null
                    is String -> value
                    else -> value.toString()
                }
            )
        }
        return result
    }

    private fun shouldUseLegacyJsRuntime(): kotlin.Boolean {
        return source != null
    }

    // ==================== Helper Methods ====================

    /**
     * Replace variable placeholders in rule
     */
    private fun replaceVariables(rule: kotlin.String): kotlin.String {
        if (!rule.contains("@get:", ignoreCase = true)) return rule
        val result = StringBuilder()
        var index = 0
        while (index < rule.length) {
            val replacement = readLegacyGetReplacement(rule, index)
            if (replacement == null) {
                result.append(rule[index])
                index++
            } else {
                result.append(replacement.value)
                index = replacement.endIndex
            }
        }
        return result.toString()
    }

    private fun readLegacyGetReplacement(rule: kotlin.String, startIndex: Int): LegacyGetReplacement? {
        val wrapperStartLength = when {
            rule.startsWith("{{", startIndex) -> 2
            rule[startIndex] == '{' && (startIndex == 0 || rule[startIndex - 1] != '{') -> 1
            else -> 0
        }
        val getStart = startIndex + wrapperStartLength
        if (!rule.regionMatches(getStart, "@get:{", 0, 6, ignoreCase = true)) {
            return null
        }
        val keyStart = getStart + 6
        val keyEnd = rule.indexOf('}', keyStart)
        if (keyEnd < 0) return null
        val expectedSuffix = when (wrapperStartLength) {
            2 -> "}}"
            1 -> "}"
            else -> ""
        }
        val suffixStart = keyEnd + 1
        if (expectedSuffix.isNotEmpty() && !rule.startsWith(expectedSuffix, suffixStart)) {
            return null
        }
        val key = rule.substring(keyStart, keyEnd)
        if ('{' in key) return null
        val value = getVariable(key)
            ?: key.trim().takeIf { it != key }?.let { getVariable(it) }
            ?: ""
        return LegacyGetReplacement(
            value = value,
            endIndex = suffixStart + expectedSuffix.length
        )
    }

    private suspend fun applyPutMap(putMap: Map<kotlin.String, kotlin.String>) {
        putMap.forEach { (key, valueRule) ->
            val resolvedKey = replaceVariables(key)
            if (resolvedKey.isEmpty()) return@forEach
            val resolvedValue = if (shouldEvaluatePutValue(valueRule)) {
                evaluateAuxiliaryRule(valueRule)
            } else {
                valueRule
            }
            put(resolvedKey, resolvedValue)
        }
    }

    private fun shouldEvaluatePutValue(valueRule: kotlin.String): kotlin.Boolean {
        val trimmed = valueRule.trim()
        if (trimmed.isEmpty()) return false
        return trimmed.contains("@get:", ignoreCase = true) ||
            trimmed.contains("{{") ||
            trimmed.contains("<js>", ignoreCase = true) ||
            trimmed.startsWith("@js:", ignoreCase = true) ||
            isNestedRuleExpression(trimmed)
    }

    private suspend fun resolveLegacySourceRule(
        sourceRule: SourceRule,
        previousResult: AnalyzeResult
    ): SourceRule {
        var resolved = replaceVariables(sourceRule.rule)
        resolved = replaceLegacyRegexRefs(resolved, previousResult)
        resolved = replaceLegacyInlineExpressions(resolved, previousResult)
        return sourceRule.copy(rule = resolved)
    }

    /**
     * Replace $N regex group references in rule text.
     * Aligned with legado's makeUpRule regType > 0 behavior:
     * - $N where N > 0 indexes into the previous result list
     * - Only replaced when previous result is actually a List with size > N
     * - If result is not a list or index out of bounds, the $N token stays as-is
     */
    private fun replaceLegacyRegexRefs(
        rule: kotlin.String,
        previousResult: AnalyzeResult
    ): kotlin.String {
        if (!rule.contains('$')) return rule
        val values: List<String?> = when (previousResult) {
            is AnalyzeResult.StringList -> previousResult.values
            is AnalyzeResult.Elements -> previousResult.values.map { it.toString() }
            else -> return rule // legado only replaces $N when result is a List
        }
        if (values.isEmpty()) return rule
        return regexGroupRefPattern.replace(rule) { match ->
            val index = match.groupValues[1].toIntOrNull() ?: return@replace match.value
            if (index > 0 && values.size > index) {
                values[index] ?: match.value
            } else {
                match.value
            }
        }
    }

    private suspend fun replaceLegacyInlineExpressions(
        rule: kotlin.String,
        previousResult: AnalyzeResult
    ): kotlin.String {
        if (!rule.contains("{{") || !rule.contains("}}")) {
            return rule
        }
        val builder = StringBuilder()
        var cursor = 0
        while (cursor < rule.length) {
            val start = rule.indexOf("{{", cursor)
            if (start < 0) {
                builder.append(rule.substring(cursor))
                break
            }
            builder.append(rule.substring(cursor, start))
            val end = findLegacyInlineExpressionEnd(rule, start)
            if (end < 0) {
                builder.append(rule.substring(start))
                break
            }
            val expression = rule.substring(start + 2, end).trim()
            val replacement = when {
                expression.isBlank() -> ""
                isNestedRuleExpression(expression) -> evaluateAuxiliaryRule(expression, previousResult)
                else -> resolveLegacyInlineScopeExpression(expression, previousResult)
                    ?: parseJsRule(expression, previousResult).asString()
            }
            builder.append(replacement)
            cursor = end + 2
        }
        return builder.toString()
    }

    private fun resolveLegacyInlineScopeExpression(
        expression: kotlin.String,
        previousResult: AnalyzeResult
    ): kotlin.String? {
        val trimmed = expression.trim()
        if (!legacyInlineScopePattern.matches(trimmed)) {
            return null
        }
        val segments = trimmed.split('.')
        if (segments.isEmpty()) {
            return null
        }
        val scope = buildLegacyInlineScope(previousResult)
        var current: Any? = scope[segments.first()]
        if (segments.size == 1) {
            return when (current) {
                null -> getVariable(segments.first()) ?: ""
                else -> current.toString()
            }
        }
        for (segment in segments.drop(1)) {
            current = when (current) {
                null -> return ""
                is Map<*, *> -> current[segment]
                else -> return ""
            }
        }
        return current?.toString().orEmpty()
    }

    private fun buildLegacyInlineScope(previousResult: AnalyzeResult): Map<String, Any?> {
        val contentValue = previousResult.asString()
        val sourceMap = source?.let { legacySource ->
            linkedMapOf<String, Any?>(
                "key" to legacySource.bookSourceUrl,
                "tag" to legacySource.bookSourceName,
                "bookSourceUrl" to legacySource.bookSourceUrl,
                "bookSourceName" to legacySource.bookSourceName,
                "bookSourceGroup" to legacySource.bookSourceGroup,
                "loginUrl" to legacySource.loginUrl,
                "loginUi" to legacySource.loginUi,
                "loginCheckJs" to legacySource.loginCheckJs,
                "header" to legacySource.header,
                "enabledCookieJar" to legacySource.enabledCookieJar,
                "customOrder" to legacySource.customOrder
            )
        }
        return linkedMapOf<String, Any?>().apply {
            put("result", contentValue)
            put("body", contentValue)
            put("src", contentValue)
            put("baseUrl", baseUrl ?: "")
            put("nextChapterUrl", nextChapterUrl ?: "")
            put("book", jsContextBindings["book"])
            put("chapter", jsContextBindings["chapter"])
            put("source", sourceMap)
        }
    }

    private suspend fun evaluateAuxiliaryRule(
        rule: kotlin.String,
        previousResult: AnalyzeResult? = null
    ): kotlin.String {
        val helper = AnalyzeRule(
            source = source,
            sourceStateStore = sourceStateStore,
            httpUseCase = httpUseCase,
            htmlParser = htmlParser,
            jsExecutor = jsExecutor,
            connectGateway = connectGateway,
            headerResolver = headerResolver,
            sourceJsRuntime = sourceJsRuntime
        )
        val currentContent = when (previousResult) {
            is AnalyzeResult.Elements -> if (previousResult.values.isStructuredArray()) {
                previousResult.values
            } else {
                previousResult.values.singleOrNull() ?: previousResult.values
            }
            is AnalyzeResult.StringList -> previousResult.values.singleOrNull() ?: previousResult.values
            is AnalyzeResult.StringVal -> previousResult.value
            is AnalyzeResult.IntVal -> previousResult.value
            is AnalyzeResult.LongVal -> previousResult.value
            is AnalyzeResult.FloatVal -> previousResult.value
            is AnalyzeResult.BoolVal -> previousResult.value
            is AnalyzeResult.Null, null -> content
        } ?: return ""
        helper.setContent(currentContent, baseUrl)
        helper.setBaseUrl(baseUrl)
        redirectUrl?.let(helper::setRedirectUrl)
        currentBook?.let(helper::setBookContext)
        currentChapter?.let(helper::setChapterContext)
        nextChapterUrl?.let(helper::setNextChapterUrl)
        helper.setRuleData(ruleData)
        helper.bigVariableSupport = bigVariableSupport
        helper.variables.putAll(variables)
        helper.jsContextBindings.putAll(jsContextBindings)
        return helper.getString(rule)
    }

    /**
     * Check if expression inside {{}} is a nested rule (not JS).
     * Based on legado's isRule() which checks @, $., $[, //.
     * Additionally includes CSS selector prefixes (., #, [) because
     * in KMP's architecture, inline {{}} expressions are resolved via
     * evaluateAuxiliaryRule (rule path) vs parseJsRule (JS path),
     * and CSS selectors like .class@text must go through the rule path.
     */
    private fun isNestedRuleExpression(expression: kotlin.String): kotlin.Boolean {
        return expression.startsWith("@") ||
            expression.startsWith("$.") ||
            expression.startsWith("$[") ||
            expression.startsWith("//") ||
            expression.startsWith(".") ||
            expression.startsWith("#") ||
            expression.startsWith("[")
    }

    // ==================== Parser Getters ====================

    private fun getCssParser(): CssRuleParser {
        return cssParser ?: CssRuleParser().also { cssParser = it }
    }

    private fun getRegexParser(): RegexRuleParser {
        return regexParser ?: RegexRuleParser().also { regexParser = it }
    }

    private fun getJsonPathParser(input: Any?) = jsonPathSupport.getParser(input)

    private fun getXPathParser(): XPathParser {
        return xPathParser ?: XPathParser().also { xPathParser = it }
    }

    private fun getJsParser(): JsRuleParser {
        return jsParser ?: JsRuleParser(jsExecutor, source, sourceStateStore).also { jsParser = it }
    }

    private companion object {
        val jsPattern = Regex("<js>([\\w\\W]*?)</js>|@js:([\\w\\W]*)", RegexOption.IGNORE_CASE)
        val legacyInlineScopePattern = Regex("""[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*""")
        val legacyJsHostHelperPattern = Regex(
            """source\.(?:getLoginHeader|putLoginHeader|getLoginInfo|getLoginInfoMap|putLoginInfo|removeLoginInfo|getVariable|getVariableMap|setVariable|removeLoginHeader|put|get|login|getHeaderMap|getLoginHeaderMap|getKey|getBookSourceUrl|getBookSourceComment)\s*\(|java\.(?:get|put|getElement|getElements|reGetBook|refreshTocUrl)\s*\("""
        )
        val legacyJsObjectMethodPattern = Regex("""(?:book|chapter)\.[A-Za-z_][A-Za-z0-9_]*\s*\(""")
        val legacyJsNetworkHelperPattern = Regex(
            """java\.(?:post|head|ajax|ajaxAll|connect|getResponse)\s*\(|java\.get\(\s*[^)]*,[^)]*\)"""
        )
    }

}
