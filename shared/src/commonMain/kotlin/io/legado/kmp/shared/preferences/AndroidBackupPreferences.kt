package io.legado.kmp.shared.preferences

import com.fleeksoft.ksoup.Ksoup
import com.fleeksoft.ksoup.parser.Parser
import kotlinx.serialization.json.*

/** Android's backup files retain their original payload as well as usable iOS preferences. */
object AndroidBackupPreferences {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true; coerceInputValues = true }

    fun parse(entries: Map<String, String>): PreferencesBackupData? {
        val config = entries["config.xml"]?.let(::parseConfig)?.toMutableMap() ?: mutableMapOf()
        val readerRaw = (entries["readConfig.json"] ?: entries["readBookConfig.json"])
            ?.let(json::parseToJsonElement)
        val shared = entries["shareReadConfig.json"]?.let(json::parseToJsonElement) as? JsonObject
        val themesRaw = entries["themeConfig.json"]?.let(json::parseToJsonElement)
        // Android stores each preset independently of the active shared layout.
        val readers = (readerRaw as? JsonArray)?.mapIndexed { index, item ->
            toReaderPreset(item.jsonObject, index)
        } ?: emptyList()
        val themes = ((themesRaw as? JsonArray)?.map { json.decodeFromJsonElement<ThemePreset>(it) } ?: emptyList()).toMutableList()
        fun color(key: String, night: Boolean, fallback: String): String {
            val primitive = config[key + (if (night) "Night" else "")] as? JsonPrimitive ?: return fallback
            return primitive.longOrNull?.let { "#" + it.toUInt().toString(16).padStart(8, '0') } ?: primitive.content
        }
        if (config.keys.any { it.startsWith("colorPrimary") || it.startsWith("colorBackground") }) {
            val dayName = "Android 当前主题"
            val nightName = "Android 当前主题（夜间）"
            themes.removeAll { it.themeName == dayName || it.themeName == nightName }
            listOf(false, true).forEach { night ->
                themes.add(ThemePreset(
                    themeName = if (night) nightName else dayName,
                    isNightTheme = night,
                    primaryColor = color("colorPrimary", night, if (night) "#546E7A" else "#795548"),
                    accentColor = color("colorAccent", night, if (night) "#D84315" else "#E53935"),
                    backgroundColor = color("colorBackground", night, if (night) "#212121" else "#F5F5F5"),
                    bottomBackground = color("colorBottomBackground", night, if (night) "#303030" else "#EEEEEE"),
                    pairedThemeName = if (night) dayName else nightName,
                ))
            }
            config["theme_preset_name"] = JsonPrimitive(
                if ((config["themeMode"] as? JsonPrimitive)?.content == "2") nightName else dayName)
        }
        val selectedIndex = (config["readStyleSelect"] as? JsonPrimitive)?.intOrNull ?: 0
        (readerRaw as? JsonArray)?.getOrNull(selectedIndex)?.let { selected ->
            val animationKey = if ((config["themeMode"] as? JsonPrimitive)?.content == "3") "pageAnimEInk" else "pageAnim"
            selected.jsonObject[animationKey]?.let { config["pageAnim"] = it }
        }
        readerRaw?.let { config["android.readConfig"] = it }
        shared?.let { config["android.shareReadConfig"] = it }
        themesRaw?.let { config["android.themeConfig"] = it }
        listOf("coverRule.json", "coverConfig.json", "directLinkUploadRule.json").forEach { file ->
            entries[file]?.let { config["android.$file"] = json.parseToJsonElement(it) }
        }
        if (config.isEmpty() && readers.isEmpty() && themes.isEmpty()) return null
        return PreferencesBackupData(JsonObject(config), readers, themes)
    }

    // Shared-config selection and the index-5/Config() fallback belong to the caller.
    internal fun sharedReaderStyle(source: JsonObject): ReaderStylePreferences =
        toReaderPreset(source, 0).toReaderStylePreferences()

    private fun parseConfig(xml: String): JsonObject {
        val document = Ksoup.parse(html = xml, parser = Parser.xmlParser())
        val root = document.selectFirst("map") ?: error("Android config.xml 缺少 map 元素")
        return JsonObject(root.children().associate { item ->
            val key = item.attr("name")
            require(key.isNotBlank()) { "Android config.xml 包含无名称的偏好" }
            val value = when (item.tagName()) {
                "string" -> JsonPrimitive(item.wholeText())
                "boolean" -> JsonPrimitive(item.attr("value").toBooleanStrict())
                "int", "long", "float" -> json.parseToJsonElement(item.attr("value"))
                "set" -> JsonArray(item.children().map { JsonPrimitive(it.wholeText()) })
                else -> error("Android config.xml 不支持的偏好类型：${item.tagName()}")
            }
            key to value
        })
    }

    private fun toReaderPreset(source: JsonObject, index: Int): ReaderPreset {
        val normalized = source.toMutableMap()
        // ReadBookConfig.Config at legado 5f5d314 defaults to 20, not the generic fallback of 24.
        if (normalized["textSize"] == null || normalized["textSize"] == JsonNull) {
            normalized["textSize"] = JsonPrimitive(20)
        }
        val name = (source["name"] as? JsonPrimitive)?.content?.takeIf { it.isNotBlank() }
        normalized["name"] = JsonPrimitive(name ?: "Android ${index + 1}")
        (source["paragraphIndent"] as? JsonPrimitive)?.let { indent ->
            normalized["paragraphIndent"] = JsonPrimitive(indent.intOrNull ?: indent.content.length)
        }
        // Android assets/content URIs and filesystem paths are not portable to the iOS sandbox.
        // Keep their original values in android.readConfig, but use usable color/system-font fallbacks.
        listOf("" to "#EEEEEE", "Night" to "#000000", "EInk" to "#FFFFFF").forEach { (suffix, fallback) ->
            val type = (source["bgType$suffix"] as? JsonPrimitive)?.intOrNull ?: 0
            val background = (source["bgStr$suffix"] as? JsonPrimitive)?.content
            if (type != 0 || (background != null && !background.startsWith("#"))) {
                normalized["bgType$suffix"] = JsonPrimitive(0)
                normalized["bgStr$suffix"] = JsonPrimitive(fallback)
            }
        }
        normalized.remove("backgroundImagePath")
        (source["textFont"] as? JsonPrimitive)?.content?.let { font ->
            if (font.contains('/') || font.contains('\\') || font.endsWith(".ttf", true) || font.endsWith(".otf", true)) {
                normalized["textFont"] = JsonNull
            }
        }
        // PageView: tip 0 follows text; divider -1 is default and 0 follows text. Others are ARGB.
        (source["tipColor"] as? JsonPrimitive)?.intOrNull?.let {
            normalized["tipColorHex"] = if (it == 0) JsonNull else JsonPrimitive(androidColor(it))
        }
        (source["tipDividerColor"] as? JsonPrimitive)?.intOrNull?.let {
            normalized["tipDividerColorHex"] = when (it) {
                -1 -> JsonNull
                0 -> JsonPrimitive("@text")
                else -> JsonPrimitive(androidColor(it))
            }
        }
        return json.decodeFromJsonElement(JsonObject(normalized))
    }

    private fun androidColor(value: Int): String = "#" + value.toUInt().toString(16).padStart(8, '0')

}
