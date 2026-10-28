package io.legado.kmp.shared.util

/**
 * Split legacy payload lists on top-level "&&" or line breaks.
 *
 * Sort/explore payloads may carry URLs, JSON, or inline JS snippets where "&&"
 * and newlines are data rather than separators. Keep those intact when they are
 * inside quotes, brackets/braces/parentheses, or "{{...}}" templates.
 */
fun splitLegacyPayloadItems(payload: String): List<String> {
    if (payload.isEmpty()) return emptyList()
    val result = ArrayList<String>()
    var start = 0
    var index = 0
    var templateDepth = 0
    var bracketDepth = 0
    var parenDepth = 0
    var braceDepth = 0
    var quote: Char? = null
    var escaped = false
    while (index < payload.length) {
        val char = payload[index]
        if (escaped) {
            escaped = false
            index++
            continue
        }
        if (quote != null) {
            if (char == '\\') {
                escaped = true
            } else if (char == quote) {
                quote = null
            }
            index++
            continue
        }
        when {
            char == '\\' -> {
                escaped = true
                index++
            }
            char == '\'' || char == '"' || char == '`' -> {
                quote = char
                index++
            }
            index + 1 < payload.length && char == '{' && payload[index + 1] == '{' -> {
                templateDepth++
                index += 2
            }
            templateDepth > 0 && index + 1 < payload.length && char == '}' && payload[index + 1] == '}' -> {
                templateDepth--
                index += 2
            }
            templateDepth == 0 &&
                bracketDepth == 0 &&
                parenDepth == 0 &&
                braceDepth == 0 &&
                index + 1 < payload.length &&
                char == '&' &&
                payload[index + 1] == '&' -> {
                result += payload.substring(start, index)
                index += 2
                start = index
            }
            templateDepth == 0 &&
                bracketDepth == 0 &&
                parenDepth == 0 &&
                braceDepth == 0 &&
                (char == '\n' || char == '\r') -> {
                result += payload.substring(start, index)
                index = consumeLineBreak(payload, index)
                start = index
            }
            templateDepth == 0 && char == '[' -> {
                bracketDepth++
                index++
            }
            templateDepth == 0 && char == ']' -> {
                if (bracketDepth > 0) bracketDepth--
                index++
            }
            templateDepth == 0 && char == '(' -> {
                parenDepth++
                index++
            }
            templateDepth == 0 && char == ')' -> {
                if (parenDepth > 0) parenDepth--
                index++
            }
            templateDepth == 0 && char == '{' -> {
                braceDepth++
                index++
            }
            templateDepth == 0 && char == '}' -> {
                if (braceDepth > 0) braceDepth--
                index++
            }
            else -> index++
        }
    }
    result += payload.substring(start)
    return result
}

private fun consumeLineBreak(text: String, index: Int): Int {
    return if (text[index] == '\r' && index + 1 < text.length && text[index + 1] == '\n') {
        index + 2
    } else {
        index + 1
    }
}
