package io.legado.kmp.shared.domain.webBook

import io.legado.kmp.shared.analyze.RuleVariableData
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.serializeVariableMap
import io.legado.kmp.shared.scripting.JsMutableObject
import io.legado.kmp.shared.source.RuleBigVariableScope
import io.legado.kmp.shared.source.SourceStateStore
import kotlin.coroutines.CoroutineContext
import kotlin.coroutines.EmptyCoroutineContext

/** A retained JS reference always observes and updates the latest immutable chapter snapshot. */
internal class FormatJsChapterBinding(
    private var chapter: BookChapter,
    sourceStateStore: SourceStateStore? = null,
    private val sourceKey: String? = null,
    executionContext: CoroutineContext = EmptyCoroutineContext,
    private val publish: (BookChapter) -> Unit
) : JsMutableObject {
    private val variableData = RuleVariableData(
        sourceStateStore, scope(), chapter.variableMap, executionContext = executionContext
    )
    private val variableBinding by lazy { FormatJsVariableMap(variableData, ::publishVariables) }

    override val propertyNames: List<String> = listOf(
        "url", "title", "volume", "baseUrl", "bookUrl", "index", "vip", "pay", "resourceUrl",
        "tag", "wordCount", "start", "end", "startFragmentId", "endFragmentId", "variable", "variableMap"
    )

    override val methodNames: List<String> = (propertyNames.flatMap { name ->
        val suffix = name.replaceFirstChar { it.uppercaseChar() }
        val getter = if (name in BOOLEAN_PROPERTIES) "is$suffix" else "get$suffix"
        if (name == "variableMap") listOf(getter) else listOf(getter, "set$suffix")
    } + listOf(
        "getVariable", "putVariable", "getBigVariable", "putBigVariable", "primaryStr",
        "getAbsoluteURL", "getDisplayTitle", "getFileName"
    )).distinct()

    override fun updateExecutionContext(context: CoroutineContext) {
        variableData.executionContext = context
    }

    override fun getProperty(name: String): Any? = when (name) {
        "url" -> chapter.url
        "title" -> chapter.title
        "volume" -> chapter.isVolume
        "baseUrl" -> chapter.baseUrl
        "bookUrl" -> chapter.bookUrl
        "index" -> chapter.index
        "vip" -> chapter.isVip
        "pay" -> chapter.isPay
        "resourceUrl" -> chapter.resourceUrl
        "tag" -> chapter.tag
        "wordCount" -> chapter.wordCount
        "start" -> chapter.start
        "end" -> chapter.end
        "startFragmentId" -> chapter.startFragmentId
        "endFragmentId" -> chapter.endFragmentId
        "variable" -> chapter.variable
        "variableMap" -> variableBinding
        else -> error("Unknown chapter property: $name")
    }

    override fun setProperty(name: String, value: Any?) {
        chapter = when (name) {
            "url" -> chapter.copy(url = requiredString(name, value))
            "title" -> chapter.copy(title = requiredString(name, value))
            "volume" -> chapter.copy(isVolume = boolean(value))
            "baseUrl" -> chapter.copy(baseUrl = requiredString(name, value))
            "bookUrl" -> chapter.copy(bookUrl = requiredString(name, value))
            "index" -> chapter.copy(index = requireNotNull(number(value)) { "index must be a number" }.toInt())
            "vip" -> chapter.copy(isVip = boolean(value))
            "pay" -> chapter.copy(isPay = boolean(value))
            "resourceUrl" -> chapter.copy(resourceUrl = value?.toString())
            "tag" -> chapter.copy(tag = value?.toString())
            "wordCount" -> chapter.copy(wordCount = value?.toString())
            "start" -> chapter.copy(start = number(value))
            "end" -> chapter.copy(end = number(value))
            "startFragmentId" -> chapter.copy(startFragmentId = value?.toString())
            "endFragmentId" -> chapter.copy(endFragmentId = value?.toString())
            "variable" -> {
                variableBinding.replaceVariables(io.legado.kmp.shared.model.parseVariableMap(value?.toString()))
                chapter.copy(variable = value?.toString())
            }
            else -> error("Chapter property is not writable: $name")
        }
        if (name == "url" || name == "bookUrl") variableData.bindScope(scope())
        publish(chapter)
    }

    override fun invoke(name: String, arguments: List<Any?>): Any? {
        return when (name) {
            "getVariable" -> if (arguments.isEmpty()) chapter.variable
                else variableData.getVariable(requiredString("key", arguments.firstOrNull()))
            "putVariable" -> {
                val key = requiredString("key", arguments.firstOrNull())
                val value = arguments.getOrNull(1)?.toString()
                variableBinding.putVariable(key, value)
                true
            }
            "getBigVariable" -> variableData.getBigVariable(requiredString("key", arguments.firstOrNull()))
            "putBigVariable" -> {
                variableData.putBigVariable(
                    requiredString("key", arguments.firstOrNull()), arguments.getOrNull(1)?.toString()
                )
                null
            }
            "primaryStr" -> chapter.primaryStr()
            "getAbsoluteURL" -> chapter.getAbsoluteURL()
            "getDisplayTitle" -> chapter.getDisplayTitle()
            "getFileName" -> chapter.getFileName(arguments.firstOrNull()?.toString() ?: "nb")
            else -> {
                val property = propertyNames.firstOrNull { property ->
                    val suffix = property.replaceFirstChar { it.uppercaseChar() }
                    name == "get$suffix" || name == "set$suffix"
                        || (property in BOOLEAN_PROPERTIES && name == "is$suffix")
                } ?: error("Unknown chapter method: $name")
                if (name.startsWith("set")) {
                    setProperty(property, arguments.firstOrNull())
                    null
                } else {
                    getProperty(property)
                }
            }
        }
    }

    private fun requiredString(name: String, value: Any?): String =
        requireNotNull(value) { "$name must not be null" }.toString()

    private fun publishVariables() {
        chapter = chapter.copy(variable = serializeVariableMap(variableData.getVariables()).ifEmpty { "{}" })
        publish(chapter)
    }

    private fun scope(): RuleBigVariableScope? {
        val key = sourceKey?.takeIf { it.isNotBlank() } ?: return null
        if (chapter.bookUrl.isBlank() || chapter.url.isBlank()) return null
        return RuleBigVariableScope(key, chapter.bookUrl, chapter.url)
    }

    private fun number(value: Any?): Long? = when (value) {
        null -> null
        is Number -> value.toLong()
        else -> requireNotNull(value.toString().toDoubleOrNull()) { "Expected a number" }.toLong()
    }

    private fun boolean(value: Any?): Boolean = when (value) {
        null -> false
        is Boolean -> value
        is Number -> value.toDouble().let { it != 0.0 && !it.isNaN() }
        is String -> value.isNotEmpty()
        else -> true
    }

    private companion object {
        val BOOLEAN_PROPERTIES = setOf("volume", "vip", "pay")
    }
}
