package io.legado.kmp.shared.analyze.parser

/**
 * Detects JsoupXPath-specific extensions in XPath expressions.
 *
 * Note: As of the iOS XPath backend shimming implementation, the following
 * extensions are now supported on iOS via pre-processing:
 * - allText(), tidyText(), html(), outerHtml() (stripped and post-processed)
 * - node()[m:n] range syntax (converted to position() predicates)
 *
 * This detector is kept for diagnostics and source compatibility reporting.
 */
object XPathCompatibility {

    data class Issue(
        val rule: String,
        val pattern: String,
        val description: String
    )

    /**
     * Known JsoupXPath extension patterns that only work with the
     * Java/Android JsoupXPath library.
     */
    private val extensionPatterns = listOf(
        ExtensionPattern(
            regex = Regex("""/allText\(\)"""),
            name = "allText()",
            description = "JsoupXPath extension — returns all descendant text. Use text() or string() instead."
        ),
        ExtensionPattern(
            regex = Regex("""/tidyText\(\)"""),
            name = "tidyText()",
            description = "JsoupXPath extension — returns cleaned text. Use normalize-space() instead."
        ),
        ExtensionPattern(
            regex = Regex("""/html\(\)"""),
            name = "html()",
            description = "JsoupXPath extension — returns inner HTML. No XPath 1.0 equivalent."
        ),
        ExtensionPattern(
            regex = Regex("""/outerHtml\(\)"""),
            name = "outerHtml()",
            description = "JsoupXPath extension — returns outer HTML. No XPath 1.0 equivalent."
        ),
        ExtensionPattern(
            regex = Regex("""/node\(\)\s*\[\s*\d+\s*:\s*\d+\s*]"""),
            name = "node()[m:n] range",
            description = "JsoupXPath range syntax — not standard XPath. Use position() predicates."
        ),
        ExtensionPattern(
            regex = Regex("""\bcontains\s*\(\s*@class\s*,"""),
            name = "contains(@class, ...)",
            description = "Works in standard XPath but may behave differently with multi-class attributes."
        )
    )

    /**
     * Analyze a set of XPath rules and return any compatibility issues found.
     *
     * @param rules map of rule name to XPath expression (e.g. "ruleSearch.bookList" → "//div[@class='item']")
     * @return list of issues found, empty if all rules are compatible
     */
    fun analyze(rules: Map<String, String>): List<Issue> {
        val issues = mutableListOf<Issue>()
        for ((name, xpath) in rules) {
            if (xpath.isBlank()) continue
            for (pattern in extensionPatterns) {
                if (pattern.regex.containsMatchIn(xpath)) {
                    issues += Issue(
                        rule = name,
                        pattern = pattern.name,
                        description = pattern.description
                    )
                }
            }
        }
        return issues
    }

    /**
     * Quick check: does any rule contain JsoupXPath extensions?
     */
    fun hasIncompatibleRules(rules: Map<String, String>): Boolean {
        return rules.values.any { xpath ->
            xpath.isNotBlank() && extensionPatterns.any { it.regex.containsMatchIn(xpath) }
        }
    }

    private data class ExtensionPattern(
        val regex: Regex,
        val name: String,
        val description: String
    )
}
