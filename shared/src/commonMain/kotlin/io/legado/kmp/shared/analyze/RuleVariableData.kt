package io.legado.kmp.shared.analyze

import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.source.RuleBigVariableScope
import io.legado.kmp.shared.source.SourceStateStore
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.runBlocking
import kotlin.coroutines.ContinuationInterceptor
import kotlin.coroutines.CoroutineContext
import kotlin.coroutines.EmptyCoroutineContext

/** Small values belong to model JSON; large values belong to identity-scoped persistent rows. */
internal class RuleVariableData(
    private val store: SourceStateStore?,
    private var scope: RuleBigVariableScope?,
    initialVariables: Map<String, String> = emptyMap(),
    override val bookSource: BookSource? = null,
    var executionContext: CoroutineContext = EmptyCoroutineContext
) : RuleDataInterface {
    override val variableMap = linkedMapOf<String, String>()
    private val pendingBig = linkedMapOf<String, String?>()

    init {
        initialVariables.forEach { (key, value) ->
            if (key.startsWith("__big__")) {
                putBigVariable(key.removePrefix("__big__"), value)
            } else if (value.length >= 10000) putBigVariable(key, value)
            else variableMap[key] = value
        }
    }

    override fun putVariable(key: String, value: String?): Boolean {
        val existed = variableMap.containsKey(key)
        putBigVariable(key, value?.takeIf { it.length >= 10000 })
        if (value == null || value.length >= 10000) variableMap.remove(key) else variableMap[key] = value
        return if (value != null && value.length < 10000) true else existed
    }

    fun bindScope(scope: RuleBigVariableScope?) {
        this.scope = scope
        if (scope != null && store != null && pendingBig.isNotEmpty()) {
            pendingBig.toMap().forEach { (key, value) ->
                blocking { store.putBigVariable(scope, key, value) }
                pendingBig.remove(key)
            }
        }
    }

    override fun putBigVariable(key: String, value: String?) {
        val identity = scope
        if (identity != null && store != null) {
            blocking { store.putBigVariable(identity, key, value) }
        } else {
            pendingBig[key] = value
        }
    }

    override fun getBigVariable(key: String): String? {
        val identity = scope
        return if (identity != null && store != null) {
            blocking { store.getBigVariable(identity, key) }
        } else pendingBig[key]
    }

    override fun getVariables(): Map<String, String> = buildMap {
        putAll(variableMap)
        // A caller without durable storage must not silently lose large values on serialization.
        if (store == null || scope == null) pendingBig.forEach { (key, value) ->
            if (value != null) put(key, value)
        }
    }

    fun <T> blocking(block: suspend () -> T): T =
        runBlocking(executionContext.minusKey(ContinuationInterceptor)) {
            ensureActive()
            block()
        }
}
