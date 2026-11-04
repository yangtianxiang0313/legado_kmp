package io.legado.kmp.shared.analyze.parser

internal data class XPathAttributeSelection(val ownerXPath: String, val attributeName: String)

internal fun parseXPathAttributeSelection(expression: String): XPathAttributeSelection? {
    val path = expression.trim()
    var index = 0
    var ownerEnd = -1
    var descendant = false
    if (path.startsWith('/')) {
        ownerEnd = 0
        index = 1
        if (path.getOrNull(index) == '/') {
            index++
            descendant = true
        }
    }
    while (index < path.length) {
        while (index < path.length && path[index].isWhitespace()) index++
        if (index == path.length) return null
        val attributeStart = when {
            path[index] == '@' -> index + 1
            path.startsWith("attribute::", index) -> index + "attribute::".length
            else -> null
        }
        if (attributeStart != null) {
            if (descendant) return null
            index = xpathSelectionQNameEnd(path, attributeStart, false) ?: return null
            val attributeName = path.substring(attributeStart, index)
            while (index < path.length) {
                if (path[index] == '/') index++
                if (path.getOrNull(index) != '@') return null
                index = xpathSelectionQNameEnd(path, index + 1, false) ?: return null
            }
            val ownerXPath = when (ownerEnd) {
                -1 -> "."
                0 -> "/"
                else -> path.substring(0, ownerEnd).trimEnd()
            }
            return XPathAttributeSelection(ownerXPath, attributeName)
        }
        val abbreviated = path[index] == '.'
        if (abbreviated) {
            index++
            if (path.getOrNull(index) == '.') index++
        } else {
            val axisEnd = xpathSelectionNCNameEnd(path, index)
            if (axisEnd != null && path.startsWith("::", axisEnd)) {
                if (path.substring(index, axisEnd) !in xpathSelectionOwnerAxes) return null
                index = axisEnd + 2
            }
            index = xpathSelectionQNameEnd(path, index, true) ?: return null
        }
        while (index < path.length && path[index].isWhitespace()) index++
        while (path.getOrNull(index) == '[') {
            if (abbreviated) return null
            index = xpathSelectionPredicateEnd(path, index) ?: return null
            while (index < path.length && path[index].isWhitespace()) index++
        }
        if (path.getOrNull(index) != '/') return null
        ownerEnd = index++
        descendant = path.getOrNull(index) == '/'
        if (descendant) index++
    }
    return null
}

private val xpathSelectionOwnerAxes = setOf(
    "ancestor", "ancestor-or-self", "child", "descendant", "descendant-or-self",
    "following", "following-sibling", "namespace", "parent", "preceding",
    "preceding-sibling", "self"
)

// Predicate contents stay opaque, but delimiters must nest correctly outside XPath literals.
private fun xpathSelectionPredicateEnd(path: String, start: Int): Int? {
    val brackets = mutableListOf<Char>()
    var quote: Char? = null
    for (index in start until path.length) {
        val character = path[index]
        if (quote != null) {
            if (character == quote) quote = null
            continue
        }
        when (character) {
            '\'', '"' -> quote = character
            '[', '(' -> brackets.add(character)
            ']', ')' -> {
                val opening = if (character == ']') '[' else '('
                if (brackets.lastOrNull() != opening) return null
                brackets.removeAt(brackets.lastIndex)
                if (brackets.isEmpty()) return index + 1
            }
        }
    }
    return null
}

private fun xpathSelectionQNameEnd(path: String, start: Int, wildcard: Boolean): Int? {
    if (wildcard && path.getOrNull(start) == '*') return start + 1
    val end = xpathSelectionNCNameEnd(path, start) ?: return null
    if (path.getOrNull(end) != ':') return end
    if (wildcard && path.getOrNull(end + 1) == '*') return end + 2
    return xpathSelectionNCNameEnd(path, end + 1)
}

private fun xpathSelectionNCNameEnd(path: String, start: Int): Int? {
    var index = start
    while (index < path.length) {
        val character = path[index]
        val next = path.getOrNull(index + 1)
        val codePoint = if (character.isHighSurrogate() && next?.isLowSurrogate() == true) {
            0x10000 + ((character.code - 0xD800) shl 10) + (next.code - 0xDC00)
        } else character.code
        // XML NCName excludes ':'; supplementary name characters end at U+EFFFF.
        val nameStart = codePoint == 0x5F || codePoint in 0x41..0x5A ||
            codePoint in 0x61..0x7A || codePoint in 0xC0..0xD6 ||
            codePoint in 0xD8..0xF6 || codePoint in 0xF8..0x2FF ||
            codePoint in 0x370..0x37D || codePoint in 0x37F..0x1FFF ||
            codePoint in 0x200C..0x200D || codePoint in 0x2070..0x218F ||
            codePoint in 0x2C00..0x2FEF || codePoint in 0x3001..0xD7FF ||
            codePoint in 0xF900..0xFDCF || codePoint in 0xFDF0..0xFFFD ||
            codePoint in 0x10000..0xEFFFF
        val nameContinuation = codePoint in 0x30..0x39 || codePoint == 0x2D ||
            codePoint == 0x2E || codePoint == 0xB7 || codePoint in 0x300..0x36F ||
            codePoint in 0x203F..0x2040
        if (!nameStart && (index == start || !nameContinuation)) break
        index += if (codePoint > 0xFFFF) 2 else 1
    }
    return index.takeIf { it > start }
}
