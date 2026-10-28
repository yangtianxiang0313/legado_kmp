package io.legado.kmp.shared.facade

import io.legado.kmp.shared.preferences.AppPreferencesStore
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.intOrNull

/** ThemeConfig's independent background image channels; color presets deliberately exclude images. */
data class ThemeBackgroundSettings(
    val isNightTheme: Boolean,
    val imagePath: String?,
    val blurring: Int,
)

internal class ThemeBackgroundPreferences(private val preferences: AppPreferencesStore) {
    fun read(isNightTheme: Boolean): ThemeBackgroundSettings = ThemeBackgroundSettings(
        isNightTheme = isNightTheme,
        imagePath = primitive(imageKey(isNightTheme))?.takeUnless { it is JsonNull }
            ?.content?.takeIf { it.isNotBlank() },
        blurring = (primitive(blurKey(isNightTheme))?.intOrNull ?: 0).coerceIn(0, 25),
    )

    fun setImage(isNightTheme: Boolean, imagePath: String?, expectedImagePath: String?) {
        require(read(isNightTheme).imagePath == expectedImagePath) { "背景图片已改变，请重新打开设置" }
        if (imagePath != null) {
            require(imagePath.matches(MANAGED_IMAGE)) { "背景图片标识无效，请重新选择图片" }
        }
        preferences.setBackupConfigJson(imageKey(isNightTheme), imagePath?.let { JsonPrimitive(it).toString() })
    }

    fun setBlurring(isNightTheme: Boolean, blurring: Int, expectedBlurring: Int) {
        require(blurring in 0..25) { "背景模糊度必须在 0 到 25 之间" }
        require(read(isNightTheme).blurring == expectedBlurring) { "背景模糊度已改变，请重新打开设置" }
        preferences.setBackupConfigJson(blurKey(isNightTheme), JsonPrimitive(blurring).toString())
    }

    private fun primitive(key: String): JsonPrimitive? = preferences.getBackupConfigJson(key)?.let { raw ->
        runCatching { Json.parseToJsonElement(raw) as? JsonPrimitive }.getOrNull()
    }

    private fun imageKey(isNightTheme: Boolean) = if (isNightTheme) "backgroundImageNight" else "backgroundImage"
    private fun blurKey(isNightTheme: Boolean) = if (isNightTheme) "backgroundImageNightBlurring" else "backgroundImageBlurring"

    private companion object {
        val MANAGED_IMAGE = Regex("legado-theme-background:[0-9a-f]{64}\\.png")
    }
}
