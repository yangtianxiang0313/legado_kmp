package io.legado.kmp.shared.analyze.parser

import io.legado.kmp.shared.analyze.AnalyzeResult
import io.legado.kmp.shared.analyze.AnalyzeJsonArrayValues
import io.legado.kmp.shared.analyze.RuleAnalyzer
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull

/** A successful string read; an empty array has no values, but an empty scalar does. */
data class JsonPathStringResult(val value: String, val hasValues: Boolean)

/**
 * JSONPath rule parser backed by JsonPath4K's RFC9535 compiler and legacy adapters.
 *
 * Original Android project uses Jayway JsonPath (Java). Result contracts:
 *
 * 1. **Return type for single values**: Jayway may return unwrapped scalars for
 *    definite paths (`$.store.book[0].title` → `String`). The backend preserves
 *    the distinction between a definite value and an indefinite nodelist.
 *
 * 2. **Filters and functions**: Standard filters use the compiler; Jayway
 *    operator/function syntax is adapted separately without evaluating source data as code.
 *
 * 3. **Deep scan (`..`)**: Both libraries support recursive descent (`$..author`),
 *    while ordering follows traversal of the input structure.
 *
 * 4. **Negative indices**: Jayway supports `$[-1]` and `$[-2:]`. JsonPath4K
 *    uses end-exclusive ranges; RFC slice steps are handled by the compiler.
 *
 * 5. **Missing paths**: Jayway throws `PathNotFoundException` by default
 *    (configurable via `Option.SUPPRESS_EXCEPTIONS`). The adapter returns
 *    null for unresolved definite paths and preserves empty indefinite arrays.
 *
 * 6. **Type coercion**: Values remain `JsonElement`; string/raw/list conversion
 *    is selected by the caller instead of flattening the query result early.
 *    Returned raw values are snapshots: later public reads do not retroactively
 *    mutate previously returned `JsonElement` values.
 *    Key-set kinds remain scoped to the evaluation/session; the raw JSON-facing
 *    API projects them as arrays and cannot carry a Java Set across that boundary.
 *
 * Simple paths (`$.data[*].name`, `$..title`, `$.list[0].url`) do not establish
 * compatibility with sources that require Jayway's broader expression language.
 */
class JsonPathParser private constructor(
    private val boundContent: String?,
    private val boundSession: JsonPathDocumentSession?
) {
    /** Each public read gets an independent session, shared by its recursive rule branches. */
    constructor() : this(null, null)

    /**
     * Parse once and retain this document across reads, including mutations before a failed read.
     * Omitting a read's content uses this binding; different content gets a temporary session.
     */
    constructor(content: String) : this(
        content,
        kotlin.runCatching { parseSession(content) }.getOrNull()
    )

    internal constructor(value: JsonPathRetainedValue) : this(value.toString(), value.newSession())

    internal fun getRetainedObject(rule: String): JsonPathRetainedValue? {
        if (boundContent.isNullOrEmpty() || rule.isBlank()) return null
        return readSession(boundContent, null) { session ->
            resolveSingle(rule, session)?.let { JsonPathRetainedValue.capture(it, session.document) }
        }
    }

    internal fun getRetainedList(rule: String): List<Any>? {
        if (boundContent.isNullOrEmpty() || rule.isBlank()) return null
        return readSession(boundContent, null) { session ->
            AnalyzeJsonArrayValues(currentListValues(getListFromElement(rule, session), session).map { value ->
                if (value is JsonElement) JsonPathRetainedValue.capture(value, session.document) else value
            })
        }
    }

    fun evaluate(path: String, content: String = boundContent.orEmpty()): AnalyzeResult {
        if (content.isEmpty() || path.isBlank()) {
            return AnalyzeResult.StringVal("")
        }

        return readSession(content, AnalyzeResult.StringVal("")) { session ->
            val analyzer = RuleAnalyzer(path, true)
            val rules = analyzer.splitRule("&&", "||", "%%")

            if (rules.size == 1) {
                analyzer.resetPos()
                val replaced = analyzer.innerRuleLegacy("{$.") { inner ->
                    getString(inner, session)
                }
                if (replaced.isNotEmpty()) {
                    AnalyzeResult.StringVal(replaced)
                } else {
                    val resolved = resolveSingle(path, session) ?: JsonNull
                    resolved.toAnalyzeResult(session.document)
                }
            } else {
                val values = getStringList(path, session)
                when {
                    values.isEmpty() -> AnalyzeResult.StringVal("")
                    values.size == 1 -> AnalyzeResult.StringVal(values.first())
                    else -> AnalyzeResult.StringList(values)
                }
            }
        }
    }

    fun extractAll(path: String, content: String = boundContent.orEmpty()): List<String> {
        if (content.isEmpty() || path.isBlank()) {
            return emptyList()
        }

        return readSession(content, emptyList()) { session ->
            getStringList(path, session)
        }
    }

    fun isValid(path: String, content: String = boundContent.orEmpty()): Boolean {
        if (content.isEmpty() || path.isBlank()) {
            return false
        }

        return readSession(content, false) { session ->
            getStringList(path, session).isNotEmpty()
        }
    }

    /**
     * Get raw resolved object from JSONPath
     * Aligned with AnalyzeByJSonPath.getObject
     */
    fun getObject(rule: String, content: String = boundContent.orEmpty()): Any? {
        if (content.isEmpty() || rule.isBlank()) return null
        return readSession(content, null) { session ->
            resolveSingle(rule, session)?.let { JsonPathBackend.currentValue(it, session) }
        }
    }

    /**
     * Get list of parsed objects for element extraction
     * Aligned with AnalyzeByJSonPath.getList
     */
    fun getList(rule: String, content: String = boundContent.orEmpty()): List<Any>? {
        if (content.isEmpty() || rule.isBlank()) return null
        return readSession(content, null) { session ->
            AnalyzeJsonArrayValues(currentListValues(getListFromElement(rule, session), session))
        }
    }

    private fun getListFromElement(rule: String, session: JsonPathDocumentSession): List<Any> {
        if (rule.isEmpty()) return emptyList()
        val ruleAnalyzer = RuleAnalyzer(rule, true)
        val rules = ruleAnalyzer.splitRule("&&", "||", "%%")

        if (rules.size == 1) {
            val resolvedValue = resolveValue(rule, session) ?: return emptyList()
            if (resolvedValue.isKeySet) return emptyList()
            val resolved = resolvedValue.value
            return when (resolved) {
                // Keep the array identity until later branches have finished mutating the document.
                is JsonArray -> resolved
                else -> emptyList()
            }
        }

        val groupedResults = mutableListOf<List<Any>>()
        for (candidate in rules) {
            val values = getListFromElement(candidate, session)
            if (values.isNotEmpty()) {
                groupedResults += values
                if (ruleAnalyzer.elementsType == "||") break
            }
        }
        if (groupedResults.isEmpty()) return emptyList()

        val currentGroups = groupedResults.map { currentListValues(it, session) }
        val values = if (ruleAnalyzer.elementsType == "%%") {
            interleave(currentGroups)
        } else {
            currentGroups.flatten()
        }
        return values
    }

    private fun currentListValues(values: List<Any>, session: JsonPathDocumentSession): List<Any> {
        val current = if (values is JsonArray) {
            JsonPathBackend.currentValue(values, session) as JsonArray
        } else {
            values
        }
        return current.map { value ->
            if (value is JsonElement) JsonPathBackend.currentValue(value, session) else value
        }
    }

    private fun <T> interleave(groups: List<List<T>>): List<T> {
        if (groups.isEmpty()) return emptyList()
        val result = mutableListOf<T>()
        val baseSize = groups.first().size
        for (index in 0 until baseSize) {
            for (group in groups) {
                if (index < group.size) {
                    result += group[index]
                }
            }
        }
        return result
    }

    fun getValue(path: String, content: String = boundContent.orEmpty()): String? =
        getValueWithPresence(path, content)?.value

    /** Resolve once so callers never rerun a mutating path to distinguish "" from an empty array. */
    fun getValueWithPresence(path: String, content: String = boundContent.orEmpty()): JsonPathStringResult? {
        if (content.isEmpty() || path.isBlank()) {
            return null
        }

        return readSession(content, null) { session ->
            getStringWithPresence(path, session)
        }
    }

    fun getValueOrDefault(
        path: String,
        content: String = boundContent.orEmpty(),
        defaultValue: String = ""
    ): String {
        return getValue(path, content) ?: defaultValue
    }

    private fun JsonElement.toAnalyzeResult(document: JsonPathFunctionDocument): AnalyzeResult {
        if (document.collections.isKeySet(this)) {
            return AnalyzeResult.StringVal(toLegacyString(document).orEmpty())
        }
        return when (this) {
            JsonNull -> AnalyzeResult.StringVal("")
            is JsonPrimitive -> {
                booleanOrNull?.let { return AnalyzeResult.BoolVal(it) }
                intOrNull?.let { return AnalyzeResult.IntVal(it) }
                longOrNull?.let { return AnalyzeResult.LongVal(it) }
                contentOrNull?.toFloatOrNull()?.let { return AnalyzeResult.FloatVal(it) }
                AnalyzeResult.StringVal(contentOrNull ?: toString())
            }
            is JsonArray -> AnalyzeResult.StringList(mapNotNull { it.toLegacyString(document) })
            is JsonObject -> AnalyzeResult.StringVal(toLegacyString(document).orEmpty())
        }
    }

    private fun JsonElement.toLegacyString(document: JsonPathFunctionDocument): String? =
        if (this === JsonNull) null else JsonPathValueStrings.javaString(
            this, document.numberTypes, document.collections::isKeySet,
        )

    private companion object {
        private fun parseSession(content: String): JsonPathDocumentSession {
            val numbers = JsonPathNumberTypes()
            val root = JsonPathJsonReader.parse(content, numbers::register)
            return JsonPathDocumentSession(root, numbers)
        }
    }

    private fun sessionFor(content: String): JsonPathDocumentSession? {
        return if (content == boundContent) {
            boundSession
        } else {
            parseSession(content)
        }
    }

    private fun <T> readSession(
        content: String,
        fallback: T,
        read: (JsonPathDocumentSession) -> T
    ): T {
        return try {
            val session = sessionFor(content) ?: return fallback
            JsonPathBackend.withSessionRead(session) { read(session) }
        } catch (failure: CancellationException) {
            throw failure
        } catch (_: Throwable) {
            fallback
        }
    }

    private fun resolveSingle(path: String, session: JsonPathDocumentSession): JsonElement? {
        return resolveValue(path, session)?.value
    }

    private fun resolveValue(path: String, session: JsonPathDocumentSession): JsonPathResolvedValue? {
        return JsonPathBackend.resolveValue(normalizeLegacyJsonPath(path), session)
    }

    private fun JsonPathResolvedValue.keySetString(): String =
        (value as JsonArray).joinToString(", ", "[", "]") { (it as JsonPrimitive).content }

    private fun normalizeLegacyJsonPath(path: String): String {
        val normalized = normalizeLegacyPathSyntax(path.trim())
        if (normalized.isEmpty()) return normalized
        return when {
            normalized.startsWith("$") -> normalized
            normalized.startsWith("..") -> "\$$normalized"
            normalized.startsWith(".") -> "\$$normalized"
            normalized.startsWith("[") -> "\$$normalized"
            else -> "\$.$normalized"
        }
    }

    private fun normalizeLegacyPathSyntax(path: String): String {
        if (!path.contains(".*") && !path.contains(".[")) return path
        val result = StringBuilder(path.length)
        var index = 0
        var quote: Char? = null
        var escaped = false
        var bracketDepth = 0
        var parenDepth = 0
        while (index < path.length) {
            val char = path[index]
            if (escaped) {
                result.append(char)
                escaped = false
                index++
                continue
            }
            if (quote != null) {
                result.append(char)
                if (char == '\\') {
                    escaped = true
                } else if (char == quote) {
                    quote = null
                }
                index++
                continue
            }
            when (char) {
                '\'', '"' -> {
                    quote = char
                    result.append(char)
                    index++
                }
                '[' -> {
                    bracketDepth++
                    result.append(char)
                    index++
                }
                ']' -> {
                    if (bracketDepth > 0) bracketDepth--
                    result.append(char)
                    index++
                }
                '(' -> {
                    parenDepth++
                    result.append(char)
                    index++
                }
                ')' -> {
                    if (parenDepth > 0) parenDepth--
                    result.append(char)
                    index++
                }
                '.' -> {
                    val isPathDot = index + 1 < path.length &&
                        (index == 0 || path[index - 1] != '.') &&
                        bracketDepth == 0 &&
                        parenDepth == 0
                    if (isPathDot && path[index + 1] == '[') {
                        // Leave quoted keys, filter contents and recursive descent unchanged.
                        index++
                    } else if (isPathDot && path[index + 1] == '*') {
                        result.append("[*]")
                        index += 2
                    } else {
                        result.append(char)
                        index++
                    }
                }
                else -> {
                    result.append(char)
                    index++
                }
            }
        }
        return result.toString()
    }

    private fun getString(rule: String, session: JsonPathDocumentSession): String? =
        getStringWithPresence(rule, session)?.value

    private fun getStringWithPresence(rule: String, session: JsonPathDocumentSession): JsonPathStringResult? {
        if (rule.isEmpty()) return null
        val ruleAnalyzer = RuleAnalyzer(rule, true)
        val rules = ruleAnalyzer.splitRule("&&", "||")

        if (rules.size == 1) {
            ruleAnalyzer.resetPos()
            val replaced = ruleAnalyzer.innerRuleLegacy("{$.") { inner ->
                getString(inner, session)
            }
            if (replaced.isNotEmpty()) {
                return JsonPathStringResult(replaced, hasValues = true)
            }

            val resolvedValue = resolveValue(rule, session) ?: return null
            if (resolvedValue.isKeySet) {
                return JsonPathStringResult(resolvedValue.keySetString(), hasValues = true)
            }
            val resolved = resolvedValue.value
            val value = when (resolved) {
                JsonNull -> "null"
                is JsonArray -> resolved.joinToString("\n") { it.toLegacyString(session.document) ?: "null" }
                else -> resolved.toLegacyString(session.document)
            }
            return value?.let {
                JsonPathStringResult(it, hasValues = resolved !is JsonArray || resolved.isNotEmpty())
            }
        }

        val values = buildList {
            for (candidate in rules) {
                val value = getString(candidate, session)
                if (!value.isNullOrEmpty()) {
                    add(value)
                    if (ruleAnalyzer.elementsType == "||") {
                        break
                    }
                }
            }
        }
        return values.joinToString("\n").takeIf { it.isNotEmpty() }
            ?.let { JsonPathStringResult(it, hasValues = true) }
    }

    private fun getStringList(rule: String, session: JsonPathDocumentSession): List<String> {
        if (rule.isEmpty()) return emptyList()
        val result = mutableListOf<String>()
        val ruleAnalyzer = RuleAnalyzer(rule, true)
        val rules = ruleAnalyzer.splitRule("&&", "||", "%%")

        if (rules.size == 1) {
            ruleAnalyzer.resetPos()
            val replaced = ruleAnalyzer.innerRuleLegacy("{$.") { inner ->
                getString(inner, session)
            }
            if (replaced.isNotEmpty()) {
                result += replaced
                return result
            }

            val resolvedValue = resolveValue(rule, session) ?: return emptyList()
            if (resolvedValue.isKeySet) return listOf(resolvedValue.keySetString())
            val resolved = resolvedValue.value
            return when (resolved) {
                JsonNull -> listOf("null")
                is JsonArray -> resolved.map { it.toLegacyString(session.document) ?: "null" }
                else -> listOfNotNull(resolved.toLegacyString(session.document))
            }
        }

        val groupedResults = mutableListOf<List<String>>()
        for (candidate in rules) {
            val values = getStringList(candidate, session)
            if (values.isNotEmpty()) {
                groupedResults += values
                if (ruleAnalyzer.elementsType == "||") {
                    break
                }
            }
        }
        if (groupedResults.isEmpty()) {
            return emptyList()
        }

        return if (ruleAnalyzer.elementsType == "%%") {
            interleave(groupedResults)
        } else {
            groupedResults.flatten()
        }
    }

}
