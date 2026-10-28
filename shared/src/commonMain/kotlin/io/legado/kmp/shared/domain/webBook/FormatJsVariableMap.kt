package io.legado.kmp.shared.domain.webBook

import io.legado.kmp.shared.analyze.RuleVariableData
import io.legado.kmp.shared.scripting.JsMutableObject
import kotlin.coroutines.CoroutineContext

/** Retained maps and their views always publish into their original chapter binding. */
internal class FormatJsVariableMap(
    private val variableData: RuleVariableData,
    private val publish: () -> Unit
) : JsMutableObject {
    private val values get() = variableData.variableMap
    private val nodes = linkedMapOf<String, FormatJsVariableMapNode>().apply {
        variableData.variableMap.forEach { (key, value) -> put(key, FormatJsVariableMapNode(key, value)) }
    }
    private val keysView by lazy { FormatJsVariableMapView(this, FormatJsVariableMapView.Kind.KEYS) }
    private val valuesView by lazy { FormatJsVariableMapView(this, FormatJsVariableMapView.Kind.VALUES) }
    private val entriesView by lazy { FormatJsVariableMapView(this, FormatJsVariableMapView.Kind.ENTRIES) }

    internal var structuralVersion: Int = 0
        private set

    override val hasDynamicProperties: Boolean get() = true
    override val propertyNames: List<String> get() = values.keys.toList()
    override val methodNames: List<String> = listOf(
        "get", "put", "remove", "containsKey", "containsValue", "size", "isEmpty", "clear",
        "keySet", "values", "entrySet", "putAll"
    )

    override fun getProperty(name: String): Any? = values[name]

    override fun updateExecutionContext(context: CoroutineContext) {
        variableData.executionContext = context
    }

    override fun setProperty(name: String, value: Any?) {
        put(name, formatJsVariableString(value))
    }

    override fun removeProperty(name: String): Boolean {
        remove(name)
        return true
    }

    override fun invoke(name: String, arguments: List<Any?>): Any? = when (name) {
        "get" -> values[arguments.firstOrNull()?.toString()]
        "put" -> put(requireNotNull(arguments.firstOrNull()).toString(), formatJsVariableString(arguments.getOrNull(1)))
        "remove" -> remove(requireNotNull(arguments.firstOrNull()).toString())
        "containsKey" -> values.containsKey(arguments.firstOrNull()?.toString())
        "containsValue" -> values.containsValue(arguments.firstOrNull()?.toString())
        "size" -> values.size
        "isEmpty" -> values.isEmpty()
        "clear" -> { clear(); null }
        "keySet" -> keysView
        "values" -> valuesView
        "entrySet" -> entriesView
        "putAll" -> {
            val entries = when (val input = arguments.firstOrNull()) {
                is FormatJsVariableMap -> input.values.toMap()
                is Map<*, *> -> input
                else -> error("Expected a map")
            }
            entries.forEach { (key, value) -> setProperty(requireNotNull(key).toString(), value) }
            null
        }
        else -> error("Unknown variable map method: $name")
    }

    /** Chapter.putVariable retains its existing large-variable policy; direct Map writes do not use it. */
    fun putVariable(key: String, value: String?) {
        variableData.putVariable(key, value)
        val newValue = values[key]
        if (newValue == null) {
            if (nodes.remove(key) != null) structuralVersion++
        } else {
            updateNode(key, newValue)
        }
        publish()
    }

    fun replaceVariables(replacement: Map<String, String>) {
        values.clear()
        nodes.clear()
        structuralVersion++
        replacement.forEach { (key, value) ->
            values[key] = value
            updateNode(key, value)
        }
    }

    internal fun currentNodes(): List<FormatJsVariableMapNode> = nodes.values.toList()

    internal fun size(): Int = values.size

    internal fun containsKey(key: String): Boolean = values.containsKey(key)

    internal fun containsValue(value: String): Boolean = values.containsValue(value)

    internal fun containsEntry(entry: FormatJsVariableMapEntry): Boolean =
        values[entry.key] == entry.value

    internal fun entry(node: FormatJsVariableMapNode): FormatJsVariableMapEntry =
        node.entry ?: FormatJsVariableMapEntry(this, node).also { node.entry = it }

    internal fun remove(key: String): String? {
        val previous = values.remove(key) ?: return null
        nodes.remove(key)
        structuralVersion++
        publish()
        return previous
    }

    internal fun clear() {
        values.clear()
        nodes.clear()
        // Java HashMap/LinkedHashMap.clear invalidates iterators even when already empty.
        structuralVersion++
        publish()
    }

    internal fun setEntryValue(node: FormatJsVariableMapNode, value: String): String {
        val previous = node.value
        if (nodes[node.key] === node) {
            put(node.key, value)
        } else {
            // Removed entries remain detached, including after reinsertion of the same key.
            node.value = value
        }
        return previous
    }

    private fun put(key: String, value: String): String? {
        val previous = values.put(key, value)
        updateNode(key, value)
        publish()
        return previous
    }

    private fun updateNode(key: String, value: String) {
        val node = nodes[key]
        if (node == null) {
            nodes[key] = FormatJsVariableMapNode(key, value)
            structuralVersion++
        } else {
            node.value = value
        }
    }
}

internal class FormatJsVariableMapNode(val key: String, var value: String) {
    var entry: FormatJsVariableMapEntry? = null
}

internal fun formatJsVariableString(value: Any?): String =
    requireNotNull(value) { "Chapter variables must be strings" }.toString()
