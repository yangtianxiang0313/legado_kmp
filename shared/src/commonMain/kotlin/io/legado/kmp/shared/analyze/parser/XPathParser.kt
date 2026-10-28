package io.legado.kmp.shared.analyze.parser

import io.legado.kmp.shared.analyze.AnalyzeResult
import io.legado.kmp.shared.analyze.RuleAnalyzer

/**
 * XPath parser facade.
 *
 * Common code keeps the original Legado rule-combination semantics here
 * (`&&`, `||`, `%%`). The actual XPath evaluation is delegated to a
 * platform backend because the original Android project relies on
 * Jsoup + JsoupXpath, and there is no equivalent KMP XPath library
 * available for commonMain.
 */
class XPathParser(
    private val backend: XPathBackend = createXPathBackend()
) {

    fun evaluate(xPath: String, content: Any): AnalyzeResult {
        val values = extractAll(xPath, content)
        return when {
            values.isEmpty() -> AnalyzeResult.StringVal("")
            values.size == 1 -> AnalyzeResult.StringVal(values.first())
            else -> AnalyzeResult.StringList(values)
        }
    }

    fun extractAll(xPath: String, content: Any): List<String> {
        if (xPath.isBlank()) {
            return emptyList()
        }

        val ruleAnalyzer = RuleAnalyzer(xPath)
        val rules = ruleAnalyzer.splitRule("&&", "||", "%%")
        if (rules.size == 1) {
            return backend.getStringList(content, xPath)
        }

        val groupedResults = mutableListOf<List<String>>()
        for (rule in rules) {
            val values = extractAll(rule, content)
            if (values.isNotEmpty()) {
                groupedResults += values
                if (ruleAnalyzer.elementsType == "||") {
                    break
                }
            }
        }

        if (groupedResults.isEmpty()) {
            return emptyList()
        }

        return if (ruleAnalyzer.elementsType == "%%") {
            interleave(groupedResults)
        } else {
            groupedResults.flatten()
        }
    }

    fun getElements(xPath: String, content: Any): List<Any> {
        if (xPath.isBlank()) {
            return emptyList()
        }

        val ruleAnalyzer = RuleAnalyzer(xPath)
        val rules = ruleAnalyzer.splitRule("&&", "||", "%%")
        if (rules.size == 1) {
            return backend.getElements(content, xPath)
        }

        val groupedResults = mutableListOf<List<Any>>()
        for (rule in rules) {
            val values = getElements(rule, content)
            if (values.isNotEmpty()) {
                groupedResults += values
                if (ruleAnalyzer.elementsType == "||") {
                    break
                }
            }
        }

        if (groupedResults.isEmpty()) {
            return emptyList()
        }

        return if (ruleAnalyzer.elementsType == "%%") {
            interleave(groupedResults)
        } else {
            groupedResults.flatten()
        }
    }

    fun getString(xPath: String, content: Any): String? {
        val ruleAnalyzer = RuleAnalyzer(xPath)
        val rules = ruleAnalyzer.splitRule("&&", "||")
        if (rules.size == 1) {
            return backend.getStringList(content, xPath).takeIf { it.isNotEmpty() }?.joinToString("\n")
        }

        val values = buildList {
            for (rule in rules) {
                val value = getString(rule, content)
                if (!value.isNullOrEmpty()) {
                    add(value)
                    if (ruleAnalyzer.elementsType == "||") {
                        break
                    }
                }
            }
        }
        return values.joinToString("\n").ifEmpty { null }
    }

    fun matches(xPath: String, content: Any): Boolean {
        return getElements(xPath, content).isNotEmpty()
    }

    fun count(xPath: String, content: Any): Int {
        return getElements(xPath, content).size
    }

    fun isValid(xPath: String, content: Any): Boolean {
        return runCatching { matches(xPath, content) }.getOrDefault(false)
    }

    private fun <T> interleave(groups: List<List<T>>): List<T> {
        if (groups.isEmpty()) return emptyList()
        val result = mutableListOf<T>()
        val baseSize = groups.first().size
        for (index in 0 until baseSize) {
            for (group in groups) {
                if (index < group.size) {
                    result += group[index]
                }
            }
        }
        return result
    }
}
