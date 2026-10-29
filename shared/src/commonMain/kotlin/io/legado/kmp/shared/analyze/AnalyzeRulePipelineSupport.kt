package io.legado.kmp.shared.analyze

import com.fleeksoft.ksoup.nodes.Element
import io.legado.kmp.shared.analyze.parser.CssRuleParser
import io.legado.kmp.shared.analyze.parser.JsonPathParser
import io.legado.kmp.shared.analyze.parser.JsonPathRetainedValue
import io.legado.kmp.shared.analyze.parser.RegexRuleParser
import io.legado.kmp.shared.analyze.parser.XPathParser
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

internal class AnalyzeRulePipelineSupport(
    private val getContent: () -> Any?,
    private val getBaseUrl: () -> String?,
    private val getCssParser: () -> CssRuleParser,
    private val getRegexParser: () -> RegexRuleParser,
    private val getJsonPathParser: (Any?) -> JsonPathParser,
    private val getXPathParser: () -> XPathParser,
    private val splitSourceRule: (String) -> List<SourceRule>,
    private val splitSourceRuleForContent: (String?, Any?, Boolean) -> List<SourceRule>,
    private val applyPutMap: suspend (SourceRule) -> Unit,
    private val resolveLegacySourceRule: suspend (SourceRule, AnalyzeResult) -> SourceRule,
    private val parseJsRule: suspend (String, AnalyzeResult) -> AnalyzeResult
) {
    suspend fun parseElementsFrom(
        rule: kotlin.String,
        input: Any?,
        singleElement: Boolean = false
    ): Any? {
        if (rule.isBlank()) return input
        val ruleList = splitSourceRuleForContent(rule, input, true)
        if (ruleList.isEmpty()) return input

        var result: Any? = input
        for (sourceRule in ruleList) {
            if (sourceRule.putMap.isNotEmpty()) {
                applyPutMap(sourceRule)
            }
            result = result?.let { current ->
                when (sourceRule.type) {
                    RuleType.REGEX -> {
                        val regs = splitRegexRules(sourceRule.cleanRule)
                        if (regs.isNotEmpty()) {
                            getRegexParser().getElements(current.toString(), regs)
                        } else {
                            emptyList<Any>()
                        }
                    }
                    RuleType.JS -> {
                        jsPipelineValue(
                            parseJsRule(
                                sourceRule.cleanRule,
                                analyzeResultFromRaw(current)
                            )
                        )
                    }
                    RuleType.JSONPATH, RuleType.JSON -> {
                        val parser = getJsonPathParser(current)
                        if (singleElement) {
                            parser.getRetainedObject(sourceRule.cleanRule)
                        } else {
                            parser.getRetainedList(sourceRule.cleanRule) ?: emptyList<Any>()
                        }
                    }
                    RuleType.XPATH -> {
                        getXPathParser().getElements(sourceRule.cleanRule, current)
                    }
                    else -> {
                        AnalyzeHtmlElementValues.elements(
                            getCssParser().getElements(sourceRule.cleanRule, current).map { it as Element }
                        )
                    }
                }
            }
            if (sourceRule.replaceRegex.isNotEmpty()) {
                result = applyRegexReplacementToResult(result, sourceRule)
            }
            if (result == null) {
                break
            }
        }
        return result
    }

    /**
     * Parse rules and evaluate with optional mContent override.
     * Used by getString and getStringList for content override support.
     */
    suspend fun parseWithRuleList(
        ruleList: List<SourceRule>,
        mContent: Any? = null,
        resultMode: JsonPathResultMode = JsonPathResultMode.STRING
    ): AnalyzeResult {
        if (ruleList.isEmpty()) return AnalyzeResult.Null

        val effectiveContent = mContent ?: getContent()

        var currentResult = analyzeResultFromRaw(effectiveContent)
        var currentInput = effectiveContent

        for (sourceRule in ruleList) {
            if (sourceRule.putMap.isNotEmpty()) {
                applyPutMap(sourceRule)
            }
            val resolvedRule = resolveLegacySourceRule(sourceRule, currentResult)
            currentResult = evaluateResolvedSourceRule(sourceRule, resolvedRule, currentResult, resultMode, currentInput)
            if (currentResult is AnalyzeResult.Null) {
                break
            }
            currentResult = applyPipelineReplacement(currentResult, resolvedRule)
            currentInput = currentResult.jsonPathRawInput()
        }
        return currentResult
    }

    /**
     * Parse a single rule part
     */
    suspend fun parseSingleRule(
        rule: kotlin.String,
        previousResult: AnalyzeResult,
        resultMode: JsonPathResultMode,
        input: Any? = previousResult.jsonPathRawInput()
    ): AnalyzeResult {
        if (rule.isBlank()) {
            return previousResult
        }

        var currentResult = previousResult
        var currentInput = input
        for (sourceRule in splitSourceRule(rule)) {
            if (sourceRule.putMap.isNotEmpty()) {
                applyPutMap(sourceRule)
            }
            val resolvedRule = resolveLegacySourceRule(sourceRule, currentResult)
            currentResult = evaluateResolvedSourceRule(sourceRule, resolvedRule, currentResult, resultMode, currentInput)
            if (currentResult is AnalyzeResult.Null) {
                break
            }
            currentResult = applyPipelineReplacement(currentResult, resolvedRule)
            currentInput = currentResult.jsonPathRawInput()
        }
        return currentResult
    }

    /**
     * Parse elements from rule
     */
    private suspend fun parseElements(rule: kotlin.String, inputElements: List<Any>): List<Any> {
        if (rule.isBlank()) {
            return inputElements
        }

        val sourceRule = SourceRule.parse(rule)

        return when (sourceRule.type) {
            RuleType.CSS -> {
                inputElements.flatMap { element ->
                    getCssParser().getElements(sourceRule.cleanRule, element)
                }
            }
            RuleType.JSONPATH, RuleType.JSON -> {
                inputElements.flatMap { element ->
                    getJsonPathParser(element).getRetainedList(sourceRule.cleanRule).orEmpty()
                }
            }
            RuleType.REGEX -> {
                val regs = splitRegexRules(sourceRule.cleanRule)
                if (regs.isEmpty()) {
                    emptyList()
                } else {
                    val matches = inputElements.flatMap { element ->
                        if (regs.size == 1) {
                            getRegexParser().findAllGroups(regs.first(), element.toString())
                        } else {
                            getRegexParser().getElements(element.toString(), regs)
                        }
                    }
                    if (matches.any { it.size > 1 }) {
                        matches.map { it as Any }
                    } else {
                        matches.mapNotNull { it.firstOrNull() }.map { it as Any }
                    }
                }
            }
            RuleType.JS -> {
                parseJsRule(
                    sourceRule.cleanRule,
                    analyzeResultFromRaw(inputElements)
                ).asElementValues()
            }
            RuleType.XPATH -> {
                inputElements.flatMap { element ->
                    getXPathParser().getElements(sourceRule.cleanRule, element)
                }
            }
        }
    }

    // ==================== Parser Methods ====================

    private suspend fun evaluateResolvedSourceRule(
        sourceRule: SourceRule,
        resolvedRule: SourceRule,
        previousResult: AnalyzeResult,
        resultMode: JsonPathResultMode,
        input: Any?
    ): AnalyzeResult {
        tryReturnLegacyLiteralResult(sourceRule, resolvedRule, previousResult)?.let { return it }
        evaluateMixedParserFallback(sourceRule, previousResult, resultMode, input)?.let { return it }
        return evaluateSingleResolvedRule(resolvedRule, previousResult, resultMode, input)
    }

    private suspend fun evaluateMixedParserFallback(
        sourceRule: SourceRule,
        previousResult: AnalyzeResult,
        resultMode: JsonPathResultMode,
        input: Any?
    ): AnalyzeResult? {
        val parts = splitRuleChain(sourceRule.rule, "||")
        if (!shouldUseMixedParserFallback(parts)) {
            return null
        }
        for (part in parts) {
            val branchSourceRule = SourceRule.parse(part)
            val branchResolvedRule = resolveLegacySourceRule(branchSourceRule, previousResult)
            val branchResult = tryReturnLegacyLiteralResult(
                branchSourceRule,
                branchResolvedRule,
                previousResult
            ) ?: evaluateSingleResolvedRule(branchResolvedRule, previousResult, resultMode, input)
            val replaced = applyPipelineReplacement(branchResult, branchResolvedRule)
            if (!replaced.isEmptyResult()) {
                return replaced
            }
        }
        return AnalyzeResult.Null
    }

    private fun applyPipelineReplacement(result: AnalyzeResult, rule: SourceRule): AnalyzeResult {
        val replaced = applyRuleReplacement(result, rule)
        return if (result is AnalyzeResult.StringList &&
            result.values is AnalyzeJsonStringValues && replaced is AnalyzeResult.StringList
        ) {
            AnalyzeResult.StringList(AnalyzeJsonStringValues(replaced.values))
        } else {
            replaced
        }
    }

    private fun shouldUseMixedParserFallback(parts: List<kotlin.String>): kotlin.Boolean {
        if (parts.size < 2) return false
        val explicitTypes = parts.mapNotNull { explicitParserType(it) }
        return explicitTypes.size == parts.size && explicitTypes.toSet().size >= 2
    }

    private fun explicitParserType(rule: kotlin.String): RuleType? {
        val trimmed = rule.trim()
        return when {
            trimmed.startsWith("@json:", ignoreCase = true) -> RuleType.JSON
            trimmed.startsWith("@css:", ignoreCase = true) -> RuleType.CSS
            trimmed.startsWith("@xpath:", ignoreCase = true) -> RuleType.XPATH
            trimmed.startsWith("@js:", ignoreCase = true) -> RuleType.JS
            trimmed.startsWith("<js>", ignoreCase = true) -> RuleType.JS
            else -> null
        }
    }

    private suspend fun evaluateSingleResolvedRule(
        resolvedRule: SourceRule,
        previousResult: AnalyzeResult,
        resultMode: JsonPathResultMode,
        input: Any?
    ): AnalyzeResult {
        return when (resolvedRule.type) {
            RuleType.CSS -> {
                // URL callers choose the first candidate in getString(), but
                // getStringList(isUrl = true) must preserve every matched URL
                // for multi-page TOC/content rules.
                parseCssRule(resolvedRule.cleanRule, previousResult)
            }
            RuleType.XPATH -> parseXPathRule(resolvedRule.cleanRule, previousResult)
            RuleType.JSONPATH -> parseJsonPathRule(resolvedRule.cleanRule, input, resultMode)
            RuleType.JSON -> parseJsonPathRule(resolvedRule.cleanRule, input, resultMode)
            RuleType.REGEX -> parseRegexRule(resolvedRule.cleanRule, previousResult)
            RuleType.JS -> parseJsRule(resolvedRule.cleanRule, previousResult)
        }
    }

    private fun AnalyzeResult.isEmptyResult(): kotlin.Boolean {
        return when (this) {
            is AnalyzeResult.Null -> true
            is AnalyzeResult.StringVal -> value.isBlank()
            is AnalyzeResult.StringList -> values.isEmpty() || values.all { it.isBlank() }
            is AnalyzeResult.Elements -> values.isEmpty()
            else -> false
        }
    }

    private fun parseCssRule(rule: kotlin.String, previousResult: AnalyzeResult): AnalyzeResult {
        parseDirectObjectRule(rule, previousResult)?.let { return it }
        val values = when (previousResult) {
            is AnalyzeResult.Elements -> previousResult.values.mapNotNull { element ->
                getCssParser().getString(rule, element, getBaseUrl())
            }
            else -> {
                val contentStr = previousResult.asString()
                if (contentStr.isBlank()) {
                    return AnalyzeResult.Null
                }
                listOfNotNull(getCssParser().getString(rule, contentStr, getBaseUrl()))
            }
        }

        return when {
            values.isEmpty() -> AnalyzeResult.Null
            values.size == 1 -> AnalyzeResult.StringVal(values.first())
            else -> AnalyzeResult.StringList(values)
        }
    }

    private fun parseXPathRule(rule: kotlin.String, previousResult: AnalyzeResult): AnalyzeResult {
        val results = when (previousResult) {
            is AnalyzeResult.Elements -> previousResult.values.flatMap { element ->
                getXPathParser().extractAll(rule, element)
            }
            else -> getXPathParser().extractAll(rule, previousResult.asString())
        }

        return when {
            results.isEmpty() -> AnalyzeResult.Null
            results.size == 1 -> AnalyzeResult.StringVal(results.first())
            else -> AnalyzeResult.StringList(results)
        }
    }

    private fun parseJsonPathRule(
        rule: kotlin.String,
        input: Any?,
        resultMode: JsonPathResultMode
    ): AnalyzeResult {
        val parser = getJsonPathParser(input)
        return when (resultMode) {
            JsonPathResultMode.RAW -> analyzeResultFromRaw(parser.getRetainedObject(rule))
            JsonPathResultMode.STRING -> {
                val result = parser.getValueWithPresence(rule) ?: return AnalyzeResult.Null
                if (!result.hasValues) {
                    AnalyzeResult.Null
                } else {
                    AnalyzeResult.StringVal(result.value)
                }
            }
            JsonPathResultMode.STRING_LIST -> {
                val values = parser.extractAll(rule)
                if (values.isEmpty()) {
                    AnalyzeResult.Null
                } else {
                    AnalyzeResult.StringList(AnalyzeJsonStringValues(values))
                }
            }
        }
    }

    private fun parseRegexRule(rule: kotlin.String, previousResult: AnalyzeResult): AnalyzeResult {
        val contentStr = previousResult.asString()

        if (contentStr.isBlank()) {
            return AnalyzeResult.Null
        }

        val regs = splitRegexRules(rule)
        if (regs.isEmpty()) {
            return AnalyzeResult.Null
        }
        val matches = getRegexParser().getElements(contentStr, regs)
        if (matches.isEmpty()) {
            return AnalyzeResult.Null
        }
        if (matches.size == 1) {
            val groups = matches.first()
            return if (groups.size > 1) {
                AnalyzeResult.StringList(groups)
            } else {
                AnalyzeResult.StringVal(groups.firstOrNull().orEmpty())
            }
        }
        return AnalyzeResult.StringList(matches.mapNotNull { it.firstOrNull() })
    }

    private fun parseDirectObjectRule(
        rule: kotlin.String,
        previousResult: AnalyzeResult
    ): AnalyzeResult? {
        if (!directLookupRulePattern.matches(rule)) {
            return null
        }
        val values = when (previousResult) {
            is AnalyzeResult.Elements -> previousResult.values.mapNotNull { directLookup(it, rule) }
            else -> directLookup(getContent() ?: return null, rule)?.let(::listOf).orEmpty()
        }
        return when {
            values.isEmpty() -> null
            values.size == 1 -> AnalyzeResult.StringVal(values.first())
            else -> AnalyzeResult.StringList(values)
        }
    }

    /**
     * Direct key access on structured objects.
     * Aligned with legado's NativeObject key access: when content is a JS-originated
     * object (Map in KMP/QuickJS), directly access by key. Also handles JsonObject
     * and nested attrs maps.
     */
    private fun directLookup(value: Any, key: kotlin.String): kotlin.String? {
        return when (value) {
            is JsonPathRetainedValue -> directLookup(value.element, key)
            is Map<*, *> -> value[key]?.toString()
                ?: (value["attrs"] as? Map<*, *>)?.get(key)?.toString()
            is JsonObject -> value[key]?.toPlainString()
            is JsonPrimitive -> if (key == "text" || key == "value") value.content else null
            is JsonElement -> value.toPlainString()
            is List<*> -> {
                // JS arrays: try first element as map lookup
                val first = value.firstOrNull()
                if (first is Map<*, *>) first[key]?.toString() else null
            }
            else -> {
                // Try JSON parsing for string values that look like JSON objects
                val str = value.toString().trim()
                if (str.startsWith("{") && str.endsWith("}")) {
                    runCatching {
                        val parsed = Json.parseToJsonElement(str) as? JsonObject
                        parsed?.get(key)?.toPlainString()
                    }.getOrNull()
                } else {
                    null
                }
            }
        }
    }

    private fun JsonElement.toPlainString(): kotlin.String {
        return when (this) {
            is JsonPrimitive -> content
            is JsonArray -> joinToString("\n") { it.toPlainString() }
            is JsonObject -> toString()
        }
    }

    private companion object {
        val directLookupRulePattern = Regex("""[A-Za-z0-9_\-.]+""")
    }
}
