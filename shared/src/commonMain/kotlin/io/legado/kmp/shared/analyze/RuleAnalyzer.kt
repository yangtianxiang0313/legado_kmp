package io.legado.kmp.shared.analyze

/**
 * Rule parser for splitting complex rule strings
 * Ported from Legado's RuleAnalyzer
 *
 * Handles rule syntax like:
 * - Single rules: "class.title"
 * - Split rules: "class.title@text@href"
 * - Nested rules: "class[expr]{{text}}"
 *
 * @param data The rule string to parse
 * @param code Whether to use code-balanced parsing (for JSON/JS)
 */
class RuleAnalyzer(
    private var queue: String,
    private val code: Boolean = false
) {
    private var pos: Int = 0           // Current processing position
    private var start: Int = 0         // Current field start
    private var startX: Int = 0        // Current rule start
    private var step: Int = 0          // Separator length
    private var trimmedStart: Int = 0
    var elementsType: String = ""     // Current separator type

    private val rule = mutableListOf<String>()

    companion object {
        private const val ESC = '\\'
    }

    /**
     * Trim whitespace and special characters before current position
     */
    fun trim() {
        if (pos < queue.length && (queue[pos] == '@' || queue[pos] < '!')) {
            pos++
            while (pos < queue.length && (queue[pos] == '@' || queue[pos] < '!')) {
                pos++
            }
            start = pos
            startX = pos
            trimmedStart = pos
        }
    }

    /**
     * Reset position to 0 for reusing the analyzer
     */
    fun resetPos() {
        pos = 0
        startX = 0
        trimmedStart = 0
    }

    /**
     * Consume characters until finding seq (case-sensitive)
     */
    private fun consumeTo(seq: String): Boolean {
        start = pos
        val offset = queue.indexOf(seq, pos)
        return if (offset != -1) {
            pos = offset
            true
        } else false
    }

    /**
     * Consume until finding any of the given sequences
     */
    private fun consumeToAny(vararg seq: String): Boolean {
        var tempPos = pos

        while (tempPos < queue.length) {
            for (s in seq) {
                if (queue.regionMatches(tempPos, s, 0, s.length)) {
                    step = s.length
                    pos = tempPos
                    return true
                }
            }
            tempPos++
        }
        return false
    }

    /**
     * Find position of any of the given characters
     */
    private fun findToAny(vararg seq: Char): Int {
        var tempPos = pos

        while (tempPos < queue.length) {
            for (s in seq) {
                if (queue[tempPos] == s) return tempPos
            }
            tempPos++
        }
        return -1
    }

    /**
     * Pull a balanced group (code mode)
     */
    private fun chompCodeBalanced(open: Char, close: Char): Boolean {
        var tempPos = pos
        var depth = 0
        var otherDepth = 0
        var inSingleQuote = false
        var inDoubleQuote = false

        do {
            if (tempPos >= queue.length) break
            val c = queue[tempPos++]
            if (c != ESC) {
                if (c == '\'' && !inDoubleQuote) inSingleQuote = !inSingleQuote
                else if (c == '"' && !inSingleQuote) inDoubleQuote = !inDoubleQuote

                if (!inSingleQuote && !inDoubleQuote) {
                    if (c == '[') depth++
                    else if (c == ']') depth--
                    else if (depth == 0) {
                        if (c == open) otherDepth++
                        else if (c == close) otherDepth--
                    }
                }
            } else {
                tempPos++
            }
        } while (depth > 0 || otherDepth > 0)

        return if (depth > 0 || otherDepth > 0) false
        else {
            pos = tempPos
            true
        }
    }

    /**
     * Pull a balanced group (rule mode)
     */
    private fun chompRuleBalanced(open: Char, close: Char): Boolean {
        var tempPos = pos
        var depth = 0
        var inSingleQuote = false
        var inDoubleQuote = false

        do {
            if (tempPos >= queue.length) break
            val c = queue[tempPos++]
            if (c == '\'' && !inDoubleQuote) inSingleQuote = !inSingleQuote
            else if (c == '"' && !inSingleQuote) inDoubleQuote = !inDoubleQuote

            if (!inSingleQuote && !inDoubleQuote) {
                if (c == '\\') {
                    tempPos++
                    continue
                }
                if (c == open) depth++
                else if (c == close) depth--
            }
        } while (depth > 0)

        return if (depth > 0) false
        else {
            pos = tempPos
            true
        }
    }

    /**
     * Split rule by delimiters
     * @param split Delimiter strings to split by
     * @return List of rule parts
     */
    fun splitRule(vararg split: String): List<String> {
        rule.clear()
        // trim() removes the leading legacy extraction marker; splitting must not resurrect it.
        pos = trimmedStart
        start = trimmedStart
        startX = trimmedStart
        elementsType = ""

        if (queue.isEmpty()) {
            return emptyList()
        }

        elementsType = when {
            split.isEmpty() -> ""
            split.size == 1 -> split[0]
            else -> findFirstTopLevelDelimiter(split) ?: return arrayListOf(queue.substring(startX))
        }

        if (elementsType.isEmpty()) {
            return arrayListOf(queue.substring(startX))
        }

        step = elementsType.length
        return splitByTopLevelDelimiter(elementsType)
    }

    /**
     * Choose balanced function based on mode
     */
    private val chompBalanced: (Char, Char) -> Boolean =
        if (code) ::chompCodeBalanced else ::chompRuleBalanced

    private fun findFirstTopLevelDelimiter(delimiters: Array<out String>): String? {
        var index = trimmedStart
        while (index < queue.length) {
            when (queue[index]) {
                '\'', '"' -> {
                    val quotedEnd = findQuotedEnd(index, queue[index])
                    if (quotedEnd != null) {
                        index = quotedEnd
                        continue
                    }
                }
                '[', '(' -> {
                    val close = if (queue[index] == '[') ']' else ')'
                    index = findBalancedEnd(index, queue[index], close)
                    continue
                }
            }

            for (delimiter in delimiters) {
                if (queue.regionMatches(index, delimiter, 0, delimiter.length)) {
                    return delimiter
                }
            }
            index++
        }
        return null
    }

    private fun splitByTopLevelDelimiter(delimiter: String): ArrayList<String> {
        val result = ArrayList<String>()
        var index = trimmedStart
        var segmentStart = trimmedStart

        while (index < queue.length) {
            when (queue[index]) {
                '\'', '"' -> {
                    val quotedEnd = findQuotedEnd(index, queue[index])
                    if (quotedEnd != null) {
                        index = quotedEnd
                        continue
                    }
                }
                '[', '(' -> {
                    val close = if (queue[index] == '[') ']' else ')'
                    index = findBalancedEnd(index, queue[index], close)
                    continue
                }
            }

            if (queue.regionMatches(index, delimiter, 0, delimiter.length)) {
                result += queue.substring(segmentStart, index)
                index += delimiter.length
                segmentStart = index
                continue
            }
            index++
        }

        result += queue.substring(segmentStart)
        return result
    }

    private fun findQuotedEnd(startIndex: Int, quote: Char): Int? {
        var index = startIndex + 1
        while (index < queue.length) {
            val char = queue[index]
            if (char == ESC) {
                index += 2
                continue
            }
            index++
            if (char == quote) {
                return index
            }
        }
        return null
    }

    private fun findBalancedEnd(startIndex: Int, open: Char, close: Char): Int {
        return if (code) {
            findCodeBalancedEnd(startIndex, open, close)
        } else {
            findRuleBalancedEnd(startIndex, open, close)
        }
    }

    private fun findCodeBalancedEnd(startIndex: Int, open: Char, close: Char): Int {
        var index = startIndex
        var depth = 0
        var otherDepth = 0
        var inSingleQuote = false
        var inDoubleQuote = false

        do {
            if (index >= queue.length) {
                throw IllegalArgumentException(queue.substring(0, start) + "后未平衡")
            }
            val c = queue[index++]
            if (c != ESC) {
                if (c == '\'' && !inDoubleQuote) inSingleQuote = !inSingleQuote
                else if (c == '"' && !inSingleQuote) inDoubleQuote = !inDoubleQuote

                if (!inSingleQuote && !inDoubleQuote) {
                    if (c == '[') depth++
                    else if (c == ']') depth--
                    else if (depth == 0) {
                        if (c == open) otherDepth++
                        else if (c == close) otherDepth--
                    }
                }
            } else {
                index++
            }
        } while (depth > 0 || otherDepth > 0)

        return index
    }

    private fun findRuleBalancedEnd(startIndex: Int, open: Char, close: Char): Int {
        var index = startIndex
        var depth = 0
        var inSingleQuote = false
        var inDoubleQuote = false

        do {
            if (index >= queue.length) {
                throw IllegalArgumentException(queue.substring(0, start) + "后未平衡")
            }
            val c = queue[index++]
            if (c == '\'' && !inDoubleQuote) inSingleQuote = !inSingleQuote
            else if (c == '"' && !inSingleQuote) inDoubleQuote = !inDoubleQuote

            if (!inSingleQuote && !inDoubleQuote) {
                if (c == '\\') {
                    index++
                    continue
                }
                if (c == open) depth++
                else if (c == close) depth--
            }
        } while (depth > 0)

        return index
    }

    /**
     * Parse inner rules (rules within {{}} or $$)
     *
     * @param startStr Start marker like "{{"
     * @param endStr End marker like "}}"
     * @param resolver Function to resolve inner rule
     * @return Parsed string with inner rules resolved
     */
    fun innerRule(
        startStr: String,
        endStr: String,
        resolver: (String) -> String?
    ): String {
        val result = StringBuilder()

        while (consumeTo(startStr)) {
            pos += startStr.length
            val prePos = pos

            if (consumeTo(endStr)) {
                val inner = queue.substring(prePos, pos)
                val resolved = resolver(inner)
                if (resolved != null) {
                    result.append(queue.substring(startX, prePos - startStr.length) + resolved)
                    startX = pos
                }
            }

            pos += endStr.length
        }

        return if (startX == 0) queue
        else result.append(queue.substring(startX)).toString()
    }

    /**
     * Parse legacy inner rules with "{$...$}" syntax
     *
     * @param inner Start marker
     * @param startStep Prefix length to skip
     * @param endStep Suffix length to skip
     * @param resolver Function to resolve inner rule
     * @return Parsed string
     */
    fun innerRuleLegacy(
        inner: String,
        startStep: Int = 1,
        endStep: Int = 1,
        resolver: (String) -> String?
    ): String {
        val result = StringBuilder()

        while (consumeTo(inner)) {
            val prePos = pos
            if (chompCodeBalanced('{', '}')) {
                val resolved = resolver(queue.substring(prePos + startStep, pos - endStep))
                if (!resolved.isNullOrEmpty()) {
                    result.append(queue.substring(startX, prePos) + resolved)
                    startX = pos
                    continue
                }
            }
            pos += inner.length
        }

        return if (startX == 0) "" else result.append(queue.substring(startX)).toString()
    }

    /**
     * Get remaining string from current position
     */
    fun getRemaining(): String = queue.substring(pos)

    /**
     * Check if there's more content to process
     */
    fun hasMore(): Boolean = pos < queue.length

    /**
     * Peek at the next character without consuming it
     */
    fun peek(): Char? = if (pos < queue.length) queue[pos] else null

    /**
     * Consume next character if it matches
     */
    fun consume(expected: Char): Boolean {
        return if (peek() == expected) {
            pos++
            true
        } else false
    }

    /**
     * Get the current position
     */
    fun getPosition(): Int = pos
}

/**
 * Split a rule string into parts
 *
 * @param rule The rule string to split
 * @param delimiters Delimiters to split by
 * @return List of rule parts
 */
fun splitRule(rule: String, vararg delimiters: String): List<String> {
    val analyzer = RuleAnalyzer(rule)
    return analyzer.splitRule(*delimiters)
}

/**
 * Common rule delimiters
 */
object RuleDelimiters {
    const val PIPE = "|"
    const val AT = "@"
    const val COMMA = ","
    const val SPACE = " "
}

/**
 * Common rule markers
 */
object RuleMarkers {
    const val DOUBLE_BRACE_START = "{{"
    const val DOUBLE_BRACE_END = "}}"
    const val DOLLAR_START = "\${"
    const val DOLLAR_END = "}"
}
