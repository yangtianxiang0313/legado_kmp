package io.legado.kmp.shared.facade

import io.legado.kmp.shared.preferences.PreferencesBackupData
import io.legado.kmp.shared.preferences.ReaderPreset
import io.legado.kmp.shared.preferences.ThemePreset
import io.legado.kmp.shared.preferences.ThemePresetCodec
import kotlin.math.roundToInt
import kotlinx.serialization.json.*

/** Produces Android's actual config files; iOS-only fields belong in separate metadata. */
internal class AndroidBackupPreferencesExport(private val warnings: MutableList<String>) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    fun files(data: PreferencesBackupData?, password: String): Map<String, String> {
        if (data == null) return mapOf("config.xml" to xml(emptyMap()))
        require(data.readConfig.size <= 1024 && data.themeConfig.size <= 1024 && data.appConfig.size <= 4096) {
            "备份偏好或预设数量超过上限"
        }
        val original = data.appConfig
        val config = AndroidBackupExportPreferenceKeys.config(original, warnings)
        val readers = if (data.readConfig.isNotEmpty()) JsonArray(data.readConfig.map(::reader))
            else original["android.readConfig"] as? JsonArray
        val themes = if (data.themeConfig.isNotEmpty()) JsonArray(data.themeConfig.map(::theme))
            else original["android.themeConfig"] as? JsonArray
        val result = linkedMapOf<String, String>()
        readers?.let { rows ->
            require(rows.all { it is JsonObject }) { "阅读预设备份必须是对象数组" }
            if (rows.isNotEmpty()) {
                result["readConfig.json"] = rows.toString()
                val selected = ((config["readStyleSelect"] as? JsonPrimitive)?.intOrNull ?: 0)
                    .coerceIn(0, rows.lastIndex)
                config["readStyleSelect"] = JsonPrimitive(selected)
            }
        }
        val snapshot = original["reader_shared_layout_snapshot"]
        val sharedLayout = (snapshot as? JsonObject)?.let(::sharedPreset)
        if (snapshot != null && snapshot !is JsonNull && sharedLayout == null) {
            warnings += "共享阅读排版快照无效，Android 备份已回退到原生共享配置或默认排版。"
        }
        val shared = sharedLayout?.let(::reader)
            // ReadBookConfig.initShareConfig (5f5d314): saved object, index 5, then Config().
            ?: (original["android.shareReadConfig"] as? JsonObject)
            ?: (readers?.getOrNull(5) as? JsonObject)
            ?: reader(androidDefaultPreset())
        result["shareReadConfig.json"] = shared.toString()
        themes?.let { rows ->
            require(rows.all { it is JsonObject }) { "主题备份必须是对象数组" }
            if (rows.isNotEmpty()) result["themeConfig.json"] = rows.toString()
        }
        val selectedTheme = (original["theme_preset_name"] as? JsonPrimitive)?.content
        data.themeConfig.firstOrNull { it.themeName == selectedTheme }?.let { selected ->
            val suffix = if (selected.isNightTheme) "Night" else ""
            mapOf("colorPrimary" to selected.primaryColor, "colorAccent" to selected.accentColor,
                "colorBackground" to selected.backgroundColor, "colorBottomBackground" to selected.bottomBackground)
                .forEach { (key, color) -> config[key + suffix] = JsonPrimitive(ThemePresetCodec.colorInt(color)) }
        }
        // The only native backup password preference is PreferKey.webDavPassword = web_dav_password.
        (config["web_dav_password"] as? JsonPrimitive)?.let { value ->
            config["web_dav_password"] = JsonPrimitive(AndroidBackupCipher.encrypt(value.content, password))
        }
        val cover = original["android.coverRule.json"] ?: original["android.coverConfig.json"]
        if (cover != null && cover !is JsonNull) {
            val rule = cover as? JsonObject ?: error("封面规则备份必须为对象")
            requireStrings(rule, "searchUrl", "coverRule")
            result["coverRule.json"] = rule.toString()
        }
        val direct = original["android.directLinkUploadRule.json"]
        if (direct != null && direct !is JsonNull) {
            val rule = direct as? JsonObject ?: error("直链规则备份必须为对象")
            requireStrings(rule, "uploadUrl", "downloadUrlRule", "summary")
            result["directLinkUploadRule.json"] = rule.toString()
            warnings += "Android 原生直链上传规则为明文文件，可能包含上传凭据；请妥善保管备份。"
        }
        result["config.xml"] = xml(config)
        return result
    }

    private fun reader(preset: ReaderPreset): JsonObject {
        require(preset.paragraphIndent in 0..64) { "阅读预设段落缩进超过上限" }
        require(preset.titleSize.isFinite()) { "阅读预设标题大小无效" }
        val row = json.encodeToJsonElement(ReaderPreset.serializer(), preset).jsonObject.toMutableMap()
        row.remove("backgroundImagePath")
        row.remove("tipColorHex")
        row.remove("tipDividerColorHex")
        row["textSize"] = JsonPrimitive(preset.textSize ?: 24)
        row["lineSpacingExtra"] = JsonPrimitive(preset.lineSpacingExtra ?: 12)
        row["paddingLeft"] = JsonPrimitive(preset.paddingLeft ?: 16)
        row["paddingRight"] = JsonPrimitive(preset.paddingRight ?: 16)
        row["paragraphIndent"] = JsonPrimitive("\u3000".repeat(preset.paragraphIndent))
        row["titleSize"] = JsonPrimitive(preset.titleSize.toInt())
        row["textFont"] = JsonPrimitive(preset.textFont.orEmpty())
        row["tipColor"] = JsonPrimitive(tipColor(preset.tipColorHex, divider = false))
        row["tipDividerColor"] = JsonPrimitive(tipColor(preset.tipDividerColorHex, divider = true))
        if (preset.titleSize != preset.titleSize.toInt().toFloat()) {
            warnings += "Android 标题字号为整数，小数字号已取整；原值保留在 KMP metadata。"
        }
        if (!preset.textFont.isNullOrEmpty()) {
            warnings += "字体文件与 iOS 字体并未迁移；Android 仅保留字体名称或路径引用，需要在目标设备重新选择。"
        }
        listOf("" to "#EEEEEE", "Night" to "#000000", "EInk" to "#FFFFFF").forEach { (suffix, fallback) ->
            val type = row.getValue("bgType$suffix").jsonPrimitive.int
            val background = (row["bgStr$suffix"] as? JsonPrimitive)?.contentOrNull
            if (type == 0) {
                row["bgStr$suffix"] = JsonPrimitive(validColor(background, fallback))
            } else if (type != 1 || background.isNullOrBlank() || '/' in background || '\\' in background) {
                row["bgType$suffix"] = JsonPrimitive(0)
                row["bgStr$suffix"] = JsonPrimitive(fallback)
                warnings += "自定义阅读背景图片未迁移；Android 原生配置使用纯色背景，原路径保留在 KMP metadata。"
            }
            row["textColor$suffix"] = JsonPrimitive(validColor(
                (row["textColor$suffix"] as? JsonPrimitive)?.contentOrNull,
                if (suffix == "Night") "#ADADAD" else if (suffix == "EInk") "#000000" else "#3E3D3B",
            ))
        }
        return JsonObject(row)
    }

    private fun androidDefaultPreset(): ReaderPreset = ReaderPreset(name = "", textSize = 20)

    private fun sharedPreset(snapshot: JsonObject): ReaderPreset? = runCatching {
        val fields = setOf(
            "textFont", "textSize", "lineSpacingExtra", "textBold", "letterSpacing", "paragraphSpacing",
            "paragraphIndent", "underline", "bgAlpha", "titleMode", "titleSize", "titleTopSpacing",
            "titleBottomSpacing", "paddingTop", "paddingBottom", "paddingLeft", "paddingRight",
            "headerPaddingTop", "headerPaddingBottom", "headerPaddingLeft", "headerPaddingRight",
            "footerPaddingTop", "footerPaddingBottom", "footerPaddingLeft", "footerPaddingRight",
            "showHeaderLine", "showFooterLine", "tipHeaderLeft", "tipHeaderMiddle", "tipHeaderRight",
            "tipFooterLeft", "tipFooterMiddle", "tipFooterRight", "tipColorHex", "tipDividerColorHex",
            "headerMode", "footerMode",
        )
        val aliases = mapOf("fontName" to "textFont", "backgroundAlpha" to "bgAlpha")
        val layout = snapshot.filterKeys { it in fields }.toMutableMap()
        aliases.forEach { (source, target) -> snapshot[source]?.let { layout[target] = it } }
        fun scaled(source: String, target: String, scale: Float) {
            val element = snapshot[source] ?: return
            val primitive = element as? JsonPrimitive
            require(primitive != null && !primitive.isString) { "共享阅读排版数值无效" }
            val value = primitive.floatOrNull?.times(scale)
            require(value != null && value.isFinite()) { "共享阅读排版数值无效" }
            layout[target] = JsonPrimitive(value.roundToInt())
        }
        scaled("fontSizeSp", "textSize", 1f)
        scaled("lineSpacingMultiplier", "lineSpacingExtra", 10f)
        require(layout.isNotEmpty()) { "共享阅读排版快照为空" }
        // Start independently of the selected preset; visuals are never shared-layout fields.
        val row = json.encodeToJsonElement(ReaderPreset.serializer(), androidDefaultPreset()).jsonObject + layout
        json.decodeFromJsonElement(ReaderPreset.serializer(), JsonObject(row)).also {
            require(it.paragraphIndent in 0..64 && it.titleSize.isFinite() && it.letterSpacing.isFinite()) {
                "共享阅读排版快照无效"
            }
        }
    }.getOrNull()

    private fun theme(preset: ThemePreset): JsonObject {
        val valid = ThemePresetCodec.validated(preset)
        return JsonObject(json.encodeToJsonElement(ThemePreset.serializer(), valid).jsonObject - "pairedThemeName")
    }

    private fun validColor(value: String?, fallback: String): String {
        if (value == null) return fallback
        return try {
            ThemePresetCodec.colorInt(value)
            value
        } catch (_: IllegalArgumentException) {
            warnings += "部分颜色值不符合 Android Color.parseColor 契约，原生配置使用默认颜色，原值保留在 KMP metadata。"
            fallback
        }
    }

    private fun tipColor(value: String?, divider: Boolean): Int {
        val fallback = if (divider) -1 else 0
        if (value == null) return fallback
        if (value == "@text") return 0
        val color = runCatching { ThemePresetCodec.colorInt(value) }.getOrNull()
        if (color == null) {
            warnings += "页眉页脚颜色无效，Android 使用默认颜色；原值保留在 KMP metadata。"
            return fallback
        }
        if (color == 0 || (divider && color == -1)) {
            warnings += "部分颜色与 Android 的跟随正文／默认分隔线标记重合；原颜色保留在 KMP metadata。"
        }
        return color
    }

    private fun requireStrings(rule: JsonObject, vararg keys: String) {
        require(keys.all { (rule[it] as? JsonPrimitive)?.isString == true }) { "Android 原生规则缺少必要字符串字段" }
    }

    private fun xml(config: Map<String, JsonElement>): String = buildString {
        append("<?xml version='1.0' encoding='utf-8' standalone='yes' ?>\n<map>\n")
        config.entries.sortedBy { it.key }.forEach { (key, element) ->
            val value = element as? JsonPrimitive ?: return@forEach
            if (value is JsonNull) return@forEach
            val name = escapeXml(key)
            val text = escapeXml(value.content)
            val type = AndroidBackupExportPreferenceKeys.xmlType(key, value)
            if (type == "string") append("    <string name=\"$name\">$text</string>\n")
            else append("    <$type name=\"$name\" value=\"$text\" />\n")
        }
        append("</map>\n")
    }

    private fun escapeXml(text: String): String = buildString {
        var index = 0
        while (index < text.length) {
            val char = text[index++]
            when (char) {
                '&' -> append("&amp;")
                '<' -> append("&lt;")
                '>' -> append("&gt;")
                '"' -> append("&quot;")
                '\'' -> append("&apos;")
                '\r' -> append("&#13;")
                '\n' -> append("&#10;")
                '\t' -> append("&#9;")
                else -> {
                    require(char.code >= 32 && char != '\uFFFE' && char != '\uFFFF') { "Android 偏好包含 XML 不支持的字符" }
                    if (char.isHighSurrogate()) {
                        require(index < text.length && text[index].isLowSurrogate()) { "Android 偏好包含无效 UTF-16" }
                        append(char).append(text[index++])
                    } else {
                        require(!char.isLowSurrogate()) { "Android 偏好包含无效 UTF-16" }
                        append(char)
                    }
                }
            }
        }
    }
}
