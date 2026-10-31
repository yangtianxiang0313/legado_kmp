package io.legado.kmp.shared.preferences

import platform.Foundation.NSUserDefaults

/** The same synchronous restore runs against an isolated defaults snapshot during preparation. */
internal object IosBackupPreferencesRestore {
    fun restore(defaults: NSUserDefaults, data: PreferencesBackupData, ignoredKeys: Set<String>) {
        val readers = IosReaderPresetPersistence(defaults)
        materializeLegacyReaderPresetValues(defaults, readers)
        IosPreferencesBackup.restore(defaults, data, ignoredKeys)
        defaults.restoreReaderSharedLayout(data, ignoredKeys)
        readers.reload()
        // Android presets contain the active layout; iOS snapshots already contain its exact defaults.
        if (BackupRestoreIgnoreKeys.READ_CONFIG !in ignoredKeys && data.readConfig.isNotEmpty() &&
            data.appConfig.keys.none { it in READER_STYLE_PREFERENCE_KEYS }) {
            val index = defaults.integerForKey(KEY_READ_STYLE_INDEX).toInt().coerceIn(0, readers.presets.lastIndex)
            val preset = readers.presets[index]
            val independent = IosPreferencesBackup.readerStyle(preset, defaults.stringForKey(KEY_THEME_MODE))
            val shared = defaults.readReaderSharedLayout().takeIf { defaults.boolForKey(KEY_SHARE_LAYOUT) }
            defaults.writeReaderStyleSnapshot(preset.name, shared?.let(independent::withSharedLayoutFrom) ?: independent)
            defaults.setBool(true, KEY_LINE_SPACING_MIGRATED)
            defaults.synchronize()
        }
    }

    fun materializeLegacyReaderPresetValues(defaults: NSUserDefaults, readers: IosReaderPresetPersistence) {
        migrateReaderLineSpacingToAndroidScale(defaults)
        readers.materializeLegacyValues()
    }

    private fun migrateReaderLineSpacingToAndroidScale(defaults: NSUserDefaults) {
        if (defaults.boolForKey(KEY_LINE_SPACING_MIGRATED)) return
        defaults.setBool(true, KEY_LINE_SPACING_MIGRATED)
        if (defaults.objectForKey(KEY_READER_LINE_SPACING) == null) return
        val oldMultiplier = defaults.floatForKey(KEY_READER_LINE_SPACING)
        if (oldMultiplier < 1f) return
        defaults.setFloat((oldMultiplier - 1f).coerceIn(0f, 2f), KEY_READER_LINE_SPACING)
    }

    private const val KEY_THEME_MODE = "theme_mode"
    private const val KEY_SHARE_LAYOUT = "share_layout"
    private const val KEY_READ_STYLE_INDEX = "read_style_index"
    private const val KEY_LINE_SPACING_MIGRATED = "reader_line_spacing_android_scale_migrated"
}
