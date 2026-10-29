package io.legado.kmp.shared.analyze

import io.legado.kmp.shared.analyze.parser.JsonPathJsonReader
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * Parsed rule representation.
 */
data class SourceRule(
    val rule: String,
    val type: RuleType = RuleType.CSS,
    val rawRule: String = rule,
    val putMap: Map<String, String> = emptyMap(),
    val replaceRegex: String = "",
    val replacement: String = "",
    val replaceFirst: Boolean = false,
    val putRuleKeys: Set<String> = putMap.keys.toSet(),
) {
    val isJs: Boolean
        get() = rule.startsWith("@js:", ignoreCase = true) || rule.startsWith("<js>", ignoreCase = true)

    val isXPath: Boolean
        get() = rule.startsWith("@xpath:", ignoreCase = true) || rule.startsWith("/")

    val isJsonPath: Boolean
        get() = rule.startsWith("$.") || rule.startsWith("$[") || rule.startsWith("@json:", ignoreCase = true)

    val isRegex: Boolean
        get() = rule.startsWith("##")

    val isJson: Boolean
        get() = rule.startsWith("@json:", ignoreCase = true)

    val isCss: Boolean
        get() = rule.startsWith("@css:", ignoreCase = true) || (!isJs && !isXPath && !isJsonPath && !isRegex)

    /**
     * Get the actual rule content (without prefix).
     */
    val cleanRule: String
        get() = when {
            rule.startsWith("@js:", ignoreCase = true) -> rule.substring(4)
            rule.startsWith("<js>", ignoreCase = true) -> rule.substring(4)
            rule.startsWith("@xpath:", ignoreCase = true) -> rule.substring(7)
            rule.startsWith("@css:", ignoreCase = true) -> rule
            rule.startsWith("@json:", ignoreCase = true) -> rule.substring(6)
            else -> rule
        }

    companion object {
        /**
         * Parse a rule string into SourceRule.
         */
        fun parse(rule: String): SourceRule {
            val trimmed = rule.trim()
            val (withoutPut, putMap, putRuleKeys) = extractPutMap(trimmed)
            val replaceParts = splitLegacyReplaceSegments(withoutPut)
            val originalRule = replaceParts.firstOrNull()?.trim().orEmpty()
            val parsedRule = when {
                originalRule.startsWith("@@") -> originalRule.substring(2)
                originalRule.startsWith("@CSS:", ignoreCase = true) -> originalRule
                else -> originalRule
            }
            var type = when {
                parsedRule.startsWith("@js:", ignoreCase = true) || parsedRule.startsWith("<js>", ignoreCase = true) -> RuleType.JS
                parsedRule.startsWith("@xpath:", ignoreCase = true) || parsedRule.startsWith("/") -> RuleType.XPATH
                parsedRule.startsWith("$.") || parsedRule.startsWith("$[") -> RuleType.JSONPATH
                parsedRule.startsWith("@json:", ignoreCase = true) -> RuleType.JSON
                parsedRule.startsWith("##") -> RuleType.REGEX
                else -> RuleType.CSS
            }
            if (type == RuleType.CSS && replaceParts.size == 1 && hasRegexContextAroundTemplate(originalRule)) {
                type = RuleType.REGEX
            }
            return SourceRule(
                rule = parsedRule,
                type = type,
                rawRule = rule,
                putMap = putMap,
                replaceRegex = replaceParts.getOrElse(1) { "" },
                replacement = replaceParts.getOrElse(2) { "" },
                replaceFirst = replaceParts.size > 3,
                putRuleKeys = putRuleKeys,
            )
        }

        private fun extractPutMap(rule: String): Triple<String, Map<String, String>, Set<String>> {
            val putMap = linkedMapOf<String, String>()
            val ruleKeys = mutableSetOf<String>()
            var stripped = rule
            while (true) {
                val start = stripped.indexOf("@put:", ignoreCase = true)
                if (start < 0) break
                val braceStart = stripped.indexOf('{', start)
                if (braceStart < 0) break
                val end = findLegacyPutBlockEnd(stripped, braceStart)
                if (end < 0) break
                val jsonText = stripped.substring(braceStart, end + 1)
                val (parsed, legacyLiteral) = parseJsonObject(jsonText)
                putMap.putAll(parsed)
                if (legacyLiteral) ruleKeys.removeAll(parsed.keys) else ruleKeys.addAll(parsed.keys)
                stripped = stripped.removeRange(start, end + 1)
            }
            return Triple(stripped.trim(), putMap, ruleKeys)
        }

        private fun findLegacyPutBlockEnd(rule: String, braceStart: Int): Int {
            var depth = 0
            var quote: Char? = null
            var escaped = false
            var index = braceStart
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
                when (char) {
                    '\'', '"' -> quote = char
                    '{' -> depth++
                    '}' -> {
                        depth--
                        if (depth == 0) return index
                    }
                }
                index++
            }
            return -1
        }

        private fun hasRegexContextAroundTemplate(rule: String): Boolean {
            if (!rule.contains("{{@get:", ignoreCase = true)) return false
            var stripped = rule
            while (true) {
                val start = stripped.indexOf("{{")
                if (start < 0) break
                var depth = 0
                var end = -1
                var i = start + 2
                while (i < stripped.length - 1) {
                    val c = stripped[i]
                    if (c == '{') {
                        depth++
                    } else if (c == '}' && depth > 0) {
                        depth--
                    } else if (c == '}' && stripped[i + 1] == '}' && depth == 0) {
                        end = i
                        break
                    }
                    i++
                }
                if (end < 0) break
                stripped = stripped.substring(0, start) + stripped.substring(end + 2)
            }
            return stripped.hasStrongRegexSyntax()
        }

        private fun String.hasStrongRegexSyntax(): Boolean {
            var escaped = false
            for (index in indices) {
                val char = this[index]
                if (escaped) {
                    if (char in "dDsSwWbBAZGQ") return true
                    escaped = false
                    continue
                }
                when (char) {
                    '\\' -> escaped = true
                    '[', ']', '(', ')', '^', '$', '|', '*' -> return true
                    '{' -> if (findRegexQuantifierEnd(index) > index) return true
                }
            }
            return false
        }

        private fun String.findRegexQuantifierEnd(start: Int): Int {
            var index = start + 1
            var sawDigit = false
            while (index < length) {
                val char = this[index]
                when {
                    char.isDigit() -> sawDigit = true
                    char == ',' -> Unit
                    char == '}' -> return if (sawDigit) index else -1
                    else -> return -1
                }
                index++
            }
            return -1
        }

        private fun splitLegacyReplaceSegments(rule: String): List<String> {
            return splitLegacyRuleSegments(rule, "##")
        }

        private fun splitLegacyRuleSegments(rule: String, delimiter: String): List<String> {
            if (!rule.contains(delimiter)) return listOf(rule)
            val parts = mutableListOf<String>()
            var start = 0
            var index = 0
            var templateDepth = 0
            var bracketDepth = 0
            var parenDepth = 0
            var braceDepth = 0
            var quote: Char? = null
            var escaped = false
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
                    if (char == '\\' && rule.startsWith(delimiter, index + 1)) {
                        index += delimiter.length + 1
                        continue
                    } else if (char == '\\') {
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
                    char == '\\' && rule.startsWith(delimiter, index + 1) -> {
                        index += delimiter.length + 1
                    }
                    char == '\\' -> {
                        escaped = true
                        index++
                    }
                    char == '\'' || char == '"' -> {
                        quote = char
                        index++
                    }
                    index + 1 < rule.length && char == '{' && rule[index + 1] == '{' -> {
                        templateDepth++
                        index += 2
                    }
                    templateDepth > 0 && index + 1 < rule.length && char == '}' && rule[index + 1] == '}' -> {
                        templateDepth--
                        index += 2
                    }
                    templateDepth == 0 &&
                        bracketDepth == 0 &&
                        parenDepth == 0 &&
                        braceDepth == 0 &&
                        rule.startsWith(delimiter, index) -> {
                        parts += rule.substring(start, index)
                        index += delimiter.length
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
            parts += rule.substring(start)
            return parts
        }

        private var loggedNonStandardJSON: Boolean = false

        internal fun resetNonStandardJsonWarning() {
            loggedNonStandardJSON = false
        }

        private fun parseJsonObject(text: String): Pair<Map<String, String>, Boolean> {
            val content = text.removePrefix("{").removeSuffix("}")
            if (content.isBlank()) return emptyMap<String, String>() to false
            runCatching { Json.parseToJsonElement("{$content}") }
                .getOrNull()
                ?.let { element ->
                    val objectValue = element as? JsonObject ?: return@let
                    return extractJsonMap(objectValue) to false
                }
            runCatching { JsonPathJsonReader.parseComplete("{$content}") }
                .getOrNull()
                ?.let { element ->
                    val objectValue = element as? JsonObject ?: return@let
                    if (!loggedNonStandardJSON) {
                        println("AnalyzeRule: @put rule JSON format is non-standard, please use standard format")
                        loggedNonStandardJSON = true
                    }
                    return extractJsonMap(objectValue) to false
                }
            // The comma-pair extension predates JSON-object rules and retains literal values.
            return parseLegacyPutPair(content) to true
        }

        private fun parseLegacyPutPair(content: String): Map<String, String> {
            val commaIndex = findTopLevelComma(content)
            if (commaIndex <= 0) return emptyMap()
            val key = content.substring(0, commaIndex).trim().stripLegacyPutQuotes()
            if (key.isBlank()) return emptyMap()
            val value = content.substring(commaIndex + 1).trim().stripLegacyPutQuotes()
            return mapOf(key to value)
        }

        private fun findTopLevelComma(text: String): Int {
            var quote: Char? = null
            var escaped = false
            var depth = 0
            text.forEachIndexed { index, char ->
                if (escaped) {
                    escaped = false
                    return@forEachIndexed
                }
                if (quote != null) {
                    if (char == '\\') {
                        escaped = true
                    } else if (char == quote) {
                        quote = null
                    }
                    return@forEachIndexed
                }
                when (char) {
                    '\'', '"' -> quote = char
                    '{', '[', '(' -> depth++
                    '}', ']', ')' -> if (depth > 0) depth--
                    ',' -> if (depth == 0) return index
                }
            }
            return -1
        }

        private fun String.stripLegacyPutQuotes(): String {
            if (length < 2) return this
            val first = first()
            val last = last()
            return if ((first == '"' && last == '"') || (first == '\'' && last == '\'')) {
                substring(1, length - 1)
            } else {
                this
            }
        }

        private fun extractJsonMap(obj: JsonObject): Map<String, String> {
            return linkedMapOf<String, String>().apply {
                obj.forEach { (key, value) ->
                    put(
                        key,
                        when (value) {
                            is JsonPrimitive -> value.content
                            else -> value.toString()
                        }
                    )
                }
            }
        }
    }
}
