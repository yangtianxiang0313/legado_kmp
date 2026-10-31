package io.legado.kmp.shared.scripting

import com.fleeksoft.ksoup.nodes.Comment
import com.fleeksoft.ksoup.nodes.DataNode
import com.fleeksoft.ksoup.nodes.Element
import com.fleeksoft.ksoup.nodes.Node
import com.fleeksoft.ksoup.nodes.TextNode
import com.fleeksoft.ksoup.parser.Parser
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.intOrNull

internal fun legacyJsDomNodeType(node: Node): String = when (node) {
    is Element -> "element"
    is TextNode -> "text"
    is Comment -> "comment"
    is DataNode -> "data"
    else -> "node"
}

internal fun legacyJsDomCreateNode(nodeType: String, text: String): Node = when (nodeType) {
    "text" -> TextNode(text)
    "textEncoded" -> TextNode.createFromEncoded(text)
    "comment" -> Comment(text)
    "data" -> DataNode(text)
    else -> throw IllegalArgumentException("Unsupported legacy DOM node type: $nodeType")
}

/** Node APIs shared by Elements and leaf nodes; a null reply delegates to the Element-only surface. */
internal class LegacyJsDomNodeSupport(private val session: LegacyJsDomSession) {
    fun invoke(node: Node, operation: String, args: LegacyJsDomArguments): Map<String, Any?>? = with(session) {
        when (operation) {
            "childNode" -> {
                args.count(1)
                nodeResult(node.childNode(args.int(0)))
            }
            "childNodes", "childNodesCopy", "siblingNodes" -> {
                args.count(0)
                val nodes = when (operation) {
                    "childNodes" -> node.childNodes()
                    "childNodesCopy" -> node.childNodes().map(::legacyJsDomClone)
                    else -> node.siblingNodes()
                }
                // Jsoup 1.16.2 childNodes() is an unmodifiable snapshot, not a live view.
                val emptyNodes = (operation == "childNodes" && nodes.isEmpty()) ||
                    (operation == "siblingNodes" && !node.hasParent())
                nodesResult(nodes, readOnly = operation == "childNodes" || emptyNodes, emptyNodes = emptyNodes)
            }
            "childNodeSize", "siblingIndex", "hasParent", "nodeName", "normalName", "outerHtml", "baseUri" -> {
                args.count(0)
                valueResult(when (operation) {
                    "childNodeSize" -> node.childNodeSize()
                    "siblingIndex" -> node.siblingIndex()
                    "hasParent" -> node.hasParent()
                    "nodeName" -> node.nodeName()
                    "normalName" -> node.normalName()
                    "outerHtml" -> legacyJsDomOuterHtml(node)
                    else -> node.baseUri()
                })
            }
            "nextSibling", "previousSibling", "parent", "parentNode", "root", "ownerDocument" -> {
                args.count(0)
                nodeResult(when (operation) {
                    "nextSibling" -> node.nextSibling()
                    "previousSibling" -> node.previousSibling()
                    "parent" -> node.parent()
                    "parentNode" -> node.parentNode()
                    "root" -> node.root()
                    else -> node.ownerDocument()
                })
            }
            "setBaseUri" -> {
                args.count(1)
                node.setBaseUri(args.string(0))
                valueResult(null)
            }
            "hasAttr", "absUrl" -> {
                args.count(1)
                val name = args.string(0)
                valueResult(if (operation == "hasAttr") node.hasAttr(name) else node.absUrl(name))
            }
            "attr" -> {
                args.count(1, 2)
                val key = args.string(0)
                if (args.size == 1) valueResult(node.attr(key))
                else {
                    // The boolean overload belongs to Element, not Node.
                    val value = if (node is Element) args.stringOrBoolean(1) else args.string(1)
                    nodeResult(if (value is Boolean) (node as Element).attr(key, value)
                        else node.attr(key, value as String))
                }
            }
            "removeAttr" -> {
                args.count(1)
                nodeResult(node.removeAttr(args.string(0)))
            }
            "clone" -> {
                args.count(0)
                nodeResult(legacyJsDomClone(node))
            }
            "empty" -> {
                args.count(0)
                nodeResult(node.empty())
            }
            "remove" -> {
                args.count(0)
                node.remove()
                valueResult(null)
            }
            "before", "after" -> {
                args.count(1)
                val html = args.string(0)
                requireParent(node, operation)
                nodeResult(if (operation == "before") node.before(html) else node.after(html))
            }
            "wrap" -> {
                args.count(1)
                nodeResult(wrapNode(node, args.string(0)))
            }
            "unwrap" -> {
                args.count(0)
                requireParent(node, operation)
                nodeResult(node.unwrap())
            }
            "beforeNode", "afterNode", "replaceWith", "appendChild", "prependChild" -> {
                args.count(1)
                val incoming = resolveNode(args.string(0))
                if (operation == "appendChild" || operation == "prependChild") {
                    val parent = node as? Element
                        ?: throw IllegalArgumentException("Legacy DOM $operation requires an Element")
                    requireSafeInsertion(parent, incoming, operation)
                    nodeResult(if (operation == "appendChild") parent.appendChild(incoming)
                        else parent.prependChild(incoming))
                } else {
                    val parent = requireParent(node, operation)
                    requireSafeInsertion(parent, incoming, operation)
                    require(incoming !== node || operation == "replaceWith") {
                        "Legacy DOM $operation cannot insert a node relative to itself"
                    }
                    when (operation) {
                        "beforeNode" -> nodeResult(node.before(incoming))
                        "afterNode" -> nodeResult(node.after(incoming))
                        else -> {
                            node.replaceWith(incoming)
                            valueResult(null)
                        }
                    }
                }
            }
            "text" -> {
                if (node is Element) return@with null
                args.count(0, 1)
                val text = requireTextNode(node, operation)
                if (args.size == 0) valueResult(text.text()) else nodeResult(text.text(args.string(0)))
            }
            "getWholeText", "isBlank" -> {
                args.count(0)
                val text = requireTextNode(node, operation)
                valueResult(if (operation == "getWholeText") text.getWholeText() else text.isBlank())
            }
            "splitText" -> {
                args.count(1)
                nodeResult(requireTextNode(node, operation).splitText(args.int(0)))
            }
            "getData", "setData" -> {
                args.count(if (operation == "getData") 0 else 1)
                val comment = node as? Comment
                    ?: throw IllegalArgumentException("Legacy DOM $operation requires a Comment")
                if (operation == "getData") valueResult(comment.getData())
                else nodeResult(comment.setData(args.string(0)))
            }
            "getWholeData", "setWholeData" -> {
                args.count(if (operation == "getWholeData") 0 else 1)
                val data = node as? DataNode
                    ?: throw IllegalArgumentException("Legacy DOM $operation requires a DataNode")
                if (operation == "getWholeData") valueResult(data.getWholeData())
                else nodeResult(data.setWholeData(args.string(0)))
            }
            else -> null
        }
    }

    private fun requireTextNode(node: Node, operation: String): TextNode = node as? TextNode
        ?: throw IllegalArgumentException("Legacy DOM $operation requires a TextNode")

    private fun requireParent(node: Node, operation: String): Node = node.parentNode()
        ?: throw IllegalArgumentException("Legacy DOM $operation requires a parent")

    private fun requireSafeInsertion(parent: Node, incoming: Node, operation: String) {
        var ancestor: Node? = parent
        while (ancestor != null) {
            require(ancestor !== incoming) { "Legacy DOM $operation would create a node cycle" }
            ancestor = ancestor.parentNode()
        }
    }

    private fun wrapNode(node: Node, html: String): Node {
        if (node is Element || node.parentNode() is Element) return node.wrap(html)
        require(html.isNotEmpty()) { "Legacy DOM wrap HTML must not be empty" }
        // Ksoup 0.2.4 casts an orphan leaf to Element; Jsoup 1.16.2 uses a null context.
        val children = Parser.htmlParser().parseFragmentInput(html, null, node.baseUri())
        val wrapper = children.first() as? Element ?: return node
        var deepest = wrapper
        while (true) deepest = deepest.firstElementChild() ?: break
        deepest.appendChild(node)
        for (remainder in children) {
            if (remainder === wrapper) continue
            remainder.remove()
            wrapper.after(remainder)
        }
        return node
    }
}

internal class LegacyJsDomArguments(private val operation: String, json: String) {
    private val values = Json.parseToJsonElement(json) as? JsonArray
        ?: throw IllegalArgumentException("Legacy DOM $operation arguments must be a JSON array")

    val size: Int get() = values.size

    fun count(vararg allowed: Int) {
        require(size in allowed) { "Invalid argument count for legacy DOM $operation" }
    }

    fun string(index: Int): String = stringValue(values[index], index)

    fun int(index: Int): Int {
        val primitive = values[index] as? JsonPrimitive
        return primitive?.takeUnless { it.isString }?.intOrNull
            ?: throw IllegalArgumentException("Legacy DOM $operation argument $index must be an integer")
    }

    fun stringOrBoolean(index: Int): Any {
        val primitive = values[index] as? JsonPrimitive
            ?: throw IllegalArgumentException("Legacy DOM $operation argument $index must be a string or boolean")
        if (primitive.isString) return primitive.content
        return primitive.booleanOrNull
            ?: throw IllegalArgumentException("Legacy DOM $operation argument $index must be a string or boolean")
    }

    fun strings(index: Int): List<String> {
        val array = values[index] as? JsonArray
            ?: throw IllegalArgumentException("Legacy DOM $operation argument $index must be a string array")
        return array.map { stringValue(it, index) }
    }

    private fun stringValue(value: JsonElement, index: Int): String {
        val primitive = value as? JsonPrimitive
            ?: throw IllegalArgumentException("Legacy DOM $operation argument $index must be a string")
        require(primitive.isString) { "Legacy DOM $operation argument $index must be a string" }
        return primitive.content
    }
}
