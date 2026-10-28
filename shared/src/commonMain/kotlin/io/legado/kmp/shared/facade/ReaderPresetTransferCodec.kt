package io.legado.kmp.shared.facade

import io.legado.kmp.shared.preferences.ReaderPreset
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.floatOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.put

/**
 * Android Legado 5f5d314 ReadBookConfig.Config, without filesystem or platform resolution.
 * Names, including empty names, are preserved. Unknown keys are ignored, not re-exported.
 * Tip null follows body text; divider null uses the default, @text follows body text, hex is literal.
 * Android color names normalize to #AARRGGBB; existing hex, image and font references stay unchanged.
 * Legacy KMP nullable fields and numeric indents are accepted; exports use Android defaults and types.
 */
class ReaderPresetTransferCodec {
    private val json = Json

    @Throws(RecoverableSharedException::class)
    fun decode(jsonString: String): ReaderPreset = recover("ReaderPresetTransferCodec.decode") {
        require(jsonString.length <= MAX_JSON_CHARS) { "阅读配置 JSON 超过 1 MiB 字符" }
        val source = json.parseToJsonElement(jsonString) as? JsonObject
            ?: error("阅读配置必须是单个 JSON 对象")
        read(source)
    }

    @Throws(RecoverableSharedException::class)
    fun encode(preset: ReaderPreset): String = recover("ReaderPresetTransferCodec.encode") {
        // Legacy KMP presets may keep the custom day image in a separate field.
        val dayBackground = if (preset.bgType == 2 &&
            (preset.bgStr.isNullOrEmpty() || preset.bgStr.startsWith('#'))) {
            preset.backgroundImagePath ?: preset.bgStr
        } else preset.bgStr
        val source = buildJsonObject {
            put("name", preset.name)
            put("bgStr", normalizeBackground(dayBackground ?: "#EEEEEE", preset.bgType, "bgStr"))
            put("bgStrNight", normalizeBackground(preset.bgStrNight ?: "#000000", preset.bgTypeNight, "bgStrNight"))
            put("bgStrEInk", normalizeBackground(preset.bgStrEInk ?: "#FFFFFF", preset.bgTypeEInk, "bgStrEInk"))
            put("bgAlpha", preset.bgAlpha)
            put("bgType", preset.bgType)
            put("bgTypeNight", preset.bgTypeNight)
            put("bgTypeEInk", preset.bgTypeEInk)
            put("darkStatusIcon", preset.darkStatusIcon)
            put("darkStatusIconNight", preset.darkStatusIconNight)
            put("darkStatusIconEInk", preset.darkStatusIconEInk)
            put("textColor", normalizeColor(preset.textColor ?: "#3E3D3B", "textColor"))
            put("textColorNight", normalizeColor(preset.textColorNight ?: "#ADADAD", "textColorNight"))
            put("textColorEInk", normalizeColor(preset.textColorEInk ?: "#000000", "textColorEInk"))
            put("pageAnim", preset.pageAnim)
            put("pageAnimEInk", preset.pageAnimEInk)
            put("textFont", preset.textFont ?: "")
            put("textBold", preset.textBold)
            put("textSize", preset.textSize ?: 20)
            put("letterSpacing", preset.letterSpacing)
            put("lineSpacingExtra", preset.lineSpacingExtra ?: 12)
            put("paragraphSpacing", preset.paragraphSpacing)
            require(preset.paragraphIndent in 0..MAX_INDENT) { "段落缩进必须在 0..$MAX_INDENT 内" }
            put("paragraphIndent", "\u3000".repeat(preset.paragraphIndent))
            put("underline", preset.underline)
            put("titleMode", preset.titleMode)
            put("titleSize", titleSize(JsonPrimitive(preset.titleSize)).toInt())
            put("titleTopSpacing", preset.titleTopSpacing)
            put("titleBottomSpacing", preset.titleBottomSpacing)
            put("paddingBottom", preset.paddingBottom)
            put("paddingLeft", preset.paddingLeft ?: 16)
            put("paddingRight", preset.paddingRight ?: 16)
            put("paddingTop", preset.paddingTop)
            put("headerPaddingBottom", preset.headerPaddingBottom)
            put("headerPaddingLeft", preset.headerPaddingLeft)
            put("headerPaddingRight", preset.headerPaddingRight)
            put("headerPaddingTop", preset.headerPaddingTop)
            put("footerPaddingBottom", preset.footerPaddingBottom)
            put("footerPaddingLeft", preset.footerPaddingLeft)
            put("footerPaddingRight", preset.footerPaddingRight)
            put("footerPaddingTop", preset.footerPaddingTop)
            put("showHeaderLine", preset.showHeaderLine)
            put("showFooterLine", preset.showFooterLine)
            put("tipHeaderLeft", preset.tipHeaderLeft)
            put("tipHeaderMiddle", preset.tipHeaderMiddle)
            put("tipHeaderRight", preset.tipHeaderRight)
            put("tipFooterLeft", preset.tipFooterLeft)
            put("tipFooterMiddle", preset.tipFooterMiddle)
            put("tipFooterRight", preset.tipFooterRight)
            put("tipColor", encodeTipColor(preset.tipColorHex, divider = false))
            put("tipDividerColor", encodeTipColor(preset.tipDividerColorHex, divider = true))
            put("headerMode", preset.headerMode)
            put("footerMode", preset.footerMode)
        }
        read(source)
        source.toString().also {
            require(it.length <= MAX_JSON_CHARS) { "阅读配置 JSON 超过 1 MiB 字符" }
        }
    }

    private fun read(source: JsonObject): ReaderPreset {
        val dayType = source.integer("bgType", 0, 0..2)
        val nightType = source.integer("bgTypeNight", 0, 0..2)
        val einkType = source.integer("bgTypeEInk", 0, 0..2)
        return ReaderPreset(
            name = source.string("name", "", nullAsDefault = false),
            bgStr = source.background("bgStr", "#EEEEEE", dayType),
            bgStrNight = source.background("bgStrNight", "#000000", nightType),
            bgStrEInk = source.background("bgStrEInk", "#FFFFFF", einkType),
            bgAlpha = source.integer("bgAlpha", 100, 0..100),
            bgType = dayType,
            bgTypeNight = nightType,
            bgTypeEInk = einkType,
            backgroundImagePath = source.optionalString("backgroundImagePath"),
            darkStatusIcon = source.boolean("darkStatusIcon", true),
            darkStatusIconNight = source.boolean("darkStatusIconNight", false),
            darkStatusIconEInk = source.boolean("darkStatusIconEInk", true),
            textColor = source.color("textColor", "#3E3D3B"),
            textColorNight = source.color("textColorNight", "#ADADAD"),
            textColorEInk = source.color("textColorEInk", "#000000"),
            pageAnim = source.integer("pageAnim", 0, 0..4),
            pageAnimEInk = source.integer("pageAnimEInk", 4, 0..4),
            textFont = source.string("textFont", ""),
            textBold = source.integer("textBold", 0, 0..2),
            textSize = source.integer("textSize", 20, 1..Int.MAX_VALUE, nullAsDefault = true),
            letterSpacing = source.finiteFloat("letterSpacing", 0.1f),
            lineSpacingExtra = source.integer("lineSpacingExtra", 12, nullAsDefault = true),
            paragraphSpacing = source.integer("paragraphSpacing", 2),
            paragraphIndent = paragraphIndent(source["paragraphIndent"]),
            underline = source.boolean("underline", false),
            titleMode = source.integer("titleMode", 0, 0..2),
            titleSize = source["titleSize"]?.let(::titleSize) ?: 0f,
            titleTopSpacing = source.integer("titleTopSpacing", 0),
            titleBottomSpacing = source.integer("titleBottomSpacing", 0),
            paddingBottom = source.integer("paddingBottom", 6),
            paddingLeft = source.integer("paddingLeft", 16, nullAsDefault = true),
            paddingRight = source.integer("paddingRight", 16, nullAsDefault = true),
            paddingTop = source.integer("paddingTop", 6),
            headerPaddingBottom = source.integer("headerPaddingBottom", 0),
            headerPaddingLeft = source.integer("headerPaddingLeft", 16),
            headerPaddingRight = source.integer("headerPaddingRight", 16),
            headerPaddingTop = source.integer("headerPaddingTop", 0),
            footerPaddingBottom = source.integer("footerPaddingBottom", 6),
            footerPaddingLeft = source.integer("footerPaddingLeft", 16),
            footerPaddingRight = source.integer("footerPaddingRight", 16),
            footerPaddingTop = source.integer("footerPaddingTop", 6),
            showHeaderLine = source.boolean("showHeaderLine", false),
            showFooterLine = source.boolean("showFooterLine", true),
            tipHeaderLeft = source.integer("tipHeaderLeft", 2, 0..11),
            tipHeaderMiddle = source.integer("tipHeaderMiddle", 0, 0..11),
            tipHeaderRight = source.integer("tipHeaderRight", 3, 0..11),
            tipFooterLeft = source.integer("tipFooterLeft", 1, 0..11),
            tipFooterMiddle = source.integer("tipFooterMiddle", 0, 0..11),
            tipFooterRight = source.integer("tipFooterRight", 6, 0..11),
            tipColorHex = source.tipColor(divider = false),
            tipDividerColorHex = source.tipColor(divider = true),
            headerMode = source.integer("headerMode", 0, 0..2),
            footerMode = source.integer("footerMode", 0, 0..1),
        )
    }

    private fun JsonObject.integer(
        key: String,
        fallback: Int,
        range: IntRange = Int.MIN_VALUE..Int.MAX_VALUE,
        nullAsDefault: Boolean = false,
    ): Int {
        val element = this[key] ?: return fallback
        if (element == JsonNull && nullAsDefault) return fallback
        val primitive = element as? JsonPrimitive
        require(primitive != null && !primitive.isString) { "$key 必须是整数" }
        val value = primitive.intOrNull ?: error("$key 必须是 Int 范围内的整数")
        require(value in range) { "$key 超出允许范围" }
        return value
    }

    private fun JsonObject.boolean(key: String, fallback: Boolean): Boolean {
        val element = this[key] ?: return fallback
        val primitive = element as? JsonPrimitive
        require(primitive != null && !primitive.isString) { "$key 必须是布尔值" }
        return primitive.booleanOrNull ?: error("$key 必须是布尔值")
    }

    private fun JsonObject.optionalString(key: String): String? {
        val element = this[key] ?: return null
        if (element == JsonNull) return null
        val primitive = element as? JsonPrimitive
        require(primitive != null && primitive.isString) { "$key 必须是字符串" }
        require(primitive.content.length <= MAX_STRING_CHARS) { "$key 字符串过长" }
        return primitive.content
    }

    private fun JsonObject.string(key: String, fallback: String, nullAsDefault: Boolean = true): String {
        require(nullAsDefault || this[key] != JsonNull) { "$key 不能为 null" }
        return optionalString(key) ?: fallback
    }

    private fun JsonObject.finiteFloat(key: String, fallback: Float): Float {
        val element = this[key] ?: return fallback
        val primitive = element as? JsonPrimitive
        require(primitive != null && !primitive.isString) { "$key 必须是有限数值" }
        val value = primitive.floatOrNull ?: error("$key 必须是数值")
        require(value.isFinite()) { "$key 必须是有限 Float 数值" }
        return value
    }

    private fun paragraphIndent(element: JsonElement?): Int {
        if (element == null) return 2
        val primitive = element as? JsonPrimitive ?: error("paragraphIndent 必须是全角空格字符串或整数")
        val value = if (primitive.isString) {
            if (primitive.content.all { it == '\u3000' }) primitive.content.length
            else {
                require(primitive.content.isNotEmpty() && primitive.content.all { it in '0'..'9' }) {
                    "paragraphIndent 只接受全角空格或数字"
                }
                primitive.content.toIntOrNull() ?: error("paragraphIndent 超出整数范围")
            }
        } else primitive.intOrNull ?: error("paragraphIndent 必须是整数")
        require(value in 0..MAX_INDENT) { "段落缩进必须在 0..$MAX_INDENT 内" }
        return value
    }

    private fun titleSize(element: JsonElement): Float {
        val primitive = element as? JsonPrimitive
        require(primitive != null && !primitive.isString) { "titleSize 必须是整数" }
        val number = primitive.doubleOrNull ?: error("titleSize 必须是整数")
        require(number.isFinite() && number >= Int.MIN_VALUE.toDouble() && number <= Int.MAX_VALUE.toDouble() &&
            number % 1.0 == 0.0 && number.toFloat().toDouble() == number) {
            "titleSize 必须是 ReaderPreset 可精确表示的原始 Int 值"
        }
        return number.toFloat()
    }

    private fun JsonObject.background(key: String, fallback: String, type: Int): String =
        normalizeBackground(string(key, fallback), type, key)

    private fun normalizeBackground(value: String, type: Int, key: String): String =
        if (type == 0) normalizeColor(value, key) else value

    private fun JsonObject.color(key: String, fallback: String): String = normalizeColor(string(key, fallback), key)

    private fun normalizeColor(value: String, key: String): String =
        if (HEX_COLOR.matches(value)) value
        else NAMED_COLORS[value.lowercase()] ?: error("$key 不是有效 Android 颜色")

    private fun JsonObject.tipColor(divider: Boolean): String? {
        val androidKey = if (divider) "tipDividerColor" else "tipColor"
        val kmpKey = if (divider) "tipDividerColorHex" else "tipColorHex"
        val android = if (containsKey(androidKey)) {
            decodeTipColor(integer(androidKey, if (divider) ANDROID_DEFAULT_DIVIDER else ANDROID_FOLLOW_TEXT), divider)
        } else null
        val legacy = if (containsKey(kmpKey)) {
            val value = optionalString(kmpKey)
            if (value == null || value == FOLLOW_TEXT) {
                if (divider && value != null) FOLLOW_TEXT else null
            } else {
                require(HEX_COLOR.matches(value)) { "$kmpKey 只接受 null、@text 或 hex 颜色" }
                hexColor(colorInt(value))
            }
        } else null
        require(!containsKey(androidKey) || !containsKey(kmpKey) || android == legacy) {
            "$androidKey 与 $kmpKey 相互冲突"
        }
        return if (containsKey(androidKey)) android else legacy
    }

    // PageView.upStyle (5f5d314): tip 0=body; divider -1=theme divider, 0=body, otherwise literal ARGB.
    private fun decodeTipColor(value: Int, divider: Boolean): String? = if (divider) {
        when (value) {
            ANDROID_DEFAULT_DIVIDER -> null
            ANDROID_FOLLOW_TEXT -> FOLLOW_TEXT
            else -> hexColor(value)
        }
    } else if (value == ANDROID_FOLLOW_TEXT) null else hexColor(value)

    private fun encodeTipColor(value: String?, divider: Boolean): Int {
        if (value == null) return if (divider) ANDROID_DEFAULT_DIVIDER else ANDROID_FOLLOW_TEXT
        if (value == FOLLOW_TEXT) return ANDROID_FOLLOW_TEXT
        require(HEX_COLOR.matches(value)) { "提示颜色只接受 null、@text 或 hex 颜色" }
        val color = colorInt(value)
        // Literal colors colliding with Android policy sentinels cannot round-trip faithfully.
        require(color != ANDROID_FOLLOW_TEXT && (!divider || color != ANDROID_DEFAULT_DIVIDER)) {
            "自定义颜色与 Android 颜色策略哨兵冲突"
        }
        return color
    }

    private fun colorInt(value: String): Int {
        val raw = value.substring(1).toLong(16)
        return (if (value.length == 7) raw or 0xff000000L else raw).toInt()
    }

    private fun hexColor(value: Int): String = "#" + value.toUInt().toString(16).padStart(8, '0').uppercase()

    private inline fun <T> recover(code: String, block: () -> T): T = try {
        block()
    } catch (error: Exception) {
        throw error.asRecoverableSharedException(code)
    }

    private companion object {
        const val MAX_JSON_CHARS = 1024 * 1024
        const val MAX_STRING_CHARS = 4096
        const val MAX_INDENT = 64
        const val FOLLOW_TEXT = "@text"
        const val ANDROID_FOLLOW_TEXT = 0
        const val ANDROID_DEFAULT_DIVIDER = -1
        val HEX_COLOR = Regex("#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?")
        // android.graphics.Color.parseColor, not CSS named-color values (notably gray/green).
        val NAMED_COLORS = mapOf(
            "black" to "#FF000000",
            "darkgray" to "#FF444444",
            "gray" to "#FF888888",
            "lightgray" to "#FFCCCCCC",
            "white" to "#FFFFFFFF",
            "red" to "#FFFF0000",
            "green" to "#FF00FF00",
            "blue" to "#FF0000FF",
            "yellow" to "#FFFFFF00",
            "cyan" to "#FF00FFFF",
            "magenta" to "#FFFF00FF",
            "aqua" to "#FF00FFFF",
            "fuchsia" to "#FFFF00FF",
            "darkgrey" to "#FF444444",
            "grey" to "#FF888888",
            "lightgrey" to "#FFCCCCCC",
            "lime" to "#FF00FF00",
            "maroon" to "#FF800000",
            "navy" to "#FF000080",
            "olive" to "#FF808000",
            "purple" to "#FF800080",
            "silver" to "#FFC0C0C0",
            "teal" to "#FF008080",
        )
    }
}
