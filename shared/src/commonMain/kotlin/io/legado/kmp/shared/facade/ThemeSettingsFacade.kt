package io.legado.kmp.shared.facade

import io.legado.kmp.shared.preferences.AppPreferencesStore
import io.legado.kmp.shared.preferences.ThemeColorField
import io.legado.kmp.shared.preferences.ThemeColorPalette
import io.legado.kmp.shared.preferences.ThemePreset
import io.legado.kmp.shared.preferences.ThemePresetCodec
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

class ThemeSettingsFacade internal constructor(private val preferences: AppPreferencesStore) {
    private val backgrounds = ThemeBackgroundPreferences(preferences)
    private val backgroundMutex = Mutex()
    val presets: List<ThemePreset> get() = preferences.themePresets

    fun palette(isNightTheme: Boolean): ThemeColorPalette = preferences.themePalette(isNightTheme)

    fun background(isNightTheme: Boolean): ThemeBackgroundSettings = backgrounds.read(isNightTheme)

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setBackgroundImage(isNightTheme: Boolean, imagePath: String?, expectedImagePath: String?) {
        runRecoverable("ThemeSettingsFacade.setBackgroundImage") {
            backgroundMutex.withLock { backgrounds.setImage(isNightTheme, imagePath, expectedImagePath) }
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setBackgroundBlurring(isNightTheme: Boolean, blurring: Int, expectedBlurring: Int) {
        runRecoverable("ThemeSettingsFacade.setBackgroundBlurring") {
            backgroundMutex.withLock { backgrounds.setBlurring(isNightTheme, blurring, expectedBlurring) }
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setColor(isNightTheme: Boolean, field: ThemeColorField, color: String) {
        runRecoverable("ThemeSettingsFacade.setColor") { preferences.setThemeColor(isNightTheme, field, color) }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun savePalette(themeName: String, isNightTheme: Boolean) {
        runRecoverable("ThemeSettingsFacade.savePalette") { preferences.saveThemePalette(themeName, isNightTheme) }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun applyPreset(themeName: String) {
        runRecoverable("ThemeSettingsFacade.applyPreset") { preferences.applyThemePreset(themeName) }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun importPreset(json: String) {
        runRecoverable("ThemeSettingsFacade.importPreset") { preferences.importThemePreset(ThemePresetCodec.decode(json)) }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun deletePreset(themeName: String) {
        runRecoverable("ThemeSettingsFacade.deletePreset") { preferences.deleteThemePreset(themeName) }
    }
}
