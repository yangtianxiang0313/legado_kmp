package io.legado.kmp.shared.scripting

import com.dokar.quickjs.QuickJs
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.JsonPrimitive
import kotlin.coroutines.coroutineContext

/**
 * Bindings live in one JavaScript realm until the enclosing withMutableContext block finishes.
 * Each execution replaces only the supplied globals; it does not write back to the input maps.
 * JsMutableObject values explicitly opt into live property/method write-through instead.
 */
interface JsMutableContext {
    suspend fun execute(code: String, variables: Map<String, Any?> = emptyMap()): JsResult

    suspend fun executeAsString(
        code: String,
        variables: Map<String, Any?> = emptyMap(),
        defaultValue: String = ""
    ): String {
        return when (val result = execute(code, variables)) {
            is JsResult.JsError -> defaultValue
            else -> result.asString()
        }
    }
}

internal class QuickJsMutableContext(context: JsContext) : JsMutableContext {
    private val initialVariables = context.variables.toMap()
    private val timeoutMs = context.timeoutMs
    private val mutex = Mutex()
    private val mutableObjects = QuickJsMutableObjectBridge()
    private var quickJs: QuickJs? = null
    private var initialized = false
    private var closed = false

    override suspend fun execute(code: String, variables: Map<String, Any?>): JsResult {
        return try {
            withContext(Dispatchers.Default) {
                mutex.withLock {
                    check(!closed) { "JavaScript mutable context is closed" }
                    withTimeout(timeoutMs) {
                        mutableObjects.executionContext = coroutineContext
                        val engine = quickJs ?: QuickJs.create(Dispatchers.Default).also { quickJs = it }
                        if (!initialized) {
                            mutableObjects.install(engine)
                            setBindings(engine, initialVariables)
                            initialized = true
                        }
                        setBindings(engine, variables)
                        // Never replay the script to recover a result: mutations must happen only once.
                        JsResult.fromAny(engine.evaluate<Any?>(code))
                    }
                }
            }
        } catch (timeout: TimeoutCancellationException) {
            coroutineContext.ensureActive()
            JsResult.JsError("Script execution timed out", timeout)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            coroutineContext.ensureActive()
            JsResult.JsError(
                message = error.message ?: "Unknown error",
                exception = error,
                stackTrace = error.stackTraceToString()
            )
        }
    }

    suspend fun close() {
        withContext(NonCancellable + Dispatchers.Default) {
            mutex.withLock {
                closed = true
                try {
                    quickJs?.close()
                } finally {
                    quickJs = null
                    mutableObjects.clear()
                }
            }
        }
    }

    private suspend fun setBindings(engine: QuickJs, variables: Map<String, Any?>) {
        if (variables.isEmpty()) return
        val script = buildString {
            appendLine("(function(global) {")
            variables.forEach { (name, value) ->
                append("global[")
                append(JsonPrimitive(name))
                append("] = ")
                append(mutableObjects.literal(value))
                appendLine(";")
            }
            appendLine("})(globalThis);")
        }
        engine.evaluate<Any?>(script)
    }
}
