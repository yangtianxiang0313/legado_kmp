package io.legado.kmp.shared.scripting

import com.fleeksoft.ksoup.Ksoup
import com.fleeksoft.ksoup.nodes.Document
import com.fleeksoft.ksoup.nodes.Element
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.intOrNull

/** Owned by one QuickJS execution; nodes remain live until that execution releases the session. */
internal class LegacyJsDomSession {
    private val namespace = randomUUID()
    private var nextHandle = 0L
    private val elementsByHandle = HashMap<String, Element>()

    // Ksoup 0.2.4 Node.equals/hashCode use object identity; Element does not override them.
    // Content mutations therefore cannot invalidate this index or merge equal-looking nodes.
    private val handlesByElement = HashMap<Element, String>()

    internal fun parse(html: String, baseUri: String): Map<String, Any?> =
        retain(Ksoup.parse(html, baseUri))

    internal fun adopt(payload: String): Map<String, Any?> {
        val decoded = legacyJsDomPayloadFromJson(payload)
        if (decoded.containsKey("handle")) {
            val handle = decoded["handle"] as? String
                ?: throw IllegalArgumentException("Invalid legacy DOM descriptor handle")
            val element = resolve(handle)
            require(decoded["document"] == (element is Document)) { "Invalid legacy DOM descriptor type" }
            return retain(element)
        }
        return retain(legacyJsDomElement(decoded))
    }

    internal fun retain(element: Element): Map<String, Any?> {
        val handle = handlesByElement[element] ?: run {
            check(nextHandle < Long.MAX_VALUE) { "Legacy DOM handle space exhausted" }
            val allocated = "dom:$namespace:${++nextHandle}"
            handlesByElement[element] = allocated
            elementsByHandle[allocated] = element
            allocated
        }
        return linkedMapOf("handle" to handle, "document" to (element is Document))
    }

    internal fun resolve(handle: String): Element = elementsByHandle[handle]
        ?: throw IllegalArgumentException("Unknown legacy DOM handle for this session")

    /** Arguments are a JSON array, not a comma-separated string or a serialized HTML snapshot. */
    internal fun invoke(handle: String, operation: String, argsJson: String): Map<String, Any?> {
        val element = resolve(handle)
        val args = Arguments(operation, argsJson)
        return when (operation) {
            "select" -> {
                args.count(1)
                elementsResult(element.select(args.string(0)))
            }
            "selectFirst" -> {
                args.count(1)
                elementResult(element.selectFirst(args.string(0)))
            }
            "parent", "nextElementSibling", "previousElementSibling" -> {
                args.count(0)
                elementResult(when (operation) {
                    "parent" -> element.parent()
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
            "ownText", "wholeText", "outerHtml", "data", "baseUri", "className",
            "nodeName", "normalName", "childrenSize" -> {
                args.count(0)
                valueResult(when (operation) {
                    "ownText" -> element.ownText()
                    "wholeText" -> element.wholeText()
                    "outerHtml" -> element.outerHtml()
                    "data" -> element.data()
                    "baseUri" -> element.baseUri()
                    "className" -> element.className()
                    "nodeName" -> element.nodeName()
                    "normalName" -> element.normalName()
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
            "hasAttr", "hasClass", "absUrl" -> {
                args.count(1)
                val key = args.string(0)
                valueResult(when (operation) {
                    "hasAttr" -> element.hasAttr(key)
                    "hasClass" -> element.hasClass(key)
                    else -> element.absUrl(key)
                })
            }
            "attr" -> {
                args.count(1, 2)
                val key = args.string(0)
                if (args.size == 1) {
                    valueResult(element.attr(key))
                } else {
                    val attribute = args.stringOrBoolean(1)
                    elementResult(if (attribute is Boolean) element.attr(key, attribute)
                        else element.attr(key, attribute as String))
                }
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
            "addClass", "removeClass", "toggleClass", "removeAttr" -> {
                args.count(1)
                val name = args.string(0)
                elementResult(when (operation) {
                    "addClass" -> element.addClass(name)
                    "removeClass" -> element.removeClass(name)
                    "toggleClass" -> element.toggleClass(name)
                    else -> element.removeAttr(name)
                })
            }
            "append", "prepend", "before", "after", "wrap" -> {
                args.count(1)
                val html = args.string(0)
                // Ksoup silently ignores sibling HTML on orphans; Jsoup 1.16.2 rejects it.
                if (operation == "before" || operation == "after") requireParent(element, operation)
                elementResult(when (operation) {
                    "append" -> element.append(html)
                    "prepend" -> element.prepend(html)
                    "before" -> element.before(html)
                    "after" -> element.after(html)
                    else -> element.wrap(html)
                })
            }
            "empty", "clone" -> {
                args.count(0)
                elementResult(if (operation == "empty") element.empty() else element.clone())
            }
            "remove" -> {
                args.count(0)
                element.remove()
                valueResult(null)
            }
            "unwrap" -> {
                args.count(0)
                requireParent(element, operation)
                // Node.unwrap may return a TextNode/Comment. Reject before mutation because this
                // bridge only exports Elements; returning self or null would misrepresent Jsoup.
                val first = element.firstChild()
                if (first != null && first !is Element) {
                    throw UnsupportedOperationException("Legacy DOM unwrap cannot return a non-Element node")
                }
                elementResult(element.unwrap() as? Element)
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

    private fun valueResult(value: Any?): Map<String, Any?> = linkedMapOf("kind" to "value", "value" to value)

    private fun elementResult(element: Element?): Map<String, Any?> =
        linkedMapOf("kind" to "element", "value" to element?.let(::retain))

    private fun elementsResult(elements: Iterable<Element>): Map<String, Any?> =
        linkedMapOf("kind" to "elements", "value" to elements.map(::retain))

    private fun requireDocument(element: Element, operation: String): Document = element as? Document
        ?: throw IllegalArgumentException("Legacy DOM $operation requires a Document")

    private fun requireParent(element: Element, operation: String) {
        require(element.parent() != null) { "Legacy DOM $operation requires a parent" }
    }

    private class Arguments(private val operation: String, json: String) {
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
            require(primitive.isString) {
                "Legacy DOM $operation argument $index must be a string"
            }
            return primitive.content
        }
    }
}
