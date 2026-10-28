package io.legado.kmp.shared.analyze.parser

internal object JsRuleScriptSupport {
    private val simpleBindingPattern =
        Regex("""[A-Za-z_$][A-Za-z0-9_$]*(\.[A-Za-z_$][A-Za-z0-9_$]*)*""")

    fun buildLegacyReturnScript(script: String): String? {
        val trimmed = script.trim()
        if (trimmed.isEmpty() || hasTopLevelReturn(trimmed)) {
            return null
        }
        if (simpleBindingPattern.matches(trimmed)) {
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

    fun replaceLegacyCodeMatches(
        script: String,
        pattern: Regex,
        replacement: (MatchResult) -> String
    ): String {
        val result = StringBuilder()
        var index = 0
        var lastIndex = 0
        var quote: Char? = null
        var escapeNext = false
        var inRegex = false
        var inRegexCharClass = false
        var inLineComment = false
        var inBlockComment = false
        var previousSignificant: Char? = null

        while (index < script.length) {
            val char = script[index]
            if (inLineComment) {
                if (char == '\n' || char == '\r') {
                    inLineComment = false
                }
                index++
                continue
            }
            if (inBlockComment) {
                if (char == '*' && index + 1 < script.length && script[index + 1] == '/') {
                    inBlockComment = false
                    index += 2
                } else {
                    index++
                }
                continue
            }
            if (escapeNext) {
                escapeNext = false
                index++
                continue
            }
            if (inRegex) {
                when {
                    char == '\\' -> escapeNext = true
                    char == '[' -> inRegexCharClass = true
                    char == ']' -> inRegexCharClass = false
                    char == '/' && !inRegexCharClass -> {
                        inRegex = false
                        previousSignificant = '/'
                    }
                }
                index++
                continue
            }
            if (quote != null) {
                if (char == '\\') {
                    escapeNext = true
                } else if (char == quote) {
                    previousSignificant = quote
                    quote = null
                }
                index++
                continue
            }
            if (char == '/' && index + 1 < script.length) {
                when (script[index + 1]) {
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
            if (char == '/' && shouldStartRegexLiteral(previousSignificant)) {
                inRegex = true
                inRegexCharClass = false
                index++
                continue
            }
            if (char == '\'' || char == '"' || char == '`') {
                quote = char
                index++
                continue
            }

            val match = pattern.find(script, index)
            if (match != null && match.range.first == index && match.value.isNotEmpty()) {
                result.append(script, lastIndex, index)
                result.append(replacement(match))
                index = match.range.last + 1
                lastIndex = index
                previousSignificant = script.getOrNull(match.range.last)
                continue
            }
            if (!char.isWhitespace()) {
                previousSignificant = char
            }
            index++
        }
        result.append(script.substring(lastIndex))
        return result.toString()
    }

    private fun Char.isScriptIdentifierPart(): Boolean {
        return isLetterOrDigit() || this == '_' || this == '$'
    }
}
