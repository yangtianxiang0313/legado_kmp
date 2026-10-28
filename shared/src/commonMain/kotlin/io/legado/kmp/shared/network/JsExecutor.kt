package io.legado.kmp.shared.network

import io.legado.kmp.shared.scripting.JsContext
import io.legado.kmp.shared.scripting.JsMutableContext
import io.legado.kmp.shared.scripting.JsResult
import io.legado.kmp.shared.scripting.JsExecutor as ScriptingJsExecutor

/**
 * JavaScript executor - backward compatibility wrapper
 * Delegates to the new scripting module
 */
class JsExecutor(
    private val delegateProvider: (() -> Delegate)? = null
) {

    private val delegate: Delegate by lazy(LazyThreadSafetyMode.NONE) {
        delegateProvider?.invoke() ?: defaultDelegate()
    }

    interface Delegate {
        suspend fun execute(code: String, variables: Map<String, Any?> = emptyMap()): JsResult

        suspend fun executeAsString(
            code: String,
            variables: Map<String, Any?> = emptyMap(),
            defaultValue: String = ""
        ): String

        suspend fun executeAsInt(
            code: String,
            variables: Map<String, Any?> = emptyMap(),
            defaultValue: Int = 0
        ): Int

        suspend fun eval(expression: String, variables: Map<String, Any?> = emptyMap()): JsResult

        suspend fun isValid(code: String): Boolean

        suspend fun <T> withContext(block: suspend (JsContext) -> T): T

        suspend fun <T> withMutableContext(
            variables: Map<String, Any?> = emptyMap(),
            block: suspend (JsMutableContext) -> T
        ): T {
            throw SharedCapabilityException(
                capabilityGapKey = "mutable_js_context_unsupported",
                message = "This JavaScript delegate does not support mutable contexts"
            )
        }
    }

    /**
     * Execute JavaScript code
     *
     * @param code JavaScript code to execute
     * @param variables Optional variables to set before execution
     * @return Execution result
     */
    suspend fun execute(
        code: String,
        variables: Map<String, Any?> = emptyMap()
    ): JsResult {
        return delegate.execute(code, variables)
    }

    /**
     * Execute JavaScript code and get string result
     *
     * @param code JavaScript code
     * @param variables Optional variables
     * @param defaultValue Default value if execution fails
     * @return Result as string
     */
    suspend fun executeAsString(
        code: String,
        variables: Map<String, Any?> = emptyMap(),
        defaultValue: String = ""
    ): String {
        return delegate.executeAsString(code, variables, defaultValue)
    }

    /**
     * Execute JavaScript code and get Int result
     *
     * @param code JavaScript code to execute
     * @param variables Optional variables
     * @param defaultValue Default value if conversion fails
     * @return Result as Int
     */
    suspend fun executeAsInt(
        code: String,
        variables: Map<String, Any?> = emptyMap(),
        defaultValue: Int = 0
    ): Int {
        val result = execute(code, variables)
        return when (result) {
            is JsResult.JsNumber -> result.value.toInt()
            is JsResult.JsString -> result.value.toIntOrNull() ?: defaultValue
            else -> defaultValue
        }
    }

    /**
     * Evaluate JavaScript expression
     *
     * @param expression JavaScript expression to evaluate
     * @param variables Optional variables
     * @return Evaluation result
     */
    suspend fun eval(
        expression: String,
        variables: Map<String, Any?> = emptyMap()
    ): JsResult {
        return delegate.eval(expression, variables)
    }

    /**
     * Check if JavaScript code is valid
     *
     * @param code JavaScript code to validate
     * @return True if code is syntactically valid
     */
    suspend fun isValid(code: String): Boolean {
        return delegate.isValid(code)
    }

    /**
     * Execute JavaScript with a persistent context
     * Useful for multiple operations in the same context
     *
     * @param block Operation to perform with the context
     * @return Result of the operation
     */
    suspend fun <T> withContext(block: suspend (JsContext) -> T): T {
        return delegate.withContext(block)
    }

    /** Reuse mutable bindings only within this block, without changing stateless execution. */
    suspend fun <T> withMutableContext(
        variables: Map<String, Any?> = emptyMap(),
        block: suspend (JsMutableContext) -> T
    ): T {
        return delegate.withMutableContext(variables, block)
    }

    companion object {
        /**
         * Default instance
         */
        val Default: JsExecutor = JsExecutor()

        private fun defaultDelegate(): Delegate {
            return try {
                QuickJsDelegate
            } catch (error: Throwable) {
                FailedDelegate(error)
            }
        }
    }

    fun runtimeCapabilityFailure(): SharedCapabilityException? {
        return (delegate as? FailedDelegate)?.asCapabilityException()
    }
}

open class SharedCapabilityException(
    val capabilityGapKey: String,
    override val message: String,
    override val cause: Throwable? = null
) : IllegalStateException(message, cause)

class JsRuntimeUnavailableException(
    cause: Throwable
) : SharedCapabilityException(
    capabilityGapKey = "quickjs_runtime_missing",
    message = "JavaScript runtime initialization failed",
    cause = cause
)

private object QuickJsDelegate : JsExecutor.Delegate {
    private val delegate = ScriptingJsExecutor.Default

    override suspend fun execute(code: String, variables: Map<String, Any?>): JsResult {
        return delegate.execute(code, variables)
    }

    override suspend fun executeAsString(
        code: String,
        variables: Map<String, Any?>,
        defaultValue: String
    ): String {
        return delegate.executeAsString(code, variables, defaultValue)
    }

    override suspend fun executeAsInt(
        code: String,
        variables: Map<String, Any?>,
        defaultValue: Int
    ): Int {
        val result = delegate.execute(code, variables)
        return when (result) {
            is JsResult.JsNumber -> result.value.toInt()
            is JsResult.JsString -> result.value.toIntOrNull() ?: defaultValue
            else -> defaultValue
        }
    }

    override suspend fun eval(expression: String, variables: Map<String, Any?>): JsResult {
        return delegate.eval(expression, variables)
    }

    override suspend fun isValid(code: String): Boolean {
        return delegate.isValid(code)
    }

    override suspend fun <T> withContext(block: suspend (JsContext) -> T): T {
        return delegate.withContext(block)
    }

    override suspend fun <T> withMutableContext(
        variables: Map<String, Any?>,
        block: suspend (JsMutableContext) -> T
    ): T {
        return delegate.withMutableContext(JsContext(variables = variables), block)
    }
}

private class FailedDelegate(
    private val cause: Throwable
) : JsExecutor.Delegate {

    fun asCapabilityException(): JsRuntimeUnavailableException {
        return when (cause) {
            is JsRuntimeUnavailableException -> cause
            else -> JsRuntimeUnavailableException(cause)
        }
    }

    private fun jsError(message: String): JsResult.JsError {
        val capability = asCapabilityException()
        return JsResult.JsError(
            message = message,
            exception = capability,
            stackTrace = capability.stackTraceToString()
        )
    }

    override suspend fun execute(code: String, variables: Map<String, Any?>): JsResult {
        return jsError("JavaScript runtime initialization failed")
    }

    override suspend fun executeAsString(
        code: String,
        variables: Map<String, Any?>,
        defaultValue: String
    ): String {
        throw asCapabilityException()
    }

    override suspend fun executeAsInt(
        code: String,
        variables: Map<String, Any?>,
        defaultValue: Int
    ): Int {
        throw asCapabilityException()
    }

    override suspend fun eval(expression: String, variables: Map<String, Any?>): JsResult {
        return jsError("JavaScript runtime initialization failed")
    }

    override suspend fun isValid(code: String): Boolean = throw asCapabilityException()

    override suspend fun <T> withContext(block: suspend (JsContext) -> T): T {
        return block(JsContext())
    }

    override suspend fun <T> withMutableContext(
        variables: Map<String, Any?>,
        block: suspend (JsMutableContext) -> T
    ): T {
        throw asCapabilityException()
    }
}

/**
 * Extension to execute JavaScript code from string
 */
suspend fun String.evalJs(variables: Map<String, Any?> = emptyMap()): JsResult {
    return JsExecutor.Default.eval(this, variables)
}

/**
 * Extension to execute JavaScript and get string result
 */
suspend fun String.evalJsAsString(
    variables: Map<String, Any?> = emptyMap(),
    defaultValue: String = ""
): String {
    return JsExecutor.Default.executeAsString(this, variables, defaultValue)
}

/**
 * Extension to execute JavaScript and get Int result
 */
suspend fun String.evalJsAsInt(
    variables: Map<String, Any?> = emptyMap(),
    defaultValue: Int = 0
): Int {
    return JsExecutor.Default.executeAsInt(this, variables, defaultValue)
}
