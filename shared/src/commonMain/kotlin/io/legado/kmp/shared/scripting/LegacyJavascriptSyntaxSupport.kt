package io.legado.kmp.shared.scripting

private val legacyDescendantOperatorPattern =
    Regex("""\b([A-Za-z_$][A-Za-z0-9_$]*)\.\.([A-Za-z_$][A-Za-z0-9_$]*)""")

internal fun buildLegacyReturnScript(script: String): String? {
    val trimmed = script.trim()
    if (trimmed.isEmpty() || hasTopLevelReturn(trimmed)) {
        return null
    }
    if (!trimmed.contains(';') && !trimmed.contains('\n')) {
        return buildString {
            append("(() => {\n")
            append("return (")
            append(trimmed)
            append(");\n})()")
        }
    }
    val withoutTrailing = trimmed.trimEnd(';', '\n', '\r', ' ', '\t')
    val splitIndex = findLegacyReturnBoundary(withoutTrailing)
    if (splitIndex < 0 || splitIndex >= withoutTrailing.lastIndex - 1) {
        return null
    }
    val statements = withoutTrailing.substring(0, splitIndex).trim()
    val tailExpression = withoutTrailing.substring(splitIndex + 1).trim().removeSuffix(";").trim()
    if (!isValidLegacyTailExpression(tailExpression)) {
        return null
    }
    return buildString {
        append("(() => {\n")
        if (statements.isNotEmpty()) {
            append(statements)
            if (!statements.endsWith(";")) {
                append(';')
            }
            append('\n')
        }
        append("return (")
        append(tailExpression)
        append(");\n})()")
    }
}

private fun findLegacyReturnBoundary(script: String): Int {
    val candidates = linkedSetOf<Int>()
    candidates += findTopLevelIndexes(script, ';')
    candidates += findTopLevelIndexes(script, '\n')
    for (index in candidates.sortedDescending()) {
        val before = script.substring(0, index).trimEnd()
        val after = script.substring(index + 1).trimStart()
        if (before.isEmpty() || after.isEmpty()) continue
        if (script[index] == '\n' && looksLikeExpressionContinuation(before, after)) continue
        val tailExpression = after.removeSuffix(";").trim()
        if (isValidLegacyTailExpression(tailExpression)) {
            return index
        }
    }
    return -1
}

private fun hasTopLevelReturn(script: String): Boolean {
    return findTopLevelKeyword(script, "return")
}

private fun isValidLegacyTailExpression(tailExpression: String): Boolean {
    if (tailExpression.isEmpty() || tailExpression.startsWith("return ")) {
        return false
    }
    return !tailExpression.startsWithLegacyStatementKeyword()
}

private fun looksLikeExpressionContinuation(before: String, after: String): Boolean {
    val beforeLine = before.substringAfterLast('\n').trimEnd()
    val afterLine = after.substringBefore('\n').trimStart()
    if (beforeLine.isEmpty() || afterLine.isEmpty()) return false
    val continuationSuffixes = listOf(
        "+", "-", "*", "/", "%", "&&", "||", "??", "|", "&", "^",
        "=", "==", "===", "!=", "!==", ">", ">=", "<", "<=", "?",
        ":", ",", ".", "(", "[", "{"
    )
    val continuationPrefixes = listOf(
        "+", "-", "*", "/", "%", "&&", "||", "??", "|", "&", "^",
        ".", ")", "]", "}", ":", "?", ","
    )
    if (continuationSuffixes.any { beforeLine.endsWith(it) }) return true
    if (continuationPrefixes.any { afterLine.startsWith(it) }) return true
    if (beforeLine.endsWith("=>")) return true
    return false
}

private fun String.startsWithLegacyStatementKeyword(): Boolean {
    val statementPrefixes = listOf(
        "if",
        "else",
        "for",
        "while",
        "switch",
        "try",
        "catch",
        "finally",
        "do",
        "var",
        "let",
        "const",
        "function",
        "class"
    )
    return statementPrefixes.any { keyword ->
        startsWith(keyword) && (length == keyword.length || !this[keyword.length].isScriptIdentifierPart())
    }
}

private fun findTopLevelKeyword(script: String, keyword: String): Boolean {
    val indexes = findTopLevelIndexes(script, keyword.first())
    return indexes.any { index ->
        script.regionMatches(index, keyword, 0, keyword.length) &&
            (index == 0 || !script[index - 1].isScriptIdentifierPart()) &&
            (index + keyword.length >= script.length || !script[index + keyword.length].isScriptIdentifierPart())
    }
}

private fun findTopLevelIndexes(script: String, target: Char): List<Int> {
    val indexes = mutableListOf<Int>()
    var parenDepth = 0
    var bracketDepth = 0
    var braceDepth = 0
    var inSingleQuote = false
    var inDoubleQuote = false
    var inTemplate = false
    var inRegex = false
    var inRegexCharClass = false
    var inLineComment = false
    var inBlockComment = false
    var escapeNext = false
    var previousSignificant: Char? = null

    script.forEachIndexed { index, char ->
        if (inLineComment) {
            if (char == '\n') {
                inLineComment = false
                if (target == '\n' && parenDepth == 0 && bracketDepth == 0 && braceDepth == 0) {
                    indexes += index
                }
            }
            return@forEachIndexed
        }
        if (inBlockComment) {
            if (char == '*' && index + 1 < script.length && script[index + 1] == '/') {
                inBlockComment = false
            }
            return@forEachIndexed
        }
        if (escapeNext) {
            escapeNext = false
            return@forEachIndexed
        }
        when {
            inRegex -> {
                when {
                    char == '\\' -> escapeNext = true
                    char == '[' -> inRegexCharClass = true
                    char == ']' -> inRegexCharClass = false
                    char == '/' && !inRegexCharClass -> {
                        inRegex = false
                        previousSignificant = '/'
                    }
                }
            }
            inSingleQuote -> {
                if (char == '\\') {
                    escapeNext = true
                } else if (char == '\'') {
                    inSingleQuote = false
                    previousSignificant = '\''
                }
            }
            inDoubleQuote -> {
                if (char == '\\') {
                    escapeNext = true
                } else if (char == '"') {
                    inDoubleQuote = false
                    previousSignificant = '"'
                }
            }
            inTemplate -> {
                if (char == '\\') {
                    escapeNext = true
                } else if (char == '`') {
                    inTemplate = false
                    previousSignificant = '`'
                }
            }
            char == '/' && index + 1 < script.length && script[index + 1] == '/' -> {
                inLineComment = true
            }
            char == '/' && index + 1 < script.length && script[index + 1] == '*' -> {
                inBlockComment = true
            }
            char == '/' && shouldStartRegexLiteral(previousSignificant) -> {
                inRegex = true
                inRegexCharClass = false
            }
            char == '\'' -> inSingleQuote = true
            char == '"' -> inDoubleQuote = true
            char == '`' -> inTemplate = true
            else -> {
                when (char) {
                    '(' -> parenDepth += 1
                    ')' -> if (parenDepth > 0) parenDepth -= 1
                    '[' -> bracketDepth += 1
                    ']' -> if (bracketDepth > 0) bracketDepth -= 1
                    '{' -> braceDepth += 1
                    '}' -> if (braceDepth > 0) braceDepth -= 1
                }
                if (char == target && parenDepth == 0 && bracketDepth == 0 && braceDepth == 0) {
                    indexes += index
                }
                if (!char.isWhitespace()) {
                    previousSignificant = char
                }
            }
        }
    }
    return indexes
}

private fun shouldStartRegexLiteral(previousSignificant: Char?): Boolean {
    return previousSignificant == null ||
        previousSignificant in charArrayOf(
            '(', '[', '{', ',', ':', ';', '=',
            '!', '?', '+', '-', '*', '%',
            '&', '|', '^', '~', '<', '>'
        )
}

/**
 * Legacy Rhino accepts `let (x = expr) condition` expressions that QuickJS rejects.
 * Rewrite that expression form into an IIFE so source jsLib/url rules stay executable.
 */
internal fun normalizeLegacyJavascriptSyntax(script: String): String {
    val letNormalized = buildString {
        var cursor = 0
        while (cursor < script.length) {
            val letIndex = findLegacyLetExpression(script, cursor) ?: break
            append(script, cursor, letIndex)
            val openParen = script.indexOf('(', letIndex)
            if (openParen < 0) {
                append(script.substring(letIndex))
                return@buildString
            }
            val bindingEnd = findMatchingParen(script, openParen)
            if (bindingEnd < 0) {
                append(script.substring(letIndex))
                return@buildString
            }
            var bodyStart = bindingEnd + 1
            while (bodyStart < script.length && script[bodyStart].isWhitespace()) {
                bodyStart += 1
            }
            if (bodyStart >= script.length || script[bodyStart] == '{') {
                append(script, letIndex, bodyStart)
                cursor = bodyStart
                continue
            }
            val bodyEnd = findLegacyLetBodyEnd(script, bodyStart)
            val bindings = script.substring(openParen + 1, bindingEnd).trim()
            val body = script.substring(bodyStart, bodyEnd).trim()
            if (bindings.isBlank() || body.isBlank()) {
                append(script, letIndex, bodyEnd)
                cursor = bodyEnd
                continue
            }
            append("((function(){ var ")
            append(bindings)
            append("; return (")
            append(body)
            append("); })())")
            cursor = bodyEnd
        }
        if (cursor < script.length) {
            append(script.substring(cursor))
        }
    }
    return legacyDescendantOperatorPattern.replace(letNormalized) { match ->
        "${match.groupValues[1]}.${match.groupValues[2]}"
    }
}

private fun findLegacyLetExpression(script: String, startIndex: Int): Int? {
    var index = startIndex
    while (index < script.length) {
        val candidate = script.indexOf("let", index)
        if (candidate < 0) return null
        val before = script.getOrNull(candidate - 1)
        if (before != null && (before.isLetterOrDigit() || before == '_' || before == '$')) {
            index = candidate + 3
            continue
        }
        var cursor = candidate + 3
        while (cursor < script.length && script[cursor].isWhitespace()) {
            cursor += 1
        }
        if (cursor < script.length && script[cursor] == '(') {
            return candidate
        }
        index = candidate + 3
    }
    return null
}

private fun findMatchingParen(script: String, openParen: Int): Int {
    var depth = 0
    var index = openParen
    var quote: Char? = null
    var escape = false
    while (index < script.length) {
        val ch = script[index]
        if (quote != null) {
            if (escape) {
                escape = false
            } else if (ch == '\\') {
                escape = true
            } else if (ch == quote) {
                quote = null
            }
        } else {
            when (ch) {
                '"', '\'' -> quote = ch
                '(' -> depth += 1
                ')' -> {
                    depth -= 1
                    if (depth == 0) return index
                }
            }
        }
        index += 1
    }
    return -1
}

private fun findLegacyLetBodyEnd(script: String, bodyStart: Int): Int {
    var index = bodyStart
    var parenDepth = 0
    var bracketDepth = 0
    var quote: Char? = null
    var escape = false
    while (index < script.length) {
        val ch = script[index]
        if (quote != null) {
            if (escape) {
                escape = false
            } else if (ch == '\\') {
                escape = true
            } else if (ch == quote) {
                quote = null
            }
            index += 1
            continue
        }
        when (ch) {
            '"', '\'' -> quote = ch
            '(' -> parenDepth += 1
            ')' -> if (parenDepth == 0 && bracketDepth == 0) return index else parenDepth -= 1
            '[' -> bracketDepth += 1
            ']' -> if (bracketDepth > 0) bracketDepth -= 1
            ';', '\n', '\r' -> if (parenDepth == 0 && bracketDepth == 0) return index
            '{', '}' -> if (parenDepth == 0 && bracketDepth == 0) return index
        }
        index += 1
    }
    return script.length
}

private fun Char.isScriptIdentifierPart(): Boolean {
    return isLetterOrDigit() || this == '_' || this == '$'
}
