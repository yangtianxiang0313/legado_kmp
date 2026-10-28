package io.legado.kmp.shared.analyze

internal fun splitRegexRules(rule: kotlin.String): Array<kotlin.String> {
    val pattern = if (rule.startsWith("##")) rule.substring(2) else rule
    return splitTopLevelRegexRules(pattern).filter { it.isNotBlank() }.toTypedArray()
}

private fun splitTopLevelRegexRules(pattern: kotlin.String): List<kotlin.String> {
    if (!pattern.contains("&&")) {
        return listOf(pattern)
    }
    val result = ArrayList<kotlin.String>()
    var start = 0
    var index = 0
    var templateDepth = 0
    var bracketDepth = 0
    var parenDepth = 0
    var braceDepth = 0
    var quote: Char? = null
    var escaped = false
    var regexQuoted = false
    while (index < pattern.length) {
        val char = pattern[index]
        if (escaped) {
            escaped = false
            index++
            continue
        }
        if (regexQuoted) {
            if (char == '\\' && index + 1 < pattern.length && pattern[index + 1] == 'E') {
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
            char == '\\' && index + 1 < pattern.length && pattern[index + 1] == 'Q' -> {
                regexQuoted = true
                index += 2
            }
            char == '\\' -> {
                escaped = true
                index++
            }
            char == '\'' || char == '"' || char == '`' -> {
                quote = char
                index++
            }
            index + 1 < pattern.length && char == '{' && pattern[index + 1] == '{' -> {
                templateDepth++
                index += 2
            }
            templateDepth > 0 && index + 1 < pattern.length && char == '}' && pattern[index + 1] == '}' -> {
                templateDepth--
                index += 2
            }
            templateDepth == 0 &&
                bracketDepth == 0 &&
                parenDepth == 0 &&
                braceDepth == 0 &&
                index + 1 < pattern.length &&
                char == '&' &&
                pattern[index + 1] == '&' -> {
                result += pattern.substring(start, index)
                index += 2
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
    result += pattern.substring(start)
    return result
}

private fun shouldReturnLegacyRegexRefLiteral(
    sourceRule: SourceRule,
    previousResult: AnalyzeResult
): kotlin.Boolean {
    // Regex mode is also used for legacy $N field references in getString/getStringList.
    if (sourceRule.type == RuleType.JS) {
        return false
    }
    if (!regexGroupRefPattern.containsMatchIn(sourceRule.rule)) {
        return false
    }
    val values: List<String?> = when (previousResult) {
        is AnalyzeResult.StringList -> previousResult.values
        is AnalyzeResult.Elements -> previousResult.values.map { it.toString() }
        else -> return false
    }
    if (values.isEmpty()) return false
    return regexGroupRefPattern.findAll(sourceRule.rule).any { match ->
        val index = match.groupValues[1].toIntOrNull() ?: return@any false
        index > 0 && values.size > index && values[index] != null
    }
}

internal fun tryReturnLegacyLiteralResult(
    sourceRule: SourceRule,
    resolvedRule: SourceRule,
    currentResult: AnalyzeResult
): AnalyzeResult? {
    if (resolvedRule.cleanRule.isBlank() && resolvedRule.replaceRegex.isNotEmpty()) {
        return currentResult
    }
    if (resolvedRule.cleanRule.isBlank() && sourceRule.putMap.isNotEmpty()) {
        return currentResult
    }
    if (
        sourceRule.rawRule.contains("@get:", ignoreCase = true) &&
        sourceRule.type != RuleType.REGEX &&
        sourceRule.type != RuleType.JS
    ) {
        return AnalyzeResult.StringVal(resolvedRule.cleanRule)
    }
    if (shouldReturnLegacyRegexRefLiteral(sourceRule, currentResult)) {
        return AnalyzeResult.StringVal(resolvedRule.cleanRule)
    }
    if (shouldReturnLegacyTemplateLiteral(sourceRule, resolvedRule)) {
        return AnalyzeResult.StringVal(resolvedRule.cleanRule)
    }
    return null
}

private fun shouldReturnLegacyTemplateLiteral(
    sourceRule: SourceRule,
    resolvedRule: SourceRule
): kotlin.Boolean {
    val start = sourceRule.rule.indexOf("{{")
    if (start < 0 || findLegacyInlineExpressionEnd(sourceRule.rule, start) < 0) return false
    if (sourceRule.type == RuleType.JS || sourceRule.type == RuleType.REGEX) return false
    if (resolvedRule.type == RuleType.JS) return false
    // Android's SourceRule switches non-JS selectors into literal Regex mode here.
    return !sourceRule.rule.substring(0, start).contains("##")
}

internal fun applyRuleReplacement(
    result: AnalyzeResult,
    sourceRule: SourceRule
): AnalyzeResult {
    if (sourceRule.replaceRegex.isEmpty()) {
        return result
    }
    return when (result) {
        is AnalyzeResult.StringVal -> AnalyzeResult.StringVal(
            applyRegexReplacement(result.value, sourceRule)
        )
        is AnalyzeResult.StringList -> AnalyzeResult.StringList(
            result.values.map { applyRegexReplacement(it, sourceRule) }
        )
        is AnalyzeResult.Elements -> AnalyzeResult.StringList(
            result.values.map { applyRegexReplacement(it.toString(), sourceRule) }
        )
        else -> AnalyzeResult.StringVal(
            applyRegexReplacement(result.asString(), sourceRule)
        )
    }
}

/**
 * Apply regex replacement to a string value.
 * Aligned with original's replaceRegex behavior:
 * - replaceFirst=true: find first match, take matched text, apply replaceFirst on it.
 *   If no match, return empty string.
 * - replaceFirst=false: replace all occurrences.
 */
private fun applyRegexReplacement(
    value: String,
    sourceRule: SourceRule
): String {
    if (sourceRule.replaceRegex.isEmpty()) return value
    return if (sourceRule.replaceFirst) {
        runCatching {
            val regex = Regex(sourceRule.replaceRegex)
            val match = regex.find(value)
            if (match != null) {
                match.value.replaceFirst(regex, sourceRule.replacement)
            } else {
                ""
            }
        }.getOrElse { sourceRule.replacement }
    } else {
        runCatching {
            value.replace(Regex(sourceRule.replaceRegex), sourceRule.replacement)
        }.getOrElse {
            value.replace(sourceRule.replaceRegex, sourceRule.replacement)
        }
    }
}

/**
 * Apply regex replacement to a result that may be a list or string
 */
internal fun applyRegexReplacementToResult(result: Any?, sourceRule: SourceRule): Any? {
    if (result == null) return null
    return applyRegexReplacement(result.toString(), sourceRule)
}

internal val regexGroupRefPattern = Regex("""\$(\d{1,2})""")
