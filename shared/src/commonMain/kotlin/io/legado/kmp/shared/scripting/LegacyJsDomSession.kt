package io.legado.kmp.shared.scripting

import com.fleeksoft.ksoup.Ksoup
import com.fleeksoft.ksoup.nodes.Document
import com.fleeksoft.ksoup.nodes.Element
import com.fleeksoft.ksoup.nodes.Node

/** Owned by one QuickJS execution; nodes remain live until that execution releases the session. */
internal class LegacyJsDomSession {
    private val namespace = randomUUID()
    private var nextHandle = 0L
    private val nodesByHandle = HashMap<String, Node>()

    // Ksoup 0.2.4 Node.equals/hashCode use object identity.
    // Content mutations therefore cannot invalidate this index or merge equal-looking nodes.
    private val handlesByNode = HashMap<Node, String>()
    private val nodeSupport = LegacyJsDomNodeSupport(this)

    internal fun parse(html: String, baseUri: String): Map<String, Any?> =
        retain(Ksoup.parse(html, baseUri))

    internal fun adopt(payload: String): Map<String, Any?> {
        val decoded = legacyJsDomPayloadFromJson(payload)
        if (decoded.containsKey("handle")) {
            return retain(resolveDescriptor(decoded))
        }
        require(!decoded.containsKey("nodeType") || decoded["nodeType"] == "element") {
            "Legacy DOM nodes require a registered handle"
        }
        return retain(legacyJsDomElement(decoded))
    }

    internal fun create(nodeType: String, text: String): Map<String, Any?> =
        retain(legacyJsDomCreateNode(nodeType, text))

    internal fun retain(element: Element): Map<String, Any?> = retain(element as Node)

    internal fun retain(node: Node): Map<String, Any?> {
        val handle = handlesByNode[node] ?: run {
            check(nextHandle < Long.MAX_VALUE) { "Legacy DOM handle space exhausted" }
            val allocated = "dom:$namespace:${++nextHandle}"
            handlesByNode[node] = allocated
            nodesByHandle[allocated] = node
            allocated
        }
        return linkedMapOf<String, Any?>(
            "handle" to handle,
            "document" to (node is Document),
        ).apply {
            if (node !is Element) put("nodeType", legacyJsDomNodeType(node))
        }
    }

    internal fun resolve(handle: String): Element = resolveNode(handle) as? Element
        ?: throw IllegalArgumentException("Legacy DOM handle does not refer to an Element")

    internal fun resolveNode(handle: String): Node = nodesByHandle[handle]
        ?: throw IllegalArgumentException("Unknown legacy DOM handle for this session")

    internal fun resolveDescriptor(descriptor: Map<*, *>): Node {
        val handle = descriptor["handle"] as? String
            ?: throw IllegalArgumentException("Invalid legacy DOM descriptor handle")
        val node = resolveNode(handle)
        require(descriptor["document"] == (node is Document)) { "Invalid legacy DOM descriptor type" }
        require(descriptor["nodeType"] == legacyJsDomNodeType(node) ||
            (node is Element && !descriptor.containsKey("nodeType"))) {
            "Invalid legacy DOM descriptor node type"
        }
        return node
    }

    /** Arguments are a JSON array, not a comma-separated string or a serialized HTML snapshot. */
    internal fun invoke(handle: String, operation: String, argsJson: String): Map<String, Any?> {
        val node = resolveNode(handle)
        val args = LegacyJsDomArguments(operation, argsJson)
        nodeSupport.invoke(node, operation, args)?.let { return it }
        val element = node as? Element
            ?: throw IllegalArgumentException("Legacy DOM $operation requires an Element")
        return when (operation) {
            "select" -> {
                args.count(1)
                elementsResult(element.select(args.string(0)))
            }
            "selectFirst" -> {
                args.count(1)
                elementResult(element.selectFirst(args.string(0)))
            }
            "nextElementSibling", "previousElementSibling" -> {
                args.count(0)
                elementResult(when (operation) {
                    "nextElementSibling" -> element.nextElementSibling()
                    else -> element.previousElementSibling()
                })
            }
            "parents", "children", "siblingElements" -> {
                args.count(0)
                elementsResult(when (operation) {
                    "parents" -> element.parents()
                    "children" -> element.children()
                    else -> element.siblingElements()
                })
            }
            "child" -> {
                args.count(1)
                elementResult(element.child(args.int(0)))
            }
            "textNodes", "dataNodes" -> {
                args.count(0)
                nodesResult(if (operation == "textNodes") element.textNodes() else element.dataNodes(), readOnly = true)
            }
            "ownText", "wholeText", "data", "className", "childrenSize" -> {
                args.count(0)
                valueResult(when (operation) {
                    "ownText" -> element.ownText()
                    "wholeText" -> element.wholeText()
                    "data" -> element.data()
                    "className" -> element.className()
                    else -> element.childrenSize()
                })
            }
            "text", "html", "tagName", "id" -> {
                args.count(0, 1)
                if (args.size == 0) {
                    valueResult(when (operation) {
                        "text" -> element.text()
                        "html" -> element.html()
                        "tagName" -> element.tagName()
                        else -> element.id()
                    })
                } else {
                    val content = args.string(0)
                    elementResult(when (operation) {
                        "text" -> element.text(content)
                        "html" -> element.html(content)
                        "tagName" -> element.tagName(content)
                        else -> element.id(content)
                    })
                }
            }
            "hasClass" -> {
                args.count(1)
                val key = args.string(0)
                valueResult(element.hasClass(key))
            }
            "getElementsByTag", "getElementsByClass" -> {
                args.count(1)
                val query = args.string(0)
                elementsResult(if (operation == "getElementsByTag") element.getElementsByTag(query)
                    else element.getElementsByClass(query))
            }
            "getElementById" -> {
                args.count(1)
                elementResult(element.getElementById(args.string(0)))
            }
            "classNames" -> {
                args.count(0, 1)
                if (args.size == 0) valueResult(element.classNames().toList())
                else elementResult(element.classNames(args.strings(0).toSet()))
            }
            "addClass", "removeClass", "toggleClass" -> {
                args.count(1)
                val name = args.string(0)
                elementResult(when (operation) {
                    "addClass" -> element.addClass(name)
                    "removeClass" -> element.removeClass(name)
                    else -> element.toggleClass(name)
                })
            }
            "append", "prepend", "appendText", "prependText" -> {
                args.count(1)
                val content = args.string(0)
                elementResult(when (operation) {
                    "append" -> element.append(content)
                    "prepend" -> element.prepend(content)
                    "appendText" -> element.appendText(content)
                    else -> element.prependText(content)
                })
            }
            "appendElement", "prependElement" -> {
                args.count(1)
                val tag = args.string(0)
                elementResult(if (operation == "appendElement") element.appendElement(tag)
                    else element.prependElement(tag))
            }
            "head", "body", "location" -> {
                args.count(0)
                val document = requireDocument(element, operation)
                when (operation) {
                    "head" -> elementResult(document.head())
                    "body" -> elementResult(document.body())
                    else -> valueResult(document.location())
                }
            }
            "title" -> {
                args.count(0, 1)
                val document = requireDocument(element, operation)
                if (args.size == 0) valueResult(document.title())
                else {
                    document.title(args.string(0))
                    valueResult(null)
                }
            }
            else -> throw IllegalArgumentException("Unsupported legacy DOM operation: $operation")
        }
    }

    internal fun valueResult(value: Any?): Map<String, Any?> = linkedMapOf("kind" to "value", "value" to value)

    internal fun nodeResult(node: Node?): Map<String, Any?> =
        if (node is Element) elementResult(node)
        else linkedMapOf("kind" to "node", "value" to node?.let { retain(it) })

    internal fun nodesResult(nodes: Iterable<Node>, readOnly: Boolean, emptyNodes: Boolean = false): Map<String, Any?> = linkedMapOf(
        "kind" to "nodes", "value" to nodes.map { retain(it) }, "readOnly" to readOnly,
        "emptyNodes" to emptyNodes,
    )

    private fun elementResult(element: Element?): Map<String, Any?> =
        linkedMapOf("kind" to "element", "value" to element?.let(::retain))

    private fun elementsResult(elements: Iterable<Element>): Map<String, Any?> =
        linkedMapOf("kind" to "elements", "value" to elements.map(::retain))

    private fun requireDocument(element: Element, operation: String): Document = element as? Document
        ?: throw IllegalArgumentException("Legacy DOM $operation requires a Document")
}
