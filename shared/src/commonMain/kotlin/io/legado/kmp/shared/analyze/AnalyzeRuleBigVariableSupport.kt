package io.legado.kmp.shared.analyze

import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.scripting.JsLegacyModelBinding
import io.legado.kmp.shared.source.RuleBigVariableScope
import io.legado.kmp.shared.source.SourceStateStore
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlin.coroutines.ContinuationInterceptor
import kotlin.coroutines.CoroutineContext
import kotlin.coroutines.EmptyCoroutineContext

internal class AnalyzeRuleBigVariableSupport(
    private val source: BookSource?,
    private val store: SourceStateStore?
) {
    private var book: Book? = null
    private var chapter: BookChapter? = null
    private var bookData: RuleVariableData? = null
    private var chapterData: RuleVariableData? = null
    var executionContext: CoroutineContext = EmptyCoroutineContext
        set(value) {
            field = value
            bookData?.executionContext = value
            chapterData?.executionContext = value
        }

    val activeData: RuleVariableData? get() = chapterData ?: bookData

    val bookVariables: Map<String, String>? get() = bookData?.getVariables()

    fun bindingVariables(): Map<String, String> = bookData?.getVariables().orEmpty() +
        chapterData?.getVariables().orEmpty()

    fun reset() {
        book = null
        chapter = null
        bookData = null
        chapterData = null
    }

    fun inheritBookState(parent: AnalyzeRuleBigVariableSupport) {
        require(book?.bookUrl == parent.book?.bookUrl && book?.origin == parent.book?.origin) {
            "Rule variable contexts must refer to the same book"
        }
        bookData = parent.bookData
    }

    fun setBook(value: Book?, seedVariables: Map<String, String>? = null) {
        if (value == null || book?.bookUrl != value.bookUrl || book?.origin != value.origin) {
            bookData = value?.let {
                RuleVariableData(store, scope(it), seedVariables ?: it.variableMap, source, executionContext)
            }
        }
        book = value
    }

    fun setChapter(value: BookChapter?) {
        val previous = chapter
        val sameChapter = value != null && previous != null && previous.bookUrl == value.bookUrl &&
            (previous.url == value.url || (previous.url.isEmpty() && previous.index == value.index))
        if (value == null) chapterData = null else if (sameChapter) {
            // TOC rules can write variables before the chapter URL has been resolved.
            chapterData?.bindScope(scope(value))
        } else {
            chapterData = RuleVariableData(store, scope(value), value.variableMap, source, executionContext)
        }
        chapter = value
    }

    fun getChapterVariable(key: String): String? = chapterData?.getVariable(key)

    fun getBookVariable(key: String): String? = bookData?.getVariable(key)

    fun getSourceBigVariable(key: String): String? {
        val identity = sourceScope() ?: return null
        return blocking { store?.getBigVariable(identity, key) }
    }

    fun putSourceBigVariable(key: String, value: String?) {
        val identity = sourceScope() ?: return
        blocking { store?.putBigVariable(identity, key, value) }
    }

    fun getBindingValue(key: String): String? {
        val request = JsLegacyModelBinding.request(key) ?: return null
        val data = data(request.scope)
        val value = when (request.operation) {
            "get" -> JsonPrimitive(if (request.scope == "source") {
                blocking { store?.getSourceVariableMap(sourceKey().orEmpty())?.get(request.key) }.orEmpty()
            } else data?.getVariable(request.key).orEmpty())
            "big" -> (if (request.scope == "source") getSourceBigVariable(request.key)
                else data?.getBigVariable(request.key))?.let(::JsonPrimitive) ?: JsonNull
            "map" -> JsonObject(smallVariables(request.scope).mapValues { JsonPrimitive(it.value) })
            "json" -> JsonPrimitive(if (request.scope == "source") {
                sourceKey()?.let { sourceKey -> blocking { store?.getSourceVariable(sourceKey) } }.orEmpty()
            } else JsonObject(smallVariables(request.scope).mapValues { JsonPrimitive(it.value) }).toString())
            else -> error("Unsupported rule variable read: ${request.operation}")
        }
        return value.toString()
    }

    fun putBindingValue(key: String, value: String?): Boolean {
        val request = JsLegacyModelBinding.request(key) ?: return false
        if (request.scope == "source") {
            val sourceKey = sourceKey() ?: return true
            when (request.operation) {
                "put", "mapPut" -> blocking { store?.putSourceVariable(sourceKey, request.key, value) }
                "putBig" -> putSourceBigVariable(request.key, value)
                "replace" -> blocking { store?.setSourceVariable(sourceKey, value) }
                else -> error("Unsupported rule variable write: ${request.operation}")
            }
        } else {
            val data = data(request.scope) ?: return true
            when (request.operation) {
                "put", "mapPut" -> data.putVariable(request.key, value)
                "putBig" -> data.putBigVariable(request.key, value)
                "replace" -> {
                    val replacement = io.legado.kmp.shared.model.parseVariableMap(value)
                    data.variableMap.keys.toList().forEach { data.putVariable(it, null) }
                    replacement.forEach { (name, item) -> data.putVariable(name, item) }
                }
                else -> error("Unsupported rule variable write: ${request.operation}")
            }
        }
        return true
    }

    fun bindingPreamble(): String = JsLegacyModelBinding.preamble(book != null, chapter != null, source != null)

    private fun smallVariables(scope: String): Map<String, String> = if (scope == "source") {
        val key = sourceKey()
        if (key == null) emptyMap() else blocking { store?.getSourceVariableMap(key) }.orEmpty()
            .filterValues { it.length < 10000 }
    } else data(scope)?.variableMap.orEmpty()

    private fun data(scope: String): RuleVariableData? = when (scope) {
        "book" -> bookData
        "chapter" -> chapterData
        "source" -> null
        else -> error("Unsupported rule variable scope: $scope")
    }

    private fun sourceKey(): String? = source?.bookSourceUrl?.takeIf { it.isNotBlank() }
        ?: book?.origin?.takeIf { it.isNotBlank() }

    private fun sourceScope(): RuleBigVariableScope? = sourceKey()?.let { RuleBigVariableScope(it) }

    private fun scope(book: Book): RuleBigVariableScope? = book.bookUrl.takeIf { it.isNotBlank() }?.let { url ->
        (source?.bookSourceUrl?.takeIf { it.isNotBlank() } ?: book.origin.takeIf { it.isNotBlank() })
            ?.let { RuleBigVariableScope(it, url) }
    }

    private fun scope(chapter: BookChapter): RuleBigVariableScope? {
        val key = sourceKey() ?: return null
        if (chapter.bookUrl.isBlank() || chapter.url.isBlank()) return null
        return RuleBigVariableScope(key, chapter.bookUrl, chapter.url)
    }

    private fun <T> blocking(block: suspend () -> T): T =
        runBlocking(executionContext.minusKey(ContinuationInterceptor)) {
            ensureActive()
            block()
        }
}
