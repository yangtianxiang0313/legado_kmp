package io.legado.kmp.shared.facade

import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

/** RuleComplete.kt and every active getSource() call at Android 5f5d314. */
internal object BookSourceRuleCompletion {
    private val notComplete = Regex("""^:|^##|\{\{|@js:|<js>|@Json:|\$\.""")
    private val separator = Regex("""&&|%%|\|\|""")
    private val getters = listOf("attr", "text", "ownText", "textNodes", "href", "content", "html", "alt", "all", "value", "src")
    private val imageText = Regex("""img((\[@?.+\]|\.[-A-Za-z_0-9]+)?)[@/]+text(\(\))?(&&|%%|\|\||$)""")
    private val xpath = Regex("^//|^@Xpath:")
    private val tail = Regex("""##|,\{""")
    private val textFields = listOf("name", "author", "kind", "intro", "wordCount", "lastChapter")

    fun payload(payload: String, enabled: Boolean): String {
        if (!enabled) return payload
        val root = importJson.parseToJsonElement(payload) as? JsonObject
            ?: throw IllegalArgumentException("Expected one book source")
        val result = root.toMutableMap()
        fun complete(key: String, pre: String?, text: List<String>, links: List<String>, images: List<String>) {
            val original = root[key] ?: return
            val objectValue = original as? JsonObject ?: (original as? JsonPrimitive)?.contentOrNull?.let {
                runCatching { importJson.parseToJsonElement(it) as? JsonObject }.getOrNull()
            } ?: return
            val updated = objectValue.toMutableMap()
            val preRule = (pre?.let { objectValue[it] } as? JsonPrimitive)?.contentOrNull?.takeUnless(String::isBlank)
            fun fields(names: List<String>, type: Int) {
                for (name in names) {
                    val value = objectValue[name] as? JsonPrimitive ?: continue
                    if (!value.isString) continue
                    val rule = value.content.takeUnless(String::isBlank)
                    updated[name] = autoComplete(rule, preRule, type)?.let(::JsonPrimitive) ?: JsonNull
                }
            }
            fields(text, 1)
            fields(links, 2)
            fields(images, 3)
            val completed = JsonObject(updated)
            if (completed != objectValue) {
                result[key] = if (original is JsonObject) completed else JsonPrimitive(completed.toString())
            }
        }
        complete("ruleSearch", "bookList", textFields, listOf("bookUrl"), listOf("coverUrl"))
        complete("ruleExplore", "bookList", textFields, listOf("bookUrl"), listOf("coverUrl"))
        complete("ruleBookInfo", "init", textFields + "downloadUrls", listOf("tocUrl"), listOf("coverUrl"))
        complete("ruleToc", "chapterList", listOf("chapterName"), listOf("chapterUrl", "nextTocUrl"), emptyList())
        complete("ruleContent", null, listOf("content", "title"), listOf("nextContentUrl"), emptyList())
        return JsonObject(result).toString()
    }

    fun autoComplete(rules: String?, preRule: String? = null, type: Int = 1): String? {
        if (rules.isNullOrEmpty() || notComplete.containsMatchIn(rules) ||
            preRule?.let(notComplete::containsMatchIn) == true || type !in 1..3
        ) return rules
        val split = tail.find(rules)
        val cleaned = rules.substring(0, split?.range?.first ?: rules.length)
        val suffix = split?.let { rules.substring(it.range.first) }.orEmpty()
        val isXpath = xpath.containsMatchIn(cleaned)
        val addition = if (isXpath) {
            when (type) { 2 -> "//@href"; 3 -> "//@src"; else -> "//text()" }
        } else {
            when (type) { 2 -> "@href"; 3 -> "@src"; else -> "@text" }
        }
        // JVM $ treats a final CRLF as one terminator; Native regex may match between its two bytes.
        val boundaries = separator.findAll(cleaned).map { it.range.first to it.value }.toMutableList()
        val terminator = when {
            cleaned.endsWith("\r\n") -> cleaned.length - 2
            cleaned.lastOrNull() in listOf('\n', '\r', '\u0085', '\u2028', '\u2029') -> cleaned.length - 1
            else -> null
        }
        if (terminator != null) boundaries.add(terminator to "")
        boundaries.add(cleaned.length to "")
        val completed = buildString {
            var start = 0
            for ((position, sequence) in boundaries.sortedBy { it.first }) {
                append(cleaned.substring(start, position))
                if (!hasGetterAt(cleaned, position)) append(addition)
                append(sequence)
                start = position + sequence.length
            }
        }
        if (type != 1) return completed + suffix
        return buildString {
            var search = 0
            var start = 0
            while (search < completed.length) {
                val match = imageText.find(completed, search) ?: break
                val position = match.range.first
                val before = completed.substring(0, position)
                if (before.isNotEmpty() && !before.endsWith("tag.") && before.last() !in "+/@>~| &") {
                    // A failed lookbehind must not consume a possible nested image match.
                    search = position + 1
                    continue
                }
                append(completed.substring(start, position))
                append("img" + match.groupValues[1] + (if (isXpath) "/@alt" else "@alt") + match.groupValues[4])
                start = match.range.last + 1
                search = start
            }
            append(completed.substring(start))
        } + suffix
    }

    private fun hasGetterAt(rule: String, position: Int): Boolean {
        val end = if (position >= 2 && rule.regionMatches(position - 2, "()", 0, 2)) position - 2 else position
        return getters.any { getter ->
            val start = end - getter.length
            start >= 0 && rule.regionMatches(start, getter, 0, getter.length) &&
                (start == 0 || rule[start - 1] in "@/" ||
                    (start >= 2 && rule[start - 1] in "|%&" && rule[start - 2] in "|%&"))
        }
    }
}
