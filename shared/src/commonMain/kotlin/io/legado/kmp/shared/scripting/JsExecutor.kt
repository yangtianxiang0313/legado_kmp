package io.legado.kmp.shared.scripting

import com.dokar.quickjs.QuickJs
import com.fleeksoft.ksoup.nodes.Element
import com.fleeksoft.ksoup.nodes.Node
import com.fleeksoft.ksoup.select.Elements
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout

/**
 * JavaScript execution context
 * Contains variables to be available during script execution
 */
data class JsContext(
    val variables: Map<String, Any?> = emptyMap(),
    val timeoutMs: Long = 5000L
)

/**
 * JavaScript execution result
 */
sealed class JsResult {
    data class JsString(val value: String) : JsResult()
    data class JsNumber(val value: Double) : JsResult()
    data class JsBoolean(val value: Boolean) : JsResult()
    data class JsObject(val value: Map<String, Any?>) : JsResult()
    data class JsArray(val value: List<Any?>) : JsResult()
    // Only the trusted runtime codec creates this result when native DOM is present.
    data class JsNativeValue(val value: Any?) : JsResult()
    data class JsNull(val value: Unit = Unit) : JsResult()
    data class JsUndefined(val value: Unit = Unit) : JsResult()
    data class JsError(
        val message: String,
        val exception: Throwable? = null,
        val stackTrace: String? = null
    ) : JsResult()

    val isSuccess: Boolean get() = this !is JsError
    val isError: Boolean get() = this is JsError

    /**
     * Get the result as a string
     */
    fun asString(): String = when (this) {
        is JsString -> value
        is JsNumber -> value.toString()
        is JsBoolean -> value.toString()
        is JsNull -> "null"
        is JsUndefined -> "undefined"
        is JsArray -> value.toString()
        is JsObject -> value.toString()
        is JsNativeValue -> when (val native = value) {
            is Element -> native.outerHtml()
            is Elements -> native.outerHtml()
            is Node -> legacyJsDomOuterHtml(native)
            else -> native.toString()
        }
        is JsError -> message
    }

    companion object {
        /**
         * Convert any value to JsResult
         */
        fun fromAny(value: Any?): JsResult = when (value) {
            null -> JsNull()
            is String -> JsString(value)
            is Int -> JsNumber(value.toDouble())
            is Long -> JsNumber(value.toDouble())
            is Float -> JsNumber(value.toDouble())
            is Double -> JsNumber(value)
            is Boolean -> JsBoolean(value)
            is Map<*, *> -> {
                @Suppress("UNCHECKED_CAST")
                JsObject(value as Map<String, Any?>)
            }
            is List<*> -> JsArray(value)
            is Set<*> -> JsArray(value.toList())
            else -> JsString(value.toString())
        }
    }
}

/**
 * JavaScript execution exception
 */
class JsExecutionException(message: String, cause: Throwable?) : Exception(message, cause)

/**
 * JavaScript executor using QuickJS
 * Provides cross-platform JavaScript execution with ES2020+ support
 */
class JsExecutor {

    /**
     * Execute JavaScript code with context
     * @param script JavaScript code
     * @param context Execution context with variables
     * @return Execution result
     */
    suspend fun execute(script: String, context: JsContext = JsContext()): JsResult {
        return try {
            withContext(Dispatchers.Default) {
                withTimeout(context.timeoutMs) {
                    val quickJs = QuickJs.create(Dispatchers.Default)
                    try {
                        // Define variables as global objects with getters
                        val varsCode = buildVariablesCode(context.variables)
                        val fullScript = if (varsCode.isNotEmpty()) "$varsCode\n$script" else script

                        val result = quickJs.evaluate<Any?>(fullScript)
                        var jsResult = JsResult.fromAny(result)
                        if (jsResult is JsResult.JsNull || jsResult is JsResult.JsUndefined) {
                            buildLegacyReturnScript(script)?.let { legacyScript ->
                                val legacyFullScript = if (varsCode.isNotEmpty()) {
                                    "$varsCode\n$legacyScript"
                                } else {
                                    legacyScript
                                }
                                jsResult = JsResult.fromAny(quickJs.evaluate<Any?>(legacyFullScript))
                            }
                        }
                        jsResult
                    } finally {
                        quickJs.close()
                    }
                }
            }
        } catch (e: kotlinx.coroutines.TimeoutCancellationException) {
            JsResult.JsError("Script execution timed out", e)
        } catch (e: Exception) {
            JsResult.JsError(
                message = e.message ?: "Unknown error",
                exception = e,
                stackTrace = e.stackTraceToString()
            )
        }
    }

    /**
     * Build JavaScript code to define variables
     */
    private fun buildVariablesCode(variables: Map<String, Any?>): String {
        if (variables.isEmpty()) return ""

        val sb = StringBuilder()
        variables.forEach { (key, value) ->
            val jsValue = when (value) {
                null -> "null"
                is String -> "\"${value.escapeJsString()}\""
                is Int, is Long, is Float, is Double -> value.toString()
                is Boolean -> value.toString()
                is Map<*, *> -> {
                    // Convert map to JSON-like object
                    val entries = value.entries.joinToString(",") { (k, v) ->
                        "\"${k}\": ${when (v) {
                            null -> "null"
                            is String -> "\"${v.escapeJsString()}\""
                            is Number -> v.toString()
                            is Boolean -> v.toString()
                            else -> "\"${v.toString().escapeJsString()}\""
                        }}"
                    }
                    "{$entries}"
                }
                is List<*> -> {
                    val items = value.joinToString(",") { v ->
                        when (v) {
                            null -> "null"
                            is String -> "\"${v.escapeJsString()}\""
                            is Number -> v.toString()
                            is Boolean -> v.toString()
                            else -> "\"${v.toString().escapeJsString()}\""
                        }
                    }
                    "[$items]"
                }
                else -> "\"${value.toString().escapeJsString()}\""
            }
            sb.append("var $key = $jsValue;\n")
        }
        return sb.toString()
    }

    /**
     * Escape JavaScript string
     */
    private fun String.escapeJsString(): String {
        return this
            .replace("\\", "\\\\")
            .replace("\"", "\\\"")
            .replace("\n", "\\n")
            .replace("\r", "\\r")
            .replace("\t", "\\t")
    }

    private fun buildLegacyReturnScript(script: String): String? {
        val trimmed = script.trim()
        if (trimmed.isEmpty() || hasTopLevelReturn(trimmed)) {
            return null
        }
        if (!trimmed.contains(';') && !trimmed.contains('\n')) {
            return buildString {
                append("(() => {\n")
                append("return (")
                append(trimmed)
                append(");\n")
                append("})()")
            }
        }
        val withoutTrailing = trimmed.trimEnd(';', '\n', '\r', ' ', '\t')
        val splitIndex = findLegacyReturnBoundary(withoutTrailing)
        if (splitIndex < 0 || splitIndex >= withoutTrailing.lastIndex - 1) {
            return null
        }
        val statements = withoutTrailing.substring(0, splitIndex).trim()
        val tailExpression = withoutTrailing.substring(splitIndex + 1).trim().removeSuffix(";").trim()
        if (!isValidLegacyTailExpression(tailExpression)) {
            return null
        }
        return buildString {
            append("(() => {\n")
            if (statements.isNotEmpty()) {
                append(statements)
                if (!statements.endsWith(";")) {
                    append(';')
                }
                append('\n')
            }
            append("return (")
            append(tailExpression)
            append(");\n})()")
        }
    }

    private fun findLegacyReturnBoundary(script: String): Int {
        val candidates = linkedSetOf<Int>()
        candidates += findTopLevelIndexes(script, ';')
        candidates += findTopLevelIndexes(script, '\n')
        for (index in candidates.sortedDescending()) {
            val before = script.substring(0, index).trimEnd()
            val after = script.substring(index + 1).trimStart()
            if (before.isEmpty() || after.isEmpty()) continue
            if (script[index] == '\n' && looksLikeExpressionContinuation(before, after)) continue
            val tailExpression = after.removeSuffix(";").trim()
            if (isValidLegacyTailExpression(tailExpression)) {
                return index
            }
        }
        return -1
    }

    private fun hasTopLevelReturn(script: String): Boolean {
        return findTopLevelKeyword(script, "return")
    }

    private fun isValidLegacyTailExpression(tailExpression: String): Boolean {
        if (tailExpression.isEmpty() || tailExpression.startsWith("return ")) {
            return false
        }
        return !tailExpression.startsWithLegacyStatementKeyword()
    }

    private fun looksLikeExpressionContinuation(before: String, after: String): Boolean {
        val beforeLine = before.substringAfterLast('\n').trimEnd()
        val afterLine = after.substringBefore('\n').trimStart()
        if (beforeLine.isEmpty() || afterLine.isEmpty()) return false
        val continuationSuffixes = listOf(
            "+", "-", "*", "/", "%", "&&", "||", "??", "|", "&", "^",
            "=", "==", "===", "!=", "!==", ">", ">=", "<", "<=", "?",
            ":", ",", ".", "(", "[", "{"
        )
        val continuationPrefixes = listOf(
            "+", "-", "*", "/", "%", "&&", "||", "??", "|", "&", "^",
            ".", ")", "]", "}", ":", "?", ","
        )
        if (continuationSuffixes.any { beforeLine.endsWith(it) }) return true
        if (continuationPrefixes.any { afterLine.startsWith(it) }) return true
        if (beforeLine.endsWith("=>")) return true
        return false
    }

    private fun String.startsWithLegacyStatementKeyword(): Boolean {
        val statementPrefixes = listOf(
            "if",
            "else",
            "for",
            "while",
            "switch",
            "try",
            "catch",
            "finally",
            "do",
            "var",
            "let",
            "const",
            "function",
            "class"
        )
        return statementPrefixes.any { keyword ->
            startsWith(keyword) && (length == keyword.length || !this[keyword.length].isScriptIdentifierPart())
        }
    }

    private fun findTopLevelKeyword(script: String, keyword: String): Boolean {
        val indexes = findTopLevelIndexes(script, keyword.first())
        return indexes.any { index ->
            script.regionMatches(index, keyword, 0, keyword.length) &&
                (index == 0 || !script[index - 1].isScriptIdentifierPart()) &&
                (index + keyword.length >= script.length || !script[index + keyword.length].isScriptIdentifierPart())
        }
    }

    private fun findTopLevelIndexes(script: String, target: Char): List<Int> {
        val indexes = mutableListOf<Int>()
        var parenDepth = 0
        var bracketDepth = 0
        var braceDepth = 0
        var inSingleQuote = false
        var inDoubleQuote = false
        var inTemplate = false
        var inRegex = false
        var inRegexCharClass = false
        var inLineComment = false
        var inBlockComment = false
        var escapeNext = false
        var previousSignificant: Char? = null

        script.forEachIndexed { index, char ->
            if (inLineComment) {
                if (char == '\n') {
                    inLineComment = false
                    if (target == '\n' && parenDepth == 0 && bracketDepth == 0 && braceDepth == 0) {
                        indexes += index
                    }
                }
                return@forEachIndexed
            }
            if (inBlockComment) {
                if (char == '*' && index + 1 < script.length && script[index + 1] == '/') {
                    inBlockComment = false
                }
                return@forEachIndexed
            }
            if (escapeNext) {
                escapeNext = false
                return@forEachIndexed
            }
            when {
                inRegex -> {
                    when {
                        char == '\\' -> escapeNext = true
                        char == '[' -> inRegexCharClass = true
                        char == ']' -> inRegexCharClass = false
                        char == '/' && !inRegexCharClass -> {
                            inRegex = false
                            previousSignificant = '/'
                        }
                    }
                }
                inSingleQuote -> {
                    if (char == '\\') {
                        escapeNext = true
                    } else if (char == '\'') {
                        inSingleQuote = false
                        previousSignificant = '\''
                    }
                }
                inDoubleQuote -> {
                    if (char == '\\') {
                        escapeNext = true
                    } else if (char == '"') {
                        inDoubleQuote = false
                        previousSignificant = '"'
                    }
                }
                inTemplate -> {
                    if (char == '\\') {
                        escapeNext = true
                    } else if (char == '`') {
                        inTemplate = false
                        previousSignificant = '`'
                    }
                }
                char == '/' && index + 1 < script.length && script[index + 1] == '/' -> {
                    inLineComment = true
                }
                char == '/' && index + 1 < script.length && script[index + 1] == '*' -> {
                    inBlockComment = true
                }
                char == '/' && shouldStartRegexLiteral(previousSignificant) -> {
                    inRegex = true
                    inRegexCharClass = false
                }
                char == '\'' -> inSingleQuote = true
                char == '"' -> inDoubleQuote = true
                char == '`' -> inTemplate = true
                else -> {
                    when (char) {
                        '(' -> parenDepth += 1
                        ')' -> if (parenDepth > 0) parenDepth -= 1
                        '[' -> bracketDepth += 1
                        ']' -> if (bracketDepth > 0) bracketDepth -= 1
                        '{' -> braceDepth += 1
                        '}' -> if (braceDepth > 0) braceDepth -= 1
                    }
                    if (char == target && parenDepth == 0 && bracketDepth == 0 && braceDepth == 0) {
                        indexes += index
                    }
                    if (!char.isWhitespace()) {
                        previousSignificant = char
                    }
                }
            }
        }
        return indexes
    }

    private fun shouldStartRegexLiteral(previousSignificant: Char?): Boolean {
        return previousSignificant == null ||
            previousSignificant in charArrayOf(
                '(', '[', '{', ',', ':', ';', '=',
                '!', '?', '+', '-', '*', '%',
                '&', '|', '^', '~', '<', '>'
            )
    }

    /**
     * Execute JavaScript code with timeout
     * @param script JavaScript code
     * @param context Execution context
     * @param timeoutMs Timeout in milliseconds
     * @return Execution result
     */
    suspend fun executeWithTimeout(
        script: String,
        context: JsContext = JsContext(),
        timeoutMs: Long = 5000L
    ): JsResult {
        val contextWithTimeout = context.copy(timeoutMs = timeoutMs)
        return execute(script, contextWithTimeout)
    }

    /**
     * Execute JavaScript code with variables
     * @param code JavaScript code
     * @param variables Variables to set before execution
     * @return Execution result
     */
    suspend fun execute(
        code: String,
        variables: Map<String, Any?>
    ): JsResult {
        val context = JsContext(variables = variables)
        return execute(code, context)
    }

    /**
     * Execute JavaScript code and get string result
     * @param code JavaScript code
     * @param variables Variables to set before execution
     * @param defaultValue Default value if execution fails
     * @return Result as string
     */
    suspend fun executeAsString(
        code: String,
        variables: Map<String, Any?> = emptyMap(),
        defaultValue: String = ""
    ): String {
        val result = execute(code, variables)
        return when (result) {
            is JsResult.JsString -> result.value
            is JsResult.JsError -> defaultValue
            else -> result.asString()
        }
    }

    /**
     * Evaluate JavaScript expression (alias for execute)
     * @param expression JavaScript expression
     * @param variables Optional variables
     * @return Evaluation result
     */
    suspend fun eval(
        expression: String,
        variables: Map<String, Any?> = emptyMap()
    ): JsResult {
        return execute(expression, variables)
    }

    /**
     * Check if JavaScript code is valid
     * @param code JavaScript code
     * @return True if code is syntactically valid
     */
    suspend fun isValid(code: String): Boolean {
        return try {
            val result = execute(code)
            result.isSuccess
        } catch (e: Exception) {
            false
        }
    }

    /**
     * Execute JavaScript with a persistent context
     * @param block Operation to perform with the context
     * @return Result of the operation
     */
    suspend fun <T> withContext(block: suspend (JsContext) -> T): T {
        val context = JsContext()
        return block(context)
    }

    /** Create an isolated, mutable realm, and release it on completion, failure or cancellation. */
    suspend fun <T> withMutableContext(
        context: JsContext = JsContext(),
        block: suspend (JsMutableContext) -> T
    ): T {
        val mutableContext = QuickJsMutableContext(context)
        return try {
            coroutineScope { block(mutableContext) }
        } finally {
            mutableContext.close()
        }
    }

    companion object {
        val Default: JsExecutor = JsExecutor()
    }

    private fun Char.isScriptIdentifierPart(): Boolean {
        return isLetterOrDigit() || this == '_' || this == '$'
    }
}

/**
 * Safe JavaScript executor with sandbox protection
 */
class SafeJsExecutor(
    private val executor: JsExecutor = JsExecutor.Default,
    private val config: SafeConfig = SafeConfig()
) {

    data class SafeConfig(
        val maxScriptLength: Int = 10000,
        val maxExecutionTime: Long = 5000L,
        val allowDangerousPatterns: Boolean = false,
    )

    /**
     * Execute JavaScript with safety checks
     */
    suspend fun execute(script: String, context: JsContext = JsContext()): JsResult {
        // Check script length
        if (script.length > config.maxScriptLength) {
            return JsResult.JsError("Script too long (max ${config.maxScriptLength} characters)")
        }

        // Check for dangerous patterns
        if (!config.allowDangerousPatterns && !isScriptSafe(script)) {
            return JsResult.JsError("Unsafe script detected")
        }

        // Execute with timeout
        return executor.executeWithTimeout(
            script,
            context,
            config.maxExecutionTime
        )
    }

    /**
     * Check if script contains dangerous patterns
     */
    private fun isScriptSafe(script: String): Boolean {
        val dangerousPatterns = listOf(
            Regex("while\\s*\\(\\s*true\\s*\\)", RegexOption.IGNORE_CASE),
            Regex("for\\s*\\(\\s*;\\s*;\\s*\\)", RegexOption.IGNORE_CASE),
            Regex("while\\s*\\(\\s*1\\s*\\)", RegexOption.IGNORE_CASE),
            Regex("eval\\s*\\(", RegexOption.IGNORE_CASE),
            Regex("Function\\s*\\(", RegexOption.IGNORE_CASE),
        )
        return !dangerousPatterns.any { it.containsMatchIn(script) }
    }
}
