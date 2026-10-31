package io.legado.kmp.shared.scripting

import com.fleeksoft.ksoup.nodes.Node

internal const val LEGACY_NATIVE_DOM_INPUT_BINDING = "__legacyNativeDomInputs"

/** Kotlin-only provenance. This value must never be serialized into the script's bindings. */
internal class LegacyJsDomInputs(private val inputs: List<Input>) {
    internal data class Input(
        val path: List<Any>,
        val elements: List<Node>,
        val single: Boolean,
        val nodeListReadOnly: Boolean? = null,
        val emptyNodes: Boolean = false,
    )

    fun bindVariables(variables: Map<String, Any?>, session: LegacyJsDomSession): Map<String, Any?> {
        val byPath = inputs.associateBy { it.path }
        fun bind(value: Any?, path: List<Any>): Any? {
            byPath[path]?.let { input ->
                return if (input.single) session.retain(input.elements.single())
                else if (input.nodeListReadOnly != null) mapOf(
                    "nodes" to input.elements.map(session::retain),
                    "readOnly" to input.nodeListReadOnly,
                    "emptyNodes" to input.emptyNodes,
                )
                else input.elements.map(session::retain)
            }
            return when (value) {
                is Map<*, *> -> value.entries.associate { (key, child) ->
                    key.toString() to bind(child, path + key.toString())
                }
                is List<*> -> value.mapIndexed { index, child -> bind(child, path + index) }
                else -> value
            }
        }
        return LinkedHashMap(variables).apply {
            remove(LEGACY_NATIVE_DOM_INPUT_BINDING)
            if (containsKey("result")) put("result", bind(get("result"), emptyList()))
        }
    }

    fun hostPayload(session: LegacyJsDomSession): Map<String, Any?> {
        val input = inputs.single()
        require(input.path.isEmpty()) { "Invalid DOM host input" }
        return if (input.single) session.retain(input.elements.single())
        else if (input.nodeListReadOnly != null) mapOf(
            "nodes" to input.elements.map(session::retain),
            "readOnly" to input.nodeListReadOnly,
            "emptyNodes" to input.emptyNodes,
        )
        else mapOf("elements" to input.elements.map(session::retain))
    }
}
