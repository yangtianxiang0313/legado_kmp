package io.legado.kmp.shared.analyze

internal data class LegacyJsRuleMatch(
    val startIndex: Int,
    val endIndex: Int,
    val script: String
)

internal fun findLegacyInlineExpressionEnd(rule: kotlin.String, start: Int): Int {
    var quote: Char? = null
    var escaped = false
    var depth = 0
    var index = start + 2
    while (index < rule.length - 1) {
        val char = rule[index]
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
        when (char) {
            '\'', '"', '`' -> quote = char
            '(', '[', '{' -> depth++
            ')', ']', '}' -> {
                if (char == '}' && depth == 0 && rule[index + 1] == '}') {
                    return index
                }
                if (depth > 0) depth--
            }
        }
        index++
    }
    return -1
}

/**
 * Split rule chain by delimiter
 */
internal fun splitRuleChain(rule: kotlin.String, delimiter: kotlin.String): List<kotlin.String> {
    if (!rule.contains(delimiter)) return listOf(rule.trim()).filter { it.isNotEmpty() }
    val parts = mutableListOf<kotlin.String>()
    var start = 0
    var index = 0
    var quote: Char? = null
    var escaped = false
    var bracketDepth = 0
    var parenDepth = 0
    var braceDepth = 0
    while (index < rule.length) {
        val char = rule[index]
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
            rule.startsWith("{{", index) -> {
                val end = findLegacyInlineExpressionEnd(rule, index)
                index = if (end < 0) rule.length else end + 2
            }
            rule.regionMatches(index, "<js>", 0, 4, ignoreCase = true) -> {
                val end = findLegacyJsTagEnd(rule, index + 4)
                index = if (end < 0) rule.length else end + 5
            }
            rule.regionMatches(index, "@js:", 0, 4, ignoreCase = true) -> {
                index = rule.length
            }
            char == '\\' -> {
                escaped = true
                index++
            }
            char == '\'' || char == '"' || char == '`' -> {
                quote = char
                index++
            }
            bracketDepth == 0 &&
                    parenDepth == 0 &&
                    braceDepth == 0 &&
                    rule.startsWith(delimiter, index) -> {
                parts += rule.substring(start, index).trim()
                index += delimiter.length
                start = index
            }
            char == '[' -> {
                bracketDepth++
                index++
            }
            char == ']' -> {
                if (bracketDepth > 0) bracketDepth--
                index++
            }
            char == '(' -> {
                parenDepth++
                index++
            }
            char == ')' -> {
                if (parenDepth > 0) parenDepth--
                index++
            }
            char == '{' -> {
                braceDepth++
                index++
            }
            char == '}' -> {
                if (braceDepth > 0) braceDepth--
                index++
            }
            else -> index++
        }
    }
    parts += rule.substring(start).trim()
    return parts.filter { it.isNotEmpty() }
}

internal fun findLegacyJsRuleMatches(rule: kotlin.String, startIndex: Int): List<LegacyJsRuleMatch> {
    val result = mutableListOf<LegacyJsRuleMatch>()
    var cursor = startIndex
    while (cursor < rule.length) {
        val jsStart = rule.indexOf("@js:", cursor, ignoreCase = true)
        val tagStart = rule.indexOf("<js>", cursor, ignoreCase = true)
        val nextStart = when {
            jsStart < 0 -> tagStart
            tagStart < 0 -> jsStart
            else -> minOf(jsStart, tagStart)
        }
        if (nextStart < 0) break
        val inlineEnd = inlineTemplateEndAfter(rule, nextStart)
        if (inlineEnd != null) {
            cursor = inlineEnd
            continue
        }
        if (tagStart == nextStart) {
            val scriptStart = nextStart + 4
            val scriptEnd = findLegacyJsTagEnd(rule, scriptStart)
            if (scriptEnd < 0) {
                cursor = scriptStart
                continue
            }
            result += LegacyJsRuleMatch(
                startIndex = nextStart,
                endIndex = scriptEnd + 5,
                script = rule.substring(scriptStart, scriptEnd)
            )
            cursor = scriptEnd + 5
        } else {
            result += LegacyJsRuleMatch(
                startIndex = nextStart,
                endIndex = rule.length,
                script = rule.substring(nextStart + 4)
            )
            break
        }
    }
    return result
}

private fun inlineTemplateEndAfter(rule: kotlin.String, matchStart: Int): Int? {
    var cursor = 0
    while (cursor < rule.length) {
        val start = rule.indexOf("{{", cursor)
        if (start < 0 || start > matchStart) return null
        val end = findLegacyInlineExpressionEnd(rule, start)
        if (end < 0) return if (matchStart > start) rule.length else null
        if (matchStart in (start + 2) until end) {
            return end + 2
        }
        cursor = end + 2
    }
    return null
}

private fun findLegacyJsTagEnd(rule: kotlin.String, startIndex: Int): Int {
    var index = startIndex
    var quote: Char? = null
    var escaped = false
    var inLineComment = false
    var inBlockComment = false
    while (index < rule.length) {
        val char = rule[index]
        if (inLineComment) {
            if (char == '\n' || char == '\r') inLineComment = false
            index++
            continue
        }
        if (inBlockComment) {
            if (char == '*' && index + 1 < rule.length && rule[index + 1] == '/') {
                inBlockComment = false
                index += 2
            } else {
                index++
            }
            continue
        }
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
        if (rule.regionMatches(index, "</js>", 0, 5, ignoreCase = true)) {
            return index
        }
        if (char == '/' && index + 1 < rule.length) {
            when (rule[index + 1]) {
                '/' -> {
                    inLineComment = true
                    index += 2
                    continue
                }
                '*' -> {
                    inBlockComment = true
                    index += 2
                    continue
                }
            }
        }
        if (char == '\'' || char == '"' || char == '`') {
            quote = char
        }
        index++
    }
    return -1
}

private fun isInlineTemplateJsMatch(rule: kotlin.String, matchStart: Int): kotlin.Boolean {
    var cursor = 0
    while (cursor < rule.length) {
        val start = rule.indexOf("{{", cursor)
        if (start < 0 || start > matchStart) return false
        val end = findLegacyInlineExpressionEnd(rule, start)
        if (end < 0) {
            return matchStart > start
        }
        if (matchStart in (start + 2) until end) {
            return true
        }
        cursor = end + 2
    }
    return rule.regionMatches(matchStart - 2, "{{", 0, 2)
}
