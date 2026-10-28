package io.legado.kmp.shared.analyze.parser

import at.asitplus.jsonpath.JsonPath
import at.asitplus.jsonpath.core.JsonPathFilterExpressionType
import at.asitplus.jsonpath.core.JsonPathFilterExpressionType.LogicalType
import at.asitplus.jsonpath.core.JsonPathFilterExpressionType.NodesType

/** Lexical substitutions only: no query AST, boolean evaluator, or data traversal. */
internal object JsonPathFilterNormalizer {
    val pathFunctions = setOf(
        "length", "size", "min", "max", "avg", "sum", "stddev", "keys", "first", "last",
        "index", "concat", "append",
    )
    private val infixFunctions = mapOf(
        "in" to "legadoin", "nin" to "legadonin", "subsetof" to "legadosubsetof",
        "anyof" to "legadoanyof", "noneof" to "legadononeof", "size" to "legadosize",
        "empty" to "legadoempty", "contains" to "legadocontains",
        "==" to "legadoeq", "!=" to "legadone", "===" to "legadostricteq", "!==" to "legadostrictne",
        "<" to "legadolt", "<=" to "legadole", ">" to "legadogt", ">=" to "legadoge",
    )
    private val numberSyntax = Regex("-?(?:0|[1-9][0-9]*)(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?")
    private const val MAX_NESTING = 128

    fun normalize(path: String): String = rewritePath(path, 0)

    private enum class Kind { VALUE, PATH, PATH_FUNCTION, ROOT_PATH, NUMBER, REGEX, OPERATOR, OTHER }

    private data class Token(
        val start: Int,
        val end: Int,
        val text: String,
        val kind: Kind,
        val argument: String = text,
        val pattern: String = "",
        val flags: String = "",
    ) {
        val isValue: Boolean get() = kind == Kind.VALUE || kind == Kind.PATH || kind == Kind.PATH_FUNCTION ||
            kind == Kind.ROOT_PATH || kind == Kind.NUMBER
        fun valueArgument(): String = when (kind) {
            Kind.PATH, Kind.ROOT_PATH -> pathArgument(text)
            Kind.NUMBER -> JsonPathFilterValues.jsonArgument(text)
            else -> argument
        }
    }

    fun isDefinitePath(path: String): Boolean {
        val syntax = JsonPathFunctionSyntax.inspect(path) ?: return false
        return !syntax.indefinite && !syntax.propertyUnion
    }

    private fun pathArgument(path: String): String = when {
        path.startsWith('$') -> "legadorootvalue(${JsonPathFilterValues.quote(path)})"
        requiresRelativeEvaluation(path) -> "legadorelativevalue(@,${JsonPathFilterValues.quote("$" + path.drop(1))})"
        isDefinitePath(path) -> "legadopathsinglevalue($path)"
        else -> "legadopathvalue($path)"
    }

    private fun requiresRelativeEvaluation(path: String): Boolean =
        path.startsWith('@') && path.length > 1

    private fun rewritePath(path: String, depth: Int): String {
        require(depth <= MAX_NESTING) { "JSONPath filter nesting exceeds $MAX_NESTING" }
        val result = StringBuilder(path.length)
        var index = 0
        while (index < path.length) {
            val start = index
            when (path[index]) {
                '\'', '"' -> {
                    index = JsonPathFilterValues.quotedEnd(path, index) ?: return path
                    result.append(path, start, index)
                }
                '[' -> {
                    val end = groupEnd(path, index, false, depth) ?: return path
                    val question = skipBlanks(path, index + 1)
                    if (question < end - 1 && path[question] == '?') {
                        result.append(path, index, question + 1)
                        result.append(rewriteExpression(path.substring(question + 1, end - 1), depth + 1))
                        result.append(']')
                    } else {
                        result.append(path, index, end)
                    }
                    index = end
                }
                else -> result.append(path[index++])
            }
        }
        return result.toString()
    }

    private fun rewriteExpression(
        expression: String,
        depth: Int,
        rootArgumentTypes: List<JsonPathFilterExpressionType>? = null,
    ): String {
        require(depth <= MAX_NESTING) { "JSONPath filter nesting exceeds $MAX_NESTING" }
        val tokens = tokenize(expression, depth) ?: return expression
        val replacements = mutableMapOf<Int, Pair<Int, String>>()
        val consumed = mutableSetOf<Int>()
        for (index in 1 until tokens.lastIndex) {
            val operator = tokens[index]
            if (operator.kind != Kind.OPERATOR) continue
            val left = tokens[index - 1]
            val right = tokens[index + 1]
            if (!leftBoundary(tokens, index - 1) || !rightBoundary(tokens, index + 1)) continue
            val replacement = if (operator.text == "=~") {
                regexCall(left, right)
            } else {
                val function = infixFunctions[operator.text.lowercase()] ?: continue
                if (!left.isValue || !right.isValue) continue
                "$function(${left.valueArgument()},${right.valueArgument()})"
            } ?: continue
            replacements[index - 1] = (index + 1) to replacement
            consumed.addAll(listOf(index - 1, index, index + 1))
        }
        // A terminal filter returns a Jayway list even when it selects no nodes.
        // Keep the complete query as an argument so ANTLR still validates its syntax.
        var argumentIndex = 0
        for (index in tokens.indices) {
            val token = tokens[index]
            if (token.text == ",") argumentIndex++
            val expectedType = rootArgumentTypes?.getOrNull(argumentIndex)
            val booleanOperand = tokens.getOrNull(index - 1)?.text in setOf("!", "&&", "||") ||
                tokens.getOrNull(index + 1)?.text in setOf("&&", "||")
            val logicalPosition = rootArgumentTypes == null || expectedType == LogicalType || booleanOperand
            if (index !in consumed && token.kind == Kind.ROOT_PATH) {
                val bareExists = leftBoundary(tokens, index) && rightBoundary(tokens, index) && logicalPosition
                val function = when {
                    bareExists -> "legadorootexists"
                    expectedType == NodesType -> "legadorootnodes"
                    else -> "legadorootvalue"
                }
                val model = if (bareExists) "@," else ""
                replacements[index] = index to "$function($model${JsonPathFilterValues.quote(token.text)})"
            }
            if (index !in consumed && token.kind == Kind.PATH_FUNCTION && logicalPosition &&
                leftBoundary(tokens, index) && rightBoundary(tokens, index)
            ) {
                replacements[index] = index to "legadopathexists(${token.text})"
            }
            if (index !in consumed && token.kind == Kind.PATH) {
                if (requiresRelativeEvaluation(token.text)) {
                    val relative = JsonPathFilterValues.quote("$" + token.text.drop(1))
                    val function = when {
                        logicalPosition && leftBoundary(tokens, index) && rightBoundary(tokens, index) -> "legadorootexists"
                        expectedType == NodesType -> "legadorelativenodes"
                        else -> "legadorelativevalue"
                    }
                    // Even simple selectors must preserve nested key-set kinds.
                    replacements[index] = index to "$function(@,$relative)"
                } else if (logicalPosition && leftBoundary(tokens, index) && rightBoundary(tokens, index)) {
                    terminalFilterPrefix(token.text, depth)?.let { prefix ->
                        replacements[index] = index to "legadofilterexists($prefix,${token.text})"
                    }
                }
            }
        }
        return buildString {
            var position = 0
            var index = 0
            while (index < tokens.size) {
                val token = tokens[index]
                append(expression, position, token.start)
                val replacement = replacements[index]
                if (replacement != null) {
                    append(replacement.second)
                    position = tokens[replacement.first].end
                    index = replacement.first + 1
                } else {
                    append(token.text)
                    position = token.end
                    index++
                }
            }
            append(expression, position, expression.length)
        }
    }

    private fun leftBoundary(tokens: List<Token>, index: Int): Boolean = index == 0 ||
        tokens[index - 1].text in setOf("!", "&&", "||", ",")

    private fun rightBoundary(tokens: List<Token>, index: Int): Boolean = index == tokens.lastIndex ||
        tokens[index + 1].text in setOf("&&", "||", ",")

    private fun regexCall(left: Token, right: Token): String? {
        val regex = when {
            left.kind == Kind.REGEX && right.isValue -> left
            right.kind == Kind.REGEX && left.isValue -> right
            else -> return null
        }
        JsonPathFilterValues.regex(regex.pattern, regex.flags)
        val input = if (regex === left) right else left
        return "legadoregex(${input.valueArgument()},${JsonPathFilterValues.quote(regex.pattern)}," +
            "${JsonPathFilterValues.quote(regex.flags)})"
    }

    private fun tokenize(text: String, depth: Int): List<Token>? {
        val tokens = mutableListOf<Token>()
        var index = 0
        while (index < text.length) {
            if (text[index].isWhitespace()) {
                index++
                continue
            }
            val start = index
            val token = when (val char = text[index]) {
                '\'', '"' -> {
                    index = JsonPathFilterValues.quotedEnd(text, index) ?: return null
                    Token(start, index, text.substring(start, index), Kind.VALUE)
                }
                '@', '$' -> {
                    index = pathEnd(text, index, depth) ?: return null
                    val path = rewritePath(text.substring(start, index), depth + 1)
                    if (char == '$') {
                        // Absolute queries consume EOF in JsonPath4K 3.0.1's function-argument grammar.
                        Token(start, index, path, Kind.ROOT_PATH)
                    } else {
                        val call = rewritePathCalls(path)
                        Token(start, index, call ?: path, if (call == null) Kind.PATH else Kind.PATH_FUNCTION)
                    }
                }
                '[', '{' -> {
                    index = groupEnd(text, index, false, depth) ?: return null
                    val literal = text.substring(start, index)
                    val argument = "legadocompound(${JsonPathFilterValues.quote(literal)})"
                    Token(start, index, argument, Kind.VALUE)
                }
                '(' -> {
                    index = groupEnd(text, index, true, depth) ?: return null
                    val body = rewriteExpression(text.substring(start + 1, index - 1), depth + 1)
                    Token(start, index, "($body)", Kind.OTHER)
                }
                '/' -> {
                    index = regexEnd(text, index) ?: return null
                    val literal = text.substring(start, index)
                    val slash = literal.lastIndexOf('/')
                    Token(start, index, literal, Kind.REGEX, pattern = literal.substring(1, slash),
                        flags = literal.substring(slash + 1))
                }
                '=', '!', '<', '>', '~', '&', '|' -> {
                    index++
                    while (index < text.length && text[index] in "=!<>~&|") index++
                    Token(start, index, text.substring(start, index), Kind.OPERATOR)
                }
                else -> when {
                    char in '0'..'9' || char == '-' -> {
                        index++
                        while (index < text.length && text[index] in "0123456789.eE+-") index++
                        val number = text.substring(start, index)
                        Token(start, index, number, if (numberSyntax.matches(number)) Kind.NUMBER else Kind.OTHER)
                    }
                    char.isLetter() || char == '_' -> {
                        index++
                        while (index < text.length && (text[index].isLetterOrDigit() || text[index] == '_')) index++
                        val word = text.substring(start, index)
                        if (index < text.length && text[index] == '(') {
                            val end = groupEnd(text, index, true, depth) ?: return null
                            val extension = JsonPathFilterFunctions.function(word)
                                ?: JsonPath.defaultFunctionExtensionRepository.getExtension(word)
                            val body = rewriteExpression(
                                text.substring(index + 1, end - 1), depth + 1,
                                extension?.argumentTypes?.toList() ?: emptyList(),
                            )
                            index = end
                            Token(start, end, "$word($body)", Kind.VALUE)
                        } else {
                            val kind = when {
                                word in setOf("true", "false", "null") -> Kind.VALUE
                                word.lowercase() in infixFunctions -> Kind.OPERATOR
                                else -> Kind.OTHER
                            }
                            Token(start, index, word, kind)
                        }
                    }
                    else -> Token(start, ++index, char.toString(), Kind.OTHER)
                }
            }
            tokens += token
        }
        return tokens
    }

    private fun pathEnd(text: String, start: Int, depth: Int): Int? {
        var index = start + 1
        while (index < text.length) {
            val char = text[index]
            if (char.isWhitespace() || char in ")<>=!&|,~") break
            index = when (char) {
                '[' -> groupEnd(text, index, false, depth) ?: return null
                '(' -> {
                    val end = groupEnd(text, index, false, depth) ?: return null
                    // FilterCompiler.readPath only retains an immediately closing function bracket.
                    require(end == index + 2) { "Jayway filter path functions require empty parentheses" }
                    end
                }
                '\'', '"' -> JsonPathFilterValues.quotedEnd(text, index) ?: return null
                else -> index + 1
            }
        }
        return index
    }

    fun terminalFilterPrefix(path: String): String? = terminalFilterPrefix(path, 0)

    private fun terminalFilterPrefix(path: String, depth: Int): String? {
        var index = 1
        while (index < path.length) {
            if (path[index] == '[') {
                val end = groupEnd(path, index, false, depth) ?: return null
                if (end == path.length && path.getOrNull(skipBlanks(path, index + 1)) == '?') {
                    return path.substring(0, index)
                }
                index = end
            } else index++
        }
        return null
    }

    private fun rewritePathCalls(path: String): String? {
        val syntax = JsonPathFunctionSyntax.inspect(path) ?: return null
        if (syntax.calls.isEmpty() || syntax.calls.any { it.name !in pathFunctions }) return null
        // Preserve the whole token chain: converting a base to ValueNode first loses
        // Set kind and changes scan inversion, events and empty-call continuations.
        return "legadorelativevalue(@,${JsonPathFilterValues.quote("$" + path.drop(1))})"
    }

    private fun groupEnd(text: String, start: Int, allowRegex: Boolean, depth: Int): Int? {
        require(depth <= MAX_NESTING) { "JSONPath filter nesting exceeds $MAX_NESTING" }
        val close = when (text[start]) { '[' -> ']'; '(' -> ')'; '{' -> '}'; else -> return null }
        val filter = text[start] == '[' && text.getOrNull(skipBlanks(text, start + 1)) == '?'
        var index = start + 1
        while (index < text.length) {
            index = when (text[index]) {
                '\'', '"' -> JsonPathFilterValues.quotedEnd(text, index) ?: return null
                '/' -> if (allowRegex || filter) regexEnd(text, index) ?: return null else index + 1
                '[', '(', '{' -> groupEnd(text, index, allowRegex || filter, depth + 1) ?: return null
                ']', ')', '}' -> return if (text[index] == close) index + 1 else null
                else -> index + 1
            }
        }
        return null
    }

    private fun regexEnd(text: String, start: Int): Int? {
        var index = start + 1
        while (index < text.length) {
            when (text[index]) {
                '\\' -> index += 2
                '/' -> {
                    index++
                    while (index < text.length && text[index].isLetter()) index++
                    return index
                }
                else -> index++
            }
        }
        return null
    }

    private fun skipBlanks(text: String, start: Int): Int {
        var index = start
        while (index < text.length && text[index].isWhitespace()) index++
        return index
    }
}
