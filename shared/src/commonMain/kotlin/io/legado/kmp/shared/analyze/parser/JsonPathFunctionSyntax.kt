package io.legado.kmp.shared.analyze.parser

/** Only function boundaries and parameter compilation; all node selection stays in the backend. */
internal object JsonPathFunctionSyntax {
    val names = setOf(
        "length", "size", "min", "max", "avg", "sum", "stddev",
        "first", "last", "index", "keys", "concat", "append",
    )

    data class Call(
        val name: String,
        val prefix: String,
        val arguments: String,
        val end: Int,
        val scanBefore: Boolean = false,
    )

    data class Inspection(
        val path: String,
        val calls: List<Call>,
        val indefinite: Boolean,
        val propertyUnion: Boolean,
        val rootScan: Boolean,
        val hasFilterOrScan: Boolean = false,
    ) {
        val tail: Call? get() = calls.lastOrNull()?.takeIf { it.end == path.length }

        /** Node-selection fragments after each call, excluding the next function token. */
        val continuations: List<String> get() = calls.mapIndexed { index, call ->
            val end = calls.getOrNull(index + 1)?.prefix?.length ?: path.length
            val fragment = path.substring(call.end, end)
            if (call.arguments.isEmpty() && call.end < path.length) {
                // PathCompiler resumes AT ')' for an empty call, so it becomes a
                // real property token before the next dot/bracket, not a no-op.
                require(fragment.isEmpty() || fragment.first() == '.' || fragment.first() == '[')
                "[')']$fragment"
            } else {
                fragment
            }
        }
    }

    data class Parameter(val text: String, val isPath: Boolean)

    fun inspect(path: String): Inspection? {
        val layout = layout(path) ?: return null
        val calls = mutableListOf<Call>()
        var indefinite = false
        var propertyUnion = false
        var hasFilterOrScan = false
        for (index in path.indices) {
            if (layout.depth[index] != 0) continue
            when (path[index]) {
                '*' -> indefinite = true
                '.' -> if (path.getOrNull(index + 1) == '.') {
                    indefinite = true
                    hasFilterOrScan = true
                }
                '[' -> {
                    val close = layout.close[index]
                    if (close < 0) return null
                    val content = path.substring(index + 1, close).trimStart()
                    if (content.startsWith('?')) hasFilterOrScan = true
                    if (content.firstOrNull() == '\'' || content.firstOrNull() == '"') {
                        if ((index + 1 until close).any { layout.depth[it] == 1 && path[it] == ',' }) {
                            propertyUnion = true
                        }
                    } else if (content.any { it == '*' || it == '?' || it == ':' || it == ',' }) {
                        indefinite = true
                    }
                }
                '(' -> {
                    var start = index
                    while (start > 0 && (path[start - 1].isLetterOrDigit() || path[start - 1] == '_')) start--
                    if (start == index || (start > 0 && path[start - 1] != '.')) continue
                    val close = layout.close[index]
                    if (close < 0) return null
                    calls += Call(
                        path.substring(start, index),
                        if (start == 0) "" else path.substring(0, start - 1),
                        path.substring(index + 1, close),
                        close + 1,
                        start >= 2 && path[start - 2] == '.' && layout.depth[start - 2] == 0,
                    )
                }
            }
        }
        return Inspection(
            path, calls, indefinite, propertyUnion,
            path.startsWith("$..") || path.startsWith("@.."),
            hasFilterOrScan,
        )
    }

    /**
     * Mirrors PathCompiler.parseFunctionParameters, including its quirks:
     * only {, digit, double quote and - start JSON; $/@ start PATH; bare
     * booleans/null/single-quoted text are otherwise ignored. '[' is grouping,
     * not a parameter start. Commas inside top-level quoted strings are dropped.
     */
    fun parameters(arguments: String): List<Parameter> {
        if (arguments.isEmpty()) return emptyList()
        val input = "$arguments)"
        val parameters = mutableListOf<Parameter>()
        val parameter = StringBuilder()
        var isPath: Boolean? = null
        var parens = 1
        var brackets = 0
        var braces = 0
        var quotes = 0
        var prior = '\u0000'
        var ended = false
        for (char in input) {
            if (ended) break
            if (isPath == null) {
                if (char == ' ' || char == '\t' || char == '\n' || char == '\r') continue
                if (char == '{' || char in '0'..'9' || char == '"' || char == '-') {
                    isPath = false
                } else if (char == '$' || char == '@') {
                    isPath = true
                }
            }
            when (char) {
                '"' -> if (prior != '\\' && quotes > 0) quotes-- else quotes++
                '(' -> parens++
                '{' -> braces++
                '[' -> brackets++
                '}' -> { require(braces > 0); braces-- }
                ']' -> { require(brackets > 0); brackets-- }
                ')' -> {
                    parens--
                    if (parens < 0 || prior == '(') parameter.append(char)
                }
            }
            if ((char == ')' || char == ',') && quotes == 0 && braces == 0 && brackets == 0 &&
                ((parens == 0 && char == ')') || parens == 1)
            ) {
                ended = parens == 0
                isPath?.let { kind ->
                    parameters += Parameter(parameter.toString(), kind)
                    parameter.clear()
                    isPath = null
                }
            }
            if (isPath != null && !(char == ',' && braces == 0 && brackets == 0 && parens == 1)) {
                parameter.append(char)
            }
            prior = char
        }
        require(braces == 0 && parens == 0 && brackets == 0)
        return parameters
    }

    private data class Layout(val depth: IntArray, val close: IntArray)

    private fun layout(text: String): Layout? {
        val depth = IntArray(text.length) { -1 }
        val close = IntArray(text.length) { -1 }
        val stack = mutableListOf<Pair<Char, Int>>()
        var quote: Char? = null
        var regex = false
        var regexClass = false
        var escaped = false
        var previous = '\u0000'
        for (index in text.indices) {
            val char = text[index]
            if (escaped) {
                escaped = false
                continue
            }
            if (quote != null) {
                if (char == '\\') escaped = true else if (char == quote) {
                    quote = null
                    previous = char
                }
                continue
            }
            if (regex) {
                when {
                    char == '\\' -> escaped = true
                    char == '[' -> regexClass = true
                    char == ']' -> regexClass = false
                    char == '/' && !regexClass -> { regex = false; previous = char }
                }
                continue
            }
            if (char == '\'' || char == '"') {
                quote = char
                continue
            }
            if (char == '/' && previous == '~') {
                regex = true
                continue
            }
            depth[index] = stack.size
            when (char) {
                '[', '(', '{' -> stack += char to index
                ']', ')', '}' -> {
                    val open = stack.removeLastOrNull() ?: return null
                    val expected = when (char) { ']' -> '['; ')' -> '('; else -> '{' }
                    if (open.first != expected) return null
                    close[open.second] = index
                }
            }
            if (!char.isWhitespace()) previous = char
        }
        if (quote != null || regex || escaped || stack.isNotEmpty()) return null
        return Layout(depth, close)
    }
}
