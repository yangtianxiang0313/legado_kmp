package io.legado.kmp.shared.scripting

import com.fleeksoft.ksoup.nodes.CDataNode
import com.fleeksoft.ksoup.nodes.Comment
import com.fleeksoft.ksoup.nodes.DataNode
import com.fleeksoft.ksoup.nodes.Document
import com.fleeksoft.ksoup.nodes.Element
import com.fleeksoft.ksoup.nodes.Node
import com.fleeksoft.ksoup.nodes.TextNode

/** Ksoup 0.2.4 leaf clone factories cast Attributes to String, or share their mutable storage. */
internal fun legacyJsDomClone(node: Node): Node {
    val copy = shallowClone(node, keepOwner = true)
    val pending = ArrayDeque<Pair<Node, Node>>()
    pending.addLast(node to copy)
    while (pending.isNotEmpty()) {
        val (original, cloned) = pending.removeFirst()
        if (cloned is Element) original.childNodes().forEach { child ->
            val childCopy = shallowClone(child, keepOwner = false)
            cloned.appendChild(childCopy)
            pending.addLast(child to childCopy)
        }
    }
    return copy
}

private fun shallowClone(node: Node, keepOwner: Boolean): Node {
    val leaf = when (node) {
        is CDataNode -> CDataNode(node.getWholeText())
        is TextNode -> TextNode(node.getWholeText())
        is Comment -> Comment(node.getData())
        is DataNode -> DataNode(node.getWholeData())
        else -> null
    }
    val copy = leaf ?: node.shallowClone()
    if (leaf != null) {
        if (node.attributesSize() > 0) leaf.attributes().addAll(node.attributes())
    }
    // Element.shallowClone bypasses Node.doClone's document attachment in Ksoup 0.2.4.
    if (keepOwner && copy !is Document && copy.parentNode() == null) {
        node.ownerDocument()?.shallowClone()?.appendChild(copy)
    }
    return copy
}
