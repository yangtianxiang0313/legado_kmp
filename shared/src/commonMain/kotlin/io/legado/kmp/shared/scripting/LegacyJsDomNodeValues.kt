package io.legado.kmp.shared.scripting

import com.fleeksoft.ksoup.nodes.Node

/** A native Java-style snapshot, distinct from both Elements and an ordinary JS result array. */
internal class LegacyJsDomNodeValues(
    nodes: List<Node>,
    val readOnly: Boolean,
    val emptyNodes: Boolean = false,
) : AbstractList<Node>() {
    private val nodes = nodes.toList()

    init { require(!emptyNodes || (readOnly && nodes.isEmpty())) { "Invalid empty DOM node list" } }

    override val size: Int get() = nodes.size

    override fun get(index: Int): Node = nodes[index]

    override fun toString(): String = nodes.joinToString(prefix = "[", postfix = "]", transform = ::legacyJsDomOuterHtml)
}
