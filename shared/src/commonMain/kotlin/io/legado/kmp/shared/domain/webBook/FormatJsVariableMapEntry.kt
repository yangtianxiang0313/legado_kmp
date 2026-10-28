package io.legado.kmp.shared.domain.webBook

import io.legado.kmp.shared.scripting.JsMutableObject
import kotlin.coroutines.CoroutineContext

/** Entry identity follows the map node, not just the key that could later be reinserted. */
internal class FormatJsVariableMapEntry(
    private val owner: FormatJsVariableMap,
    private val node: FormatJsVariableMapNode
) : JsMutableObject {
    internal val key: String get() = node.key
    internal val value: String get() = node.value

    override val propertyNames: List<String> = emptyList()
    override val methodNames: List<String> = listOf("getKey", "getValue", "setValue", "equals", "hashCode", "toString")

    override fun updateExecutionContext(context: CoroutineContext) {
        owner.updateExecutionContext(context)
    }

    override fun getProperty(name: String): Any? = error("Unknown entry property: $name")

    override fun setProperty(name: String, value: Any?) {
        error("Entry properties are not writable: $name")
    }

    override fun invoke(name: String, arguments: List<Any?>): Any? = when (name) {
        "getKey" -> key
        "getValue" -> value
        "setValue" -> owner.setEntryValue(node, formatJsVariableString(arguments.firstOrNull()))
        "equals" -> (arguments.firstOrNull() as? FormatJsVariableMapEntry)?.let {
            key == it.key && value == it.value
        } ?: false
        "hashCode" -> key.hashCode() xor value.hashCode()
        "toString" -> "$key=$value"
        else -> error("Unknown entry method: $name")
    }
}
