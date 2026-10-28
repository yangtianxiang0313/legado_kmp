package io.legado.kmp.shared.analyze.parser

import com.fleeksoft.ksoup.Ksoup
import com.fleeksoft.ksoup.nodes.Document
import com.fleeksoft.ksoup.nodes.Element
import com.fleeksoft.ksoup.parser.Parser
import com.fleeksoft.ksoup.select.Elements
import io.legado.kmp.shared.analyze.AnalyzeResult
import io.legado.kmp.shared.analyze.RuleAnalyzer

/**
 * Selects matching elements, including [root], with the existing fallback for
 * empty results and invalid selectors.
 */
private fun selectWithSelf(root: Element, cssQuery: String): Elements {
    val result = try {
        root.select(cssQuery)
    } catch (_: Exception) {
        // Invalid CSS selector (e.g. JSONPath-style rules like "$.data.*")
        // passed to CSS parser when content type detection is ambiguous.
        return Elements()
    }
    if (result.isEmpty()) {
        try {
            if (root.`is`(cssQuery)) {
                return Elements(listOf(root))
            }
        } catch (_: Exception) {
            // invalid selector — fall through
        }
    }
    return result
}

/**
 * Common CSS parser backed by ksoup.
 *
 * This is a direct KMP-oriented port of the original AnalyzeByJSoup flow:
 * - `&& / || / %%` element combination
 * - `@` rule chaining
 * - terminal extractors like `text / textNodes / ownText / html / all / attr`
 */
class CssRuleParser {

    fun evaluate(
        rule: String,
        content: Any,
        baseUrl: String? = null
    ): AnalyzeResult {
        val values = getStringList(rule, content, baseUrl)
        return when {
            values.isEmpty() -> AnalyzeResult.StringVal("")
            values.size == 1 -> AnalyzeResult.StringVal(values.first())
            else -> AnalyzeResult.StringList(values)
        }
    }

    fun extractAll(rule: String, content: Any, baseUrl: String? = null): List<String> {
        return getStringList(rule, content, baseUrl)
    }

    fun extractFirst(rule: String, content: Any, baseUrl: String? = null): String? {
        return getStringList(rule, content, baseUrl).firstOrNull()
    }

    fun extractAttrs(rule: String, content: Any, attr: String, baseUrl: String? = null): List<String> {
        val normalized = if (findTerminalCssExtractorDelimiter(rule) != -1) rule else "$rule@$attr"
        return getStringList(normalized, content, baseUrl)
    }

    fun extractFirstAttr(rule: String, content: Any, attr: String, baseUrl: String? = null): String? {
        return extractAttrs(rule, content, attr, baseUrl).firstOrNull()
    }

    fun matches(rule: String, content: Any, baseUrl: String? = null): Boolean {
        return getElements(rule, content, baseUrl).isNotEmpty()
    }

    fun count(rule: String, content: Any, baseUrl: String? = null): Int {
        return getElements(rule, content, baseUrl).size
    }

    fun getElements(rule: String, content: Any, baseUrl: String? = null): List<Any> {
        val root = parse(content, baseUrl)
        return getElements(root, rule).toList()
    }

    fun getString(rule: String, content: Any, baseUrl: String? = null): String? {
        val values = getStringList(rule, content, baseUrl)
        return when {
            values.isEmpty() -> null
            values.size == 1 -> values.first()
            else -> values.joinToString("\n")
        }
    }

    /**
     * Get only the first element's text (not concatenated).
     * Aligned with AnalyzeByJSoup.getString0 — used for URL extraction
     * where only the first match is desired.
     */
    fun getString0(rule: String, content: Any, baseUrl: String? = null): String {
        val values = getStringList(rule, content, baseUrl)
        return if (values.isEmpty()) "" else values[0]
    }

    private fun getStringList(ruleStr: String, content: Any, baseUrl: String?): List<String> {
        val root = parse(content, baseUrl)
        val results = arrayListOf<String>()
        if (ruleStr.isEmpty()) return results

        val sourceRule = SourceRule(ruleStr)
        if (sourceRule.elementsRule.isEmpty()) {
            val data = root.data()
            if (data.isNotEmpty()) {
                results += data
            }
            return results
        }

        val ruleAnalyzes = RuleAnalyzer(sourceRule.elementsRule)
        val ruleParts = ruleAnalyzes.splitRule("&&", "||", "%%")
        val groupedResults = mutableListOf<List<String>>()

        for (rulePart in ruleParts) {
            val value = if (sourceRule.isCss) {
                val lastIndex = findTerminalCssExtractorDelimiter(rulePart)
                if (lastIndex == -1) {
                    getResultLast(selectWithSelf(root, rulePart), "text")
                } else {
                    getResultLast(
                        selectWithSelf(root, rulePart.substring(0, lastIndex)),
                        rulePart.substring(lastIndex + 1)
                    )
                }
            } else {
                getResultList(root, rulePart)
            }

            if (value.isNotEmpty()) {
                groupedResults += value
                if (ruleAnalyzes.elementsType == "||") {
                    break
                }
            }
        }

        if (groupedResults.isEmpty()) {
            return emptyList()
        }

        return if (ruleAnalyzes.elementsType == "%%") {
            interleave(groupedResults)
        } else {
            groupedResults.flatten()
        }
    }

    private fun getElements(root: Element, rule: String): Elements {
        if (rule.isEmpty()) return Elements()

        val sourceRule = SourceRule(rule)
        val ruleAnalyzes = RuleAnalyzer(sourceRule.elementsRule)
        val ruleParts = ruleAnalyzes.splitRule("&&", "||", "%%")
        val groupedResults = mutableListOf<Elements>()

        if (sourceRule.isCss) {
            for (rulePart in ruleParts) {
                val extractorIndex = findTerminalCssExtractorDelimiter(rulePart)
                val selected = selectWithSelf(
                    root,
                    if (extractorIndex == -1) rulePart else rulePart.substring(0, extractorIndex)
                )
                if (selected.isNotEmpty()) {
                    groupedResults += selected
                    if (ruleAnalyzes.elementsType == "||") {
                        break
                    }
                }
            }
        } else {
            for (rulePart in ruleParts) {
                val selected = getElementsByChain(root, rulePart)
                if (selected.isNotEmpty()) {
                    groupedResults += selected
                    if (ruleAnalyzes.elementsType == "||") {
                        break
                    }
                }
            }
        }

        if (groupedResults.isEmpty()) {
            return Elements()
        }

        return if (ruleAnalyzes.elementsType == "%%") {
            Elements().apply {
                val baseSize = groupedResults.first().size
                for (index in 0 until baseSize) {
                    for (group in groupedResults) {
                        if (index < group.size) {
                            add(group[index])
                        }
                    }
                }
            }
        } else {
            Elements().apply { groupedResults.forEach(::addAll) }
        }
    }

    private fun findTerminalCssExtractorDelimiter(rule: String): Int {
        var quote: Char? = null
        var escaped = false
        var bracketDepth = 0
        var parenDepth = 0
        var delimiter = -1
        rule.forEachIndexed { index, char ->
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
                '[' -> bracketDepth++
                ']' -> if (bracketDepth > 0) bracketDepth--
                '(' -> parenDepth++
                ')' -> if (parenDepth > 0) parenDepth--
                '@' -> if (bracketDepth == 0 && parenDepth == 0) {
                    delimiter = index
                }
            }
        }
        return delimiter.takeIf { it > 0 && it < rule.lastIndex && rule.substring(it + 1).isNotBlank() } ?: -1
    }

    private fun getResultList(root: Element, ruleStr: String): ArrayList<String> {
        if (ruleStr.isEmpty()) return arrayListOf()

        var elements = Elements().apply { add(root) }
        val rule = RuleAnalyzer(ruleStr)
        rule.trim()
        val rules = rule.splitRule("@")

        val last = rules.size - 1
        for (index in 0 until last) {
            val next = Elements()
            for (element in elements) {
                next.addAll(getElementsSingle(element, rules[index]))
            }
            elements = next
        }
        return if (elements.isEmpty()) arrayListOf() else getResultLast(elements, rules[last])
    }

    private fun getElementsByChain(root: Element, ruleStr: String): Elements {
        val rule = RuleAnalyzer(ruleStr)
        rule.trim()
        val rules = rule.splitRule("@")
        if (rules.size == 1) {
            return getElementsSingle(root, ruleStr)
        }

        var elements = Elements().apply { add(root) }
        for (rulePart in rules) {
            val next = Elements()
            for (element in elements) {
                next.addAll(getElementsSingle(element, rulePart))
            }
            elements = next
        }
        return elements
    }

    private fun getResultLast(elements: Elements, lastRule: String): ArrayList<String> {
        val result = arrayListOf<String>()
        when (lastRule) {
            "text" -> elements.forEach { element ->
                val value = element.text()
                if (value.isNotEmpty()) {
                    result += value
                }
            }
            "textNodes" -> elements.forEach { element ->
                val values = element.textNodes()
                    .map { it.text().trim() }
                    .filter { it.isNotEmpty() }
                if (values.isNotEmpty()) {
                    result += values.joinToString("\n")
                }
            }
            "ownText" -> elements.forEach { element ->
                val value = element.ownText()
                if (value.isNotEmpty()) {
                    result += value
                }
            }
            "html" -> {
                val cloned = Elements()
                elements.forEach { cloned.add(it.clone()) }
                cloned.select("script").remove()
                cloned.select("style").remove()
                val html = cloned.outerHtml()
                if (html.isNotEmpty()) {
                    result += html
                }
            }
            "all" -> {
                val html = elements.outerHtml()
                if (html.isNotEmpty()) {
                    result += html
                }
            }
            else -> elements.forEach { element ->
                val value = element.attr(lastRule)
                if (value.isNotBlank() && value !in result) {
                    result += value
                }
            }
        }
        return result
    }

    private fun getElementsSingle(root: Element, rule: String): Elements {
        val parsed = ElementsSingle.parse(rule)
        var elements = if (parsed.beforeRule.isEmpty()) {
            root.children()
        } else {
            val rules = parsed.beforeRule.split(".")
            when (rules.firstOrNull()) {
                "children" -> root.children()
                "class" -> {
                    if (rules.size == 2) {
                        val classValue = rules.getOrElse(1) { "" }
                        if (' ' in classValue) {
                            val classNames = classValue.split(' ').filter { it.isNotBlank() }
                            root.select(classNames.joinToString("") { ".$it" })
                        } else {
                            root.getElementsByClass(classValue)
                        }
                    } else {
                        root.select("." + rules.drop(1).joinToString("."))
                    }
                }
                "tag" -> {
                    if (rules.size == 2) {
                        root.getElementsByTag(rules.getOrElse(1) { "" })
                    } else {
                        root.select(rules.drop(1).joinToString("."))
                    }
                }
                "id" -> {
                    if (rules.size == 2) {
                        selectWithSelf(root, "#${rules.getOrElse(1) { "" }}")
                    } else {
                        root.select("#" + rules.drop(1).joinToString("."))
                    }
                }
                "text" -> root.getElementsContainingOwnText(rules.getOrElse(1) { "" })
                else -> selectWithSelf(root, parsed.beforeRule)
            }
        }

        if (parsed.indexes.isEmpty() && parsed.indexDefault.isEmpty()) {
            return elements
        }

        val indexes = parsed.resolveIndexes(elements.size)
        elements = when (parsed.split) {
            '!' -> Elements().apply {
                elements.forEachIndexed { index, element ->
                    if (index !in indexes) add(element)
                }
            }
            '.' -> Elements().apply {
                indexes.forEach { index ->
                    if (index in 0 until elements.size) add(elements[index])
                }
            }
            else -> elements
        }

        return elements
    }

    private fun parse(content: Any, baseUrl: String?): Element {
        return when (content) {
            is Document -> content
            is Element -> content
            else -> {
                val html = content.toString()
                val isXml = html.trimStart().startsWith("<?xml", ignoreCase = true)
                val resolvedBaseUrl = baseUrl
                when {
                    isXml && baseUrl.isNullOrEmpty() -> Ksoup.parse(html = html, parser = Parser.xmlParser())
                    isXml -> Ksoup.parse(html = html, baseUri = resolvedBaseUrl ?: "", parser = Parser.xmlParser())
                    baseUrl.isNullOrEmpty() -> Ksoup.parse(html = html)
                    else -> Ksoup.parse(html = html, baseUri = resolvedBaseUrl ?: "")
                }
            }
        }
    }

    private fun interleave(groups: List<List<String>>): List<String> {
        val result = mutableListOf<String>()
        val baseSize = groups.firstOrNull()?.size ?: return emptyList()
        for (index in 0 until baseSize) {
            for (group in groups) {
                if (index < group.size) {
                    result += group[index]
                }
            }
        }
        return result
    }

    private fun decodeXmlText(value: String): String {
        return value
            .replace(Regex("<!\\[CDATA\\["), "")
            .replace(Regex("]]>"), "")
            .replace(Regex("&#(\\d+);")) { match ->
                match.groupValues[1].toIntOrNull()?.toChar()?.toString() ?: match.value
            }
            .replace("&#39;", "'")
            .replace("&apos;", "'")
            .replace("&quot;", "\"")
            .replace("&lt;", "<")
            .replace("&gt;", ">")
            .replace("&amp;", "&")
            .trim()
    }

    private data class SourceRule(
        val rawRule: String
    ) {
        val isCss = rawRule.startsWith("@CSS:", ignoreCase = true)
        val elementsRule = if (isCss) rawRule.substring(5).trim() else rawRule
    }

    private data class ElementsSingle(
        var split: Char = '.',
        var beforeRule: String = "",
        val indexDefault: MutableList<Int> = mutableListOf(),
        val indexes: MutableList<Any> = mutableListOf()
    ) {
        fun resolveIndexes(length: Int): Set<Int> {
            if (length <= 0) return emptySet()

            val result = linkedSetOf<Int>()
            if (indexes.isEmpty()) {
                for (index in indexDefault.asReversed()) {
                    normalizeIndex(index, length)?.let(result::add)
                }
                return result
            }

            for (entry in indexes.asReversed()) {
                when (entry) {
                    is Int -> normalizeIndex(entry, length)?.let(result::add)
                    is Triple<*, *, *> -> {
                        var start = (entry.first as Int?) ?: 0
                        var end = (entry.second as Int?) ?: (length - 1)
                        val rawStep = entry.third as Int

                        if (start < 0) start += length
                        if (end < 0) end += length
                        if ((start < 0 && end < 0) || (start >= length && end >= length)) continue
                        start = start.coerceIn(0, length - 1)
                        end = end.coerceIn(0, length - 1)

                        if (start == end || rawStep >= length) {
                            result += start
                            continue
                        }

                        val step = if (rawStep > 0) rawStep else if (rawStep > -length) rawStep + length else 1
                        if (end > start) {
                            for (index in start..end step step) result += index
                        } else {
                            var index = start
                            while (index >= end) {
                                result += index
                                index -= step
                            }
                        }
                    }
                }
            }
            return result
        }

        private fun normalizeIndex(value: Int, length: Int): Int? {
            return when {
                value in 0 until length -> value
                value < 0 && value >= -length -> value + length
                else -> null
            }
        }

        companion object {
            private fun parseIndexNumber(digits: String, negative: Boolean): Int {
                val signed = if (negative) "-$digits" else digits
                // Overflow stays out of bounds instead of becoming an omitted range endpoint.
                return signed.toIntOrNull() ?: if (negative) Int.MIN_VALUE else Int.MAX_VALUE
            }

            fun parse(rule: String): ElementsSingle {
                val parsed = ElementsSingle()
                val trimmed = rule.trim()
                var cursor = trimmed.length - 1
                var buffer = ""
                var negative = false
                val currentRange = mutableListOf<Int?>()

                if (trimmed.endsWith("]")) {
                    cursor--
                    while (cursor >= 0) {
                        var ch = trimmed[cursor]
                        if (ch == ' ') {
                            cursor--
                            continue
                        }
                        if (ch in '0'..'9') {
                            buffer = ch + buffer
                        } else if (ch == '-') {
                            negative = true
                        } else {
                            val current = if (buffer.isEmpty()) null else parseIndexNumber(buffer, negative)
                            when (ch) {
                                ':' -> currentRange += current
                                '[', ',', '!' -> {
                                    if (currentRange.isEmpty()) {
                                        if (current == null && ch != '[') break
                                        current?.let(parsed.indexes::add)
                                    } else {
                                        parsed.indexes += Triple(
                                            current,
                                            currentRange.last(),
                                            if (currentRange.size == 2) currentRange.first() ?: 1 else 1
                                        )
                                        currentRange.clear()
                                    }
                                    if (ch == '!') {
                                        parsed.split = '!'
                                        cursor--
                                        while (cursor > 0 && trimmed[cursor] == ' ') cursor--
                                        if (trimmed[cursor] == '[') {
                                            parsed.beforeRule = trimmed.substring(0, cursor)
                                            return parsed
                                        }
                                    }
                                    if (ch == '[') {
                                        parsed.beforeRule = trimmed.substring(0, cursor)
                                        return parsed
                                    }
                                    if (ch != ',') break
                                }
                                else -> break
                            }
                            buffer = ""
                            negative = false
                        }
                        cursor--
                    }
                }

                cursor = trimmed.length - 1
                buffer = ""
                negative = false
                while (cursor >= 0) {
                    val ch = trimmed[cursor]
                    if (ch == ' ') {
                        cursor--
                        continue
                    }
                    if (ch in '0'..'9') {
                        buffer = ch + buffer
                    } else if (ch == '-') {
                        negative = true
                    } else {
                        if (ch == '!' || ch == '.' || ch == ':') {
                            if (buffer.isEmpty()) break
                            parsed.indexDefault += parseIndexNumber(buffer, negative)
                            if (ch != ':') {
                                parsed.split = ch
                                parsed.beforeRule = trimmed.substring(0, cursor)
                                return parsed
                            }
                            buffer = ""
                            negative = false
                        } else {
                            break
                        }
                    }
                    cursor--
                }

                parsed.beforeRule = trimmed
                return parsed
            }
        }
    }
}
