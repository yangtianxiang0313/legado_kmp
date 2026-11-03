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

                        // Null/undefined are valid results; retrying would repeat script side effects.
                        val result = quickJs.evaluate<Any?>(fullScript)
                        JsResult.fromAny(result)
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
