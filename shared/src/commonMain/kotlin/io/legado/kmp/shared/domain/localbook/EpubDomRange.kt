package io.legado.kmp.shared.domain.localbook

import com.fleeksoft.ksoup.nodes.Element
import com.fleeksoft.ksoup.nodes.Node

internal object EpubDomRange {
    /**
     * All elements, including body at order 0, participate in preorder numbering.
     * Fragments are already decoded; id and legacy a[name] are exact, case-sensitive aliases.
     * Ambiguous aliases are omitted, without invalidating unrelated unique navigation targets.
     */
    fun positions(body: Element, checkActive: () -> Unit = {}): Map<String, Int> {
        checkActive()
        nodeSpans(body, checkActive)
        val result = linkedMapOf<String, Int>()
        val ambiguous = mutableSetOf<String>()
        body.getAllElements().forEachIndexed { order, element ->
            checkActive()
            anchorNames(element).forEach { fragment ->
                if (fragment !in ambiguous) {
                    val previous = result[fragment]
                    if (previous != null && previous != order) {
                        ambiguous.add(fragment)
                        result.remove(fragment)
                    } else {
                        result[fragment] = order
                    }
                }
            }
        }
        return result
    }

    /**
     * Returns a detached copy of the DOM range from before start to before end.
     * Null means the corresponding document edge. Ancestors of retained nodes keep their attributes.
     * End at/before start (including an ancestor) is an empty range, not the rest of the document.
     * Whole-SVG replacement must precede slicing; anchors inside SVG graphics are unsupported.
     */
    fun slice(body: Element, start: String?, end: String?, checkActive: () -> Unit = {}): Element {
        checkActive()
        nodeSpans(body, checkActive)
        val copy = body.clone()
        checkActive()
        if (start == null && end == null) return copy

        val nodes = nodeSpans(copy, checkActive)
        val startOrder = boundary(nodes, start, 0, checkActive)
        val endOrder = boundary(nodes, end, nodes.size, checkActive)
        if (endOrder <= startOrder) return copy.empty()

        // Node spans include text and comments, so text between two anchors cannot cross the cut.
        var order = 1
        while (order < nodes.size) {
            checkActive()
            val span = nodes[order]
            when {
                span.end <= startOrder || order >= endOrder -> {
                    span.node.remove()
                    order = span.end
                }
                order >= startOrder && span.end <= endOrder -> order = span.end
                else -> order++
            }
        }
        checkActive()
        return copy
    }

    private fun anchorNames(element: Element): List<String> {
        val id = element.attr("id")
        val name = if (element.epubName() == "a") element.attr("name") else ""
        return listOf(id, name).filter { it.isNotEmpty() }.distinct()
    }

    private fun boundary(
        nodes: List<NodeSpan>,
        fragment: String?,
        default: Int,
        checkActive: () -> Unit
    ): Int {
        if (fragment == null) return default
        require(fragment.isNotEmpty()) { "EPUB 章节锚点为空" }
        var match: Int? = null
        nodes.forEachIndexed { order, span ->
            checkActive()
            val element = span.node as? Element ?: return@forEachIndexed
            if (fragment in anchorNames(element)) {
                require(match == null) { "EPUB 章节锚点不唯一：#$fragment" }
                match = order
            }
        }
        return requireNotNull(match) { "EPUB 章节锚点不存在（不支持 SVG 内部锚点）：#$fragment" }
    }

    private fun nodeSpans(body: Element, checkActive: () -> Unit): List<NodeSpan> {
        val result = mutableListOf<NodeSpan>()
        val pending = ArrayDeque<OpenNode>()

        fun enter(node: Node) {
            require(result.size < 100000 && pending.size < 128) { "EPUB 正文节点或嵌套超过限制" }
            val span = NodeSpan(node)
            result += span
            pending.addLast(OpenNode(span, node.childNodes()))
        }

        enter(body)
        while (pending.isNotEmpty()) {
            checkActive()
            val current = pending.last()
            if (current.nextChild < current.children.size) {
                enter(current.children[current.nextChild++])
            } else {
                current.span.end = result.size
                pending.removeLast()
            }
        }
        return result
    }

    private class NodeSpan(val node: Node, var end: Int = 0)

    private class OpenNode(val span: NodeSpan, val children: List<Node>, var nextChild: Int = 0)
}
