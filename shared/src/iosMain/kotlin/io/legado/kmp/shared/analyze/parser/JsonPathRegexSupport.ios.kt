@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.legado.kmp.shared.analyze.parser

import platform.Foundation.NSMakeRange
import platform.Foundation.NSMatchingAnchored
import platform.Foundation.NSRegularExpression
import platform.Foundation.NSRegularExpressionAllowCommentsAndWhitespace
import platform.Foundation.NSRegularExpressionAnchorsMatchLines
import platform.Foundation.NSRegularExpressionCaseInsensitive
import platform.Foundation.NSRegularExpressionDotMatchesLineSeparators
import platform.Foundation.NSRegularExpressionOptions
import platform.Foundation.NSRegularExpressionUseUnixLineSeparators
import platform.Foundation.firstMatchInString

internal actual fun compileJsonPathRegex(pattern: String, flags: String): JsonPathRegexMatcher {
    require('U' !in flags) { "UNICODE_CHARACTER_CLASS flag not supported" }

    val options = flags.fold(0uL) { options, flag ->
        options or when (flag) {
            'd' -> NSRegularExpressionUseUnixLineSeparators
            'i' -> NSRegularExpressionCaseInsensitive
            'm' -> NSRegularExpressionAnchorsMatchLines
            's' -> NSRegularExpressionDotMatchesLineSeparators
            'x' -> NSRegularExpressionAllowCommentsAndWhitespace
            // Android accepts external u but only passes these five flags to ICU.
            else -> 0uL
        }
    }

    // Validate before adding terminators, so wrapping cannot repair an invalid pattern.
    val original = requireNotNull(compileFoundationJsonPathRegex(pattern, options)) {
        "Invalid JSONPath regular expression: $pattern"
    }
    validateAndroidQuoteTerminators(pattern, comments = 'x' in flags)

    // ICU must backtrack against the end anchor (e.g. a|ab against ab), not a range check.
    // A valid pattern can leave a trailing \\Q quote or x-mode # comment open at EOF.
    // Both swallow the wrapper's closing parenthesis, making its compilation fail.
    // Let ICU choose the necessary terminator instead of parsing its regex syntax here.
    val expression = listOf("", "\\E", "\n").firstNotNullOfOrNull { terminator ->
        compileFoundationJsonPathRegex("\\A(?:$pattern$terminator)\\z", options)
    } ?: throw IllegalArgumentException("Cannot anchor JSONPath regular expression: $pattern")

    check(expression.numberOfCaptureGroups == original.numberOfCaptureGroups) {
        "Anchoring changed JSONPath regular expression capture groups"
    }
    return FoundationJsonPathRegexMatcher(expression)
}

/** Foundation tolerates a stray \\E, whereas Android ICU rejects it as an invalid escape. */
private fun validateAndroidQuoteTerminators(pattern: String, comments: Boolean) {
    var index = 0
    var quoted = false
    var freeSpacing = comments
    // 0: start of set, 1: initial negation, 2: content; an initial ] is a literal.
    val classes = mutableListOf<Int>()
    val scopes = mutableListOf<Boolean>()
    while (index < pattern.length) {
        val char = pattern[index]
        val next = pattern.getOrNull(index + 1)
        if (quoted) {
            if (char == '\\' && next == 'E') {
                quoted = false
                index += 2
            } else {
                if (classes.isNotEmpty()) classes[classes.lastIndex] = 2
                index++
            }
            continue
        }
        if (char == '\\') {
            require(next != 'E') { "Invalid Android regular expression quote terminator" }
            if (next == 'Q') quoted = true
            else if (classes.isNotEmpty()) classes[classes.lastIndex] = 2
            index += 2
            continue
        }
        if (freeSpacing && char == '#') {
            while (index < pattern.length && pattern[index] !in "\n\r\u0085\u2028\u2029") index++
            continue
        }
        if (char == '[') {
            if (classes.isNotEmpty()) classes[classes.lastIndex] = 2
            classes.add(0)
            index++
            continue
        }
        if (classes.isNotEmpty()) {
            when {
                freeSpacing && char.isWhitespace() -> Unit
                char == ']' && classes.last() <= 1 -> classes[classes.lastIndex] = 2
                char == ']' -> classes.removeAt(classes.lastIndex)
                char == '^' && classes.last() == 0 -> classes[classes.lastIndex] = 1
                else -> classes[classes.lastIndex] = 2
            }
            index++
            continue
        }
        if (char == '(') {
            if (pattern.startsWith("(?#", index)) {
                index = pattern.indexOf(')', index + 3).let { if (it < 0) pattern.length else it + 1 }
                continue
            }
            if (next == '?') {
                var end = index + 2
                while (pattern.getOrNull(end)?.let { it in "dimsuxwU-" } == true) end++
                val delimiter = pattern.getOrNull(end)
                if (delimiter == ')' || delimiter == ':') {
                    if (delimiter == ':') scopes.add(freeSpacing)
                    var enabled = true
                    for (flag in pattern.substring(index + 2, end)) {
                        if (flag == '-') enabled = false
                        if (flag == 'x') freeSpacing = enabled
                    }
                    index = end + 1
                    continue
                }
            }
            scopes.add(freeSpacing)
        } else if (char == ')' && scopes.isNotEmpty()) {
            freeSpacing = scopes.removeAt(scopes.lastIndex)
        }
        index++
    }
}

private fun compileFoundationJsonPathRegex(
    pattern: String,
    options: NSRegularExpressionOptions,
): NSRegularExpression? = NSRegularExpression.regularExpressionWithPattern(
    pattern = pattern,
    options = options,
    error = null,
)

private class FoundationJsonPathRegexMatcher(
    private val expression: NSRegularExpression,
) : JsonPathRegexMatcher {
    override fun matches(input: String): Boolean = expression.firstMatchInString(
        string = input,
        options = NSMatchingAnchored,
        // Kotlin String.length and Foundation NSRange both count UTF-16 code units.
        range = NSMakeRange(0u, input.length.toULong()),
    ) != null
}
