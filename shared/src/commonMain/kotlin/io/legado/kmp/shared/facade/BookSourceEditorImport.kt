package io.legado.kmp.shared.facade

import io.legado.kmp.shared.model.BookSource
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

data class SourceEditorImportCandidate(val source: BookSource, val payload: String)
data class SourceEditorImportPreview(val candidates: List<SourceEditorImportCandidate>, val invalidCount: Int)

/** Keep editor JSON separate from the typed model, whose serializer drops unknown keys. */
internal fun sourceEditorObjects(payload: String): List<JsonObject> {
    val root = importJson.parseToJsonElement(payload.trim())
    val entries = if (root is JsonArray) root.toList() else listOf(root)
    return entries.map { entry ->
        val source = entry as? JsonObject ?: throw IllegalArgumentException("Expected book source object")
        if ("ruleSearchUrl" in source || "ruleFindUrl" in source) convertLegacyEditorSource(source) else source
    }
}

internal fun sourceEditorTypedPayload(source: JsonObject): String {
    return JsonObject(source.mapValues { (key, value) ->
        if ((key == "header" || key == "loginUi") && (value is JsonObject || value is JsonArray)) {
            JsonPrimitive(value.toString())
        } else value
    }).toString()
}

/** ImportOldData.fromOldBookSource at 5f5d314, limited to the source editor import boundary. */
private fun convertLegacyEditorSource(old: JsonObject): JsonObject {
    val result = old.toMutableMap()
    fun string(key: String) = (old[key] as? JsonPrimitive)?.contentOrNull
    fun put(key: String, value: String?) { if (value != null) result[key] = JsonPrimitive(value) else result.remove(key) }
    put("bookUrlPattern", string("ruleBookUrlPattern"))
    result["customOrder"] = JsonPrimitive(string("serialNumber")?.toIntOrNull() ?: 0)
    result["bookSourceType"] = JsonPrimitive(if (string("bookSourceType") == "AUDIO") 1 else 0)
    result["enabled"] = JsonPrimitive(string("enable")?.toBooleanStrictOrNull() ?: true)
    string("httpUserAgent")?.takeIf(String::isNotEmpty)?.let {
        put("header", JsonObject(mapOf("User-Agent" to JsonPrimitive(it))).toString())
    }
    put("searchUrl", legacyUrl(string("ruleSearchUrl")))
    val explore = string("ruleFindUrl")?.takeUnless(String::isBlank)?.let { value ->
        if (value.startsWith("@js:") || value.startsWith("<js>")) value
        else value.split(Regex("(&&|\r?\n)+")).joinToString("\n") { legacyUrl(it)?.replace(Regex("\n\\s*"), "").orEmpty() }
    }
    put("exploreUrl", explore)
    if (explore.isNullOrBlank()) result["enabledExplore"] = JsonPrimitive(false)
    fun rules(key: String, names: Map<String, String>) {
        result[key] = JsonObject(names.mapNotNull { (new, previous) ->
            legacyRule(string(previous))?.let { new to JsonPrimitive(it) }
        }.toMap())
    }
    fun listRules(prefix: String) = mapOf(
        "bookList" to "${prefix}List", "name" to "${prefix}Name", "author" to "${prefix}Author",
        "intro" to "${prefix}Introduce", "kind" to "${prefix}Kind", "bookUrl" to "${prefix}NoteUrl",
        "coverUrl" to "${prefix}CoverUrl", "lastChapter" to "${prefix}LastChapter",
    )
    rules("ruleSearch", listRules("ruleSearch"))
    rules("ruleExplore", listRules("ruleFind"))
    rules("ruleBookInfo", mapOf(
        "init" to "ruleBookInfoInit", "name" to "ruleBookName", "author" to "ruleBookAuthor",
        "intro" to "ruleIntroduce", "kind" to "ruleBookKind", "coverUrl" to "ruleCoverUrl",
        "lastChapter" to "ruleBookLastChapter", "tocUrl" to "ruleChapterUrl",
    ))
    rules("ruleToc", mapOf(
        "chapterList" to "ruleChapterList", "chapterName" to "ruleChapterName",
        "chapterUrl" to "ruleContentUrl", "nextTocUrl" to "ruleChapterUrlNext",
    ))
    rules("ruleContent", mapOf("replaceRegex" to "ruleBookContentReplace", "nextContentUrl" to "ruleContentUrlNext"))
    val content = legacyRule(string("ruleBookContent")).orEmpty().let {
        if (it.startsWith("$") && !it.startsWith("$.")) it.substring(1) else it
    }
    result["ruleContent"] = JsonObject((result["ruleContent"] as JsonObject) + ("content" to JsonPrimitive(content)))
    // Converted aliases must not trigger legacy conversion again after an editor changes a modern field.
    result.remove("ruleSearchUrl")
    result.remove("ruleFindUrl")
    return JsonObject(result)
}

private fun legacyRule(old: String?): String? {
    if (old.isNullOrBlank()) return null
    var rule: String = old
    val reverse = rule.startsWith("-")
    if (reverse) rule = rule.substring(1)
    val all = rule.startsWith("+")
    if (all) rule = rule.substring(1)
    if (!rule.startsWith("@CSS:", true) && !rule.startsWith("@XPath:", true) &&
        !rule.startsWith("//") && !rule.startsWith("##") && !rule.startsWith(":") &&
        !rule.contains("@js:", true) && !rule.contains("<js>", true)
    ) {
        if (rule.contains("#") && !rule.contains("##")) rule = old.replace("#", "##")
        if (rule.contains("|") && !rule.contains("||")) {
            val parts = rule.split("##")
            rule = (listOf(parts.first().replace("|", "||")) + parts.drop(1)).joinToString("##")
        }
        if (rule.contains("&") && !rule.contains("&&") && !rule.contains("http") && !rule.startsWith("/")) {
            rule = rule.replace("&", "&&")
        }
    }
    if (all) rule = "+$rule"
    if (reverse) rule = "-$rule"
    return rule
}

private fun legacyUrl(old: String?): String? {
    if (old.isNullOrBlank()) return null
    if (old.startsWith("<js>", true)) return old.replace("=searchKey", "={{key}}").replace("=searchPage", "={{page}}")
    var url: String = old
    val options = linkedMapOf<String, JsonElement>()
    Regex("@Header:\\{.+?\\}", RegexOption.IGNORE_CASE).find(url)?.value?.let {
        url = url.replace(it, "")
        options["headers"] = JsonPrimitive(it.substring(8))
    }
    val parts = url.split("|")
    url = parts.first()
    if (parts.size > 1) options["charset"] = JsonPrimitive(parts[1].substringAfter("="))
    val scripts = Regex("\\{\\{.+?\\}\\}", RegexOption.IGNORE_CASE).findAll(url).map { it.value }.toList()
    scripts.forEachIndexed { index, script -> url = url.replace(script, "$$index") }
    url = url.replace("{", "<").replace("}", ">").replace("searchKey", "{{key}}")
        .replace(Regex("<searchPage([-+]1)>"), "{{page$1}}")
        .replace(Regex("searchPage([-+]1)"), "{{page$1}}")
        .replace("searchPage", "{{page}}")
    scripts.forEachIndexed { index, script ->
        url = url.replace("$$index", script.replace("searchKey", "key").replace("searchPage", "page"))
    }
    val post = url.split("@")
    url = post.first()
    if (post.size > 1) {
        options["method"] = JsonPrimitive("POST")
        options["body"] = JsonPrimitive(post[1])
    }
    return if (options.isEmpty()) url else "$url,${JsonObject(options)}"
}
