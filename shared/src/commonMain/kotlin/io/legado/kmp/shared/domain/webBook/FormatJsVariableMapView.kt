package io.legado.kmp.shared.domain.webBook

import io.legado.kmp.shared.scripting.JsMutableObject
import kotlin.coroutines.CoroutineContext

/** A Java collection view, not a JS array; only toArray produces a snapshot of the elements. */
internal class FormatJsVariableMapView(
    private val owner: FormatJsVariableMap,
    private val kind: Kind
) : JsMutableObject {
    internal enum class Kind { KEYS, VALUES, ENTRIES }

    override val propertyNames: List<String> = emptyList()
    override val methodNames: List<String> = listOf(
        "size", "isEmpty", "contains", "remove", "clear", "toArray", "iterator", "add", "addAll"
    )

    override fun updateExecutionContext(context: CoroutineContext) {
        owner.updateExecutionContext(context)
    }

    override fun getProperty(name: String): Any? = error("Unknown collection property: $name")

    override fun setProperty(name: String, value: Any?) {
        error("Collection properties are not writable: $name")
    }

    override fun invoke(name: String, arguments: List<Any?>): Any? = when (name) {
        "size" -> owner.size()
        "isEmpty" -> owner.size() == 0
        "contains" -> contains(arguments.firstOrNull())
        "remove" -> remove(arguments.firstOrNull())
        "clear" -> { owner.clear(); null }
        "toArray" -> {
            if (arguments.isNotEmpty()) {
                throw UnsupportedOperationException("UnsupportedOperationException: use toArray() without a target array")
            }
            owner.currentNodes().map(::element)
        }
        "iterator" -> FormatJsVariableMapIterator(owner, this)
        "add", "addAll" -> throw UnsupportedOperationException("UnsupportedOperationException: Map views cannot add elements")
        else -> error("Unknown collection method: $name")
    }

    internal fun element(node: FormatJsVariableMapNode): Any = when (kind) {
        Kind.KEYS -> node.key
        Kind.VALUES -> node.value
        Kind.ENTRIES -> owner.entry(node)
    }

    private fun contains(value: Any?): Boolean = when (kind) {
        Kind.KEYS -> value is String && owner.containsKey(value)
        Kind.VALUES -> value is String && owner.containsValue(value)
        Kind.ENTRIES -> value is FormatJsVariableMapEntry && owner.containsEntry(value)
    }

    private fun remove(value: Any?): Boolean {
        val key = when (kind) {
            Kind.KEYS -> (value as? String)?.takeIf(owner::containsKey)
            Kind.VALUES -> owner.currentNodes().firstOrNull { it.value == value }?.key
            Kind.ENTRIES -> (value as? FormatJsVariableMapEntry)?.takeIf(owner::containsEntry)?.key
        } ?: return false
        owner.remove(key)
        return true
    }
}

internal class FormatJsVariableMapIterator(
    private val owner: FormatJsVariableMap,
    private val view: FormatJsVariableMapView
) : JsMutableObject {
    private val nodes = owner.currentNodes()
    private var expectedVersion = owner.structuralVersion
    private var cursor = 0
    private var current: FormatJsVariableMapNode? = null

    override val propertyNames: List<String> = emptyList()
    override val methodNames: List<String> = listOf("hasNext", "next", "remove")

    override fun updateExecutionContext(context: CoroutineContext) {
        owner.updateExecutionContext(context)
    }

    override fun getProperty(name: String): Any? = error("Unknown iterator property: $name")

    override fun setProperty(name: String, value: Any?) {
        error("Iterator properties are not writable: $name")
    }

    override fun invoke(name: String, arguments: List<Any?>): Any? = when (name) {
        // Java checks for structural modification in next/remove, not hasNext.
        "hasNext" -> cursor < nodes.size
        "next" -> {
            checkForModification()
            if (cursor >= nodes.size) throw NoSuchElementException("NoSuchElementException: iterator exhausted")
            val node = nodes[cursor++]
            current = node
            view.element(node)
        }
        "remove" -> {
            val node = current ?: throw IllegalStateException("IllegalStateException: next() must precede remove()")
            checkForModification()
            owner.remove(node.key)
            expectedVersion = owner.structuralVersion
            current = null
            null
        }
        else -> error("Unknown iterator method: $name")
    }

    private fun checkForModification() {
        if (expectedVersion != owner.structuralVersion) {
            throw ConcurrentModificationException("ConcurrentModificationException: chapter variable map changed")
        }
    }
}
