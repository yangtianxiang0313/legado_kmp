package io.legado.kmp.shared.analyze.parser

import io.legado.kmp.shared.analyze.AnalyzeResult

/**
 * Regular expression rule parser
 * Handles regex pattern matching and extraction
 *
 * Aligned with legado's AnalyzeByRegex.kt
 */
class RegexRuleParser {

    /**
     * LRU-limited regex cache (aligned with legado's getOrPutLimit(16)).
     * When the cache is full, new entries are not added to prevent unbounded growth.
     */
    private val regexCache = mutableMapOf<String, kotlin.text.Regex>()
    private val REGEX_CACHE_MAX_SIZE = 16

    /**
     * Parse and evaluate a regex rule
     *
     * Rule format: "pattern:replacement" or just "pattern"
     * @param rule Rule string
     * @param content Text to parse
     * @return AnalyzeResult with matched/replaced text
     */
    fun evaluate(rule: String, content: String): AnalyzeResult {
        if (content.isBlank()) {
            return AnalyzeResult.StringVal("")
        }

        val delimiter = findReplacementDelimiter(rule)
        val pattern = if (delimiter >= 0) rule.substring(0, delimiter) else rule
        val replacement = if (delimiter >= 0) rule.substring(delimiter + 1) else ""

        return try {
            val regex = getRegex(pattern)

            // If there's a replacement, do replace; otherwise just find first match
            val result = if (replacement.isNotEmpty()) {
                regex.replace(content, replacement)
            } else {
                regex.find(content)?.value ?: ""
            }

            // Check if result is numeric
            if (result.isNotEmpty() && result.all { it.isDigit() }) {
                AnalyzeResult.IntVal(result.toInt())
            } else {
                AnalyzeResult.StringVal(result)
            }
        } catch (e: Exception) {
            AnalyzeResult.StringVal("")
        }
    }

    private fun findReplacementDelimiter(rule: String): Int {
        var index = 0
        var quote: Char? = null
        var escaped = false
        var charClassDepth = 0
        var parenDepth = 0
        var regexQuoted = false
        while (index < rule.length) {
            val char = rule[index]
            if (escaped) {
                escaped = false
                index++
                continue
            }
            if (regexQuoted) {
                if (char == '\\' && index + 1 < rule.length && rule[index + 1] == 'E') {
                    regexQuoted = false
                    index += 2
                } else {
                    index++
                }
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
                char == '\\' && index + 1 < rule.length && rule[index + 1] == 'Q' -> {
                    regexQuoted = true
                    index += 2
                }
                char == '\\' -> {
                    escaped = true
                    index++
                }
                char == '\'' || char == '"' -> {
                    quote = char
                    index++
                }
                char == '[' -> {
                    charClassDepth++
                    index++
                }
                char == ']' -> {
                    if (charClassDepth > 0) charClassDepth--
                    index++
                }
                charClassDepth == 0 && char == '(' -> {
                    parenDepth++
                    index++
                }
                charClassDepth == 0 && char == ')' -> {
                    if (parenDepth > 0) parenDepth--
                    index++
                }
                char == ':' &&
                    charClassDepth == 0 &&
                    parenDepth == 0 &&
                    rule.getOrNull(index - 1) != '?' -> {
                    return index
                }
                else -> index++
            }
        }
        return -1
    }

    /**
     * Get all matches for a regex pattern
     *
     * @param pattern Regex pattern
     * @param content Text to search
     * @return List of matched strings
     */
    fun findAll(pattern: String, content: String): List<String> {
        return try {
            val regex = getRegex(pattern)
            regex.findAll(content).map { it.value }.toList()
        } catch (e: Exception) {
            emptyList()
        }
    }

    /**
     * Get all matches with group0..groupN preserved for each match.
     *
     * This intentionally does not change findAll/extractAll: callers that need
     * legacy full-match strings can keep using those methods, while element
     * parsing can expose capture groups for later $1/$2 field rules.
     */
    fun findAllGroups(pattern: String, content: String): List<List<String>> {
        return try {
            val regex = getRegex(pattern)
            regex.findAll(content).map { it.groupValues }.toList()
        } catch (e: Exception) {
            emptyList()
        }
    }

    /**
     * Get or create cached regex, with LRU-style size limit (16).
     * Aligned with legado's regexCache.getOrPutLimit(regex, 16).
     * When cache is full, the regex is still compiled but not cached.
     */
    private fun getRegex(pattern: String): kotlin.text.Regex {
        regexCache[pattern]?.let { return it }
        val compiled = kotlin.text.Regex(pattern)
        if (regexCache.size < REGEX_CACHE_MAX_SIZE) {
            regexCache[pattern] = compiled
        }
        return compiled
    }

    /**
     * Test if a pattern is valid
     *
     * @param pattern Regex pattern to test
     * @return True if valid
     */
    fun isValid(pattern: String): Boolean {
        return try {
            getRegex(pattern)
            true
        } catch (e: Exception) {
            false
        }
    }

    /**
     * Extract multiple groups from regex
     *
     * @param pattern Pattern with capture groups
     * @param content Text to parse
     * @return List of captured groups
     */
    fun extractGroups(pattern: String, content: String): List<String?> {
        return try {
            val regex = getRegex(pattern)
            val match = regex.find(content)
            match?.groupValues?.drop(1) ?: emptyList()
        } catch (e: Exception) {
            emptyList()
        }
    }

    /**
     * Extract all matches from content
     * Alias for findAll for API consistency
     *
     * @param pattern Regex pattern
     * @param content Text to search
     * @return List of matched strings
     */
    fun extractAll(pattern: String, content: String): List<String> {
        return findAll(pattern, content)
    }

    /**
     * Recursive single-match extraction (aligned with AnalyzeByRegex.getElement)
     *
     * Applies regex patterns recursively:
     * - At intermediate patterns: concatenates all matches and passes to next pattern
     * - At final pattern: returns all capture groups from the first match
     *
     * @param res Input string
     * @param regs Array of regex patterns to apply in sequence
     * @param index Current pattern index
     * @return List of capture groups from first match at final pattern, or null if no match
     */
    fun getElement(res: String, regs: Array<String>, index: Int = 0): List<String>? {
        var vIndex = index
        val regex = try {
            getRegex(regs[vIndex])
        } catch (e: Exception) {
            return null
        }
        val firstMatch = regex.find(res) ?: return null
        return if (vIndex + 1 == regs.size) {
            // Final regex: return group0..groupN from the first match.
            firstMatch.groupValues
        } else {
            // Intermediate regex: concatenate all matches and recurse
            val result = StringBuilder()
            var match: MatchResult? = firstMatch
            while (match != null) {
                result.append(match.value)
                match = match.next()
            }
            getElement(result.toString(), regs, ++vIndex)
        }
    }

    /**
     * Recursive multi-match extraction (aligned with AnalyzeByRegex.getElements)
     *
     * Applies regex patterns recursively:
     * - At intermediate patterns: concatenates all matches and passes to next pattern
     * - At final pattern: returns all matches, each as a list of capture groups
     *
     * @param res Input string
     * @param regs Array of regex patterns to apply in sequence
     * @param index Current pattern index
     * @return List of lists (each inner list = capture groups from one match)
     */
    fun getElements(res: String, regs: Array<String>, index: Int = 0): List<List<String>> {
        var vIndex = index
        val regex = try {
            getRegex(regs[vIndex])
        } catch (e: Exception) {
            return emptyList()
        }
        val firstMatch = regex.find(res) ?: return emptyList()
        if (vIndex + 1 == regs.size) {
            // Final regex: collect all matches, each as list of groups
            val books = ArrayList<List<String>>()
            var match: MatchResult? = firstMatch
            while (match != null) {
                val info = arrayListOf<String>()
                for (groupIndex in 0..match.groupValues.lastIndex) {
                    info.add(match.groupValues[groupIndex])
                }
                books.add(info)
                match = match.next()
            }
            return books
        } else {
            // Intermediate regex: concatenate all matches and recurse
            val result = StringBuilder()
            var match: MatchResult? = firstMatch
            while (match != null) {
                result.append(match.value)
                match = match.next()
            }
            return getElements(result.toString(), regs, ++vIndex)
        }
    }

    /**
     * Clear the regex cache
     */
    fun clearCache() {
        regexCache.clear()
    }

    companion object {
        /**
         * Test a regex pattern
         */
        fun testPattern(pattern: String): Boolean {
            return RegexRuleParser().isValid(pattern)
        }
    }
}
