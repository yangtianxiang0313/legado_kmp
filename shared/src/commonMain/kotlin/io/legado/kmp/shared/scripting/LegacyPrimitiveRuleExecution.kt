package io.legado.kmp.shared.scripting

import com.dokar.quickjs.quickJs
import io.legado.kmp.shared.analyze.LEGACY_DOM_INPUT_DESCRIPTORS_BINDING
import io.legado.kmp.shared.analyze.LEGACY_HTML_RESULT_KIND_BINDING
import io.legado.kmp.shared.analyze.LEGACY_JSON_INPUT_DESCRIPTORS_BINDING
import io.legado.kmp.shared.model.BookSource
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.IO
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout

/** No JavaScript is interpreted here: this only selects an unobservable bootstrap omission. */
internal suspend fun executeLegacyPrimitiveRule(
    script: String,
    source: BookSource,
    variables: Map<String, Any?>,
    timeoutMs: Long,
    sourceSnapshot: () -> String,
): JsResult? {
    if (!source.jsLib.isNullOrBlank() || !isLegacyPrimitiveExpression(script)) return null
    if (variables.keys.any { it !in PRIMITIVE_INPUTS }) return null
    if (variables[LEGACY_HTML_RESULT_KIND_BINDING] != null) return null
    for (key in listOf(LEGACY_DOM_INPUT_DESCRIPTORS_BINDING, LEGACY_JSON_INPUT_DESCRIPTORS_BINDING)) {
        val descriptors = variables[key]
        if (descriptors != null && (descriptors !is List<*> || descriptors.isNotEmpty())) return null
    }
    when (variables["result"]) {
        is String, is Boolean, is Int, is Long, is Float, is Double -> Unit
        else -> return null
    }

    return withContext(Dispatchers.IO) {
        try {
            withTimeout(timeoutMs) {
                currentCoroutineContext().ensureActive()
                quickJs(Dispatchers.Default) {
                    // Keep the exact input serializer and original expression. A fresh realm is
                    // consumed once; no host state, Java/DOM value, or library can enter this path.
                    evaluate<Any?>(buildVariablesCode(variables) + "\n" + sourceSnapshot() + "\nvoid 0;")
                    currentCoroutineContext().ensureActive()
                    JsResult.fromAny(evaluate<Any?>(script)).also { currentCoroutineContext().ensureActive() }
                }
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            // Evaluation already happened. Returning an error must not replay the full runtime.
            JsResult.JsError(error.message ?: "Unknown error", error, error.stackTraceToString())
        }
    }
}

private val PRIMITIVE_INPUTS = setOf(
    "result", "body", "src", "baseUrl", "title", "book", "chapter", "nextChapterUrl",
    "headerMap", "loginHeader", "sourceVariable",
    // Search request parameters are retained with online books before TOC parsing.
    "key", "searchKey", "page", "searchPage",
    LEGACY_HTML_RESULT_KIND_BINDING, LEGACY_DOM_INPUT_DESCRIPTORS_BINDING, LEGACY_JSON_INPUT_DESCRIPTORS_BINDING,
)
