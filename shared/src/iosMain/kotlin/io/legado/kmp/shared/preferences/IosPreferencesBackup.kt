package io.legado.kmp.shared.preferences

import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import platform.Foundation.NSNumber
import platform.Foundation.NSUserDefaults

/** Maps Android preference names onto the same defaults observed by the running iOS app. */
internal object IosPreferencesBackup {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private const val THEMES = "backup_theme_presets"
    private const val RAW_CONFIG = "backup_android_config"
    private val keys = setOf(
        "theme_mode",
        "keep_screen_on",
        "bookshelf_layout",
        "bookshelf_layout_mode",
        "bookshelf_sort",
        "book_group_style",
        "show_unread",
        "show_last_update_time",
        "show_wait_up_count",
        "show_bookshelf_fast_scroller",
        "save_tab_position",
        "theme_preset_name",
        "colorPrimary", "colorAccent", "colorBackground", "colorBottomBackground",
        "colorPrimaryNight", "colorAccentNight", "colorBackgroundNight", "colorBottomBackgroundNight",
        "reader_preset_name",
        "reader_line_spacing_android_scale_migrated",
        "thread_count",
        "precision_search",
        "replace_rule_enabled_by_default",
        "ignore_audio_focus",
        "change_source_check_author",
        "change_source_load_info",
        "change_source_load_toc",
        "change_source_load_word_count",
        "auto_change_source",
        "web_dav_url",
        "web_dav_account",
        "web_dav_password",
        "webDavDir",
        "syncBookProgress",
        "syncBookProgressPlus",
        "only_latest_backup",
        "auto_check_new_backup",
        "remote_server_id",
        "brightness_day",
        "brightness_night",
        "page_animation",
        "share_layout",
        "read_style_index",
        "comic_style_index",
        "auto_read_speed",
        "tts_follow_system_rate",
        "tts_speech_rate",
        "tts_timer_minutes",
        "tts_voice_identifier",
        "text_full_justify",
        "text_bottom_justify",
        "hide_status_bar",
        "hide_navigation_bar",
        "reader_chinese_mode",
        "tap_top_left",
        "tap_top_center",
        "tap_top_right",
        "tap_middle_left",
        "tap_middle_center",
        "tap_middle_right",
        "tap_bottom_left",
        "tap_bottom_center",
        "tap_bottom_right",
        "user_agent",
        "text_select_able",
        "screen_orientation",
        "book_export_file_name",
        "episode_export_file_name",
        "show_discovery",
        "show_rss",
        "auto_refresh_book",
        "export_charset",
        "export_use_replace",
        "export_to_webdav",
        "export_no_chapter_name",
        "enable_custom_export",
        "export_type",
        "export_picture_file",
        "parallel_export_book",
        "tts_engine",
        "toc_ui_use_replace",
        "toc_count_words",
        "enable_read_record",
        "import_keep_name",
        "import_keep_group",
        "import_keep_enable",
        "pre_download_num",
        "media_button_on_exit",
        "read_aloud_by_media_button",
        "pause_read_aloud_while_phone_calls",
        "stream_read_aloud_audio",
        "double_page_horizontal",
        "key_page_on_long_press",
        "volume_key_page",
        "volume_key_page_on_play",
        "mouse_wheel_page",
        "search_scope",
        "search_group",
        "show_manga_ui",
        "disable_manga_scale",
        "disable_manga_page_anim",
        "manga_pre_download_num",
        "disable_click_scroll",
        "manga_auto_page_speed",
        "manga_footer_config",
        "enable_manga_horizontal_scroll",
        "manga_color_filter",
        "hide_manga_title",
        "enable_manga_eink",
        "manga_eink_threshold",
        "disable_horizontal_page_snap",
        "enable_manga_gray",
        "use_zh_layout",
        "read_body_to_lh",
        "is_comic",
        "is_cronet",
        "use_anti_alias",
        "use_default_cover",
        "optimize_render",
        "record_log",
        "is_transparent_status_bar",
        "imm_navigation_bar",
        "book_import_file_name",
        "enable_review",
        "import_book_path",
        "no_anim_scroll_page",
        "web_port",
        "open_book_info_by_click_title",
        "content_select_speak_mod",
        "batch_change_source_delay",
        "previewImageByClick",
        "preview_image_by_click",
        "progress_bar_behavior",
        "padding_display_cutouts",
        "pageTouchSlop",
        "page_touch_slop",
        "bitmap_cache_size",
        "image_retain_num",
        "show_read_title_bar_addition",
        "read_bar_style_follow_page",
        "source_edit_max_line",
        "audio_play_use_wake_lock",
        "audio_play_mode",
        "brightness_vw_pos",
        "welcome_image",
        "welcome_show_text",
        "welcome_show_icon",
        "welcome_image_dark",
        "welcome_show_text_dark",
        "welcome_show_icon_dark",
        "default_home_page",
        "update_to_variant",
        "load_cover_only_wifi",
        "show_add_to_shelf_alert",
        "bookInfoDeleteAlert",
        "record_heap_dump",
    ) + READER_STYLE_PREFERENCE_KEYS

    // Opening the first settings panel must not replace preferences already saved from another screen.
    fun hasStoredPreferences(defaults: NSUserDefaults): Boolean =
        keys.any { defaults.objectForKey(it) != null }
    private fun camel(key: String): String = key.split('_').mapIndexed { index, part ->
        if (index == 0) part else part.replaceFirstChar { it.uppercase() }
    }.joinToString("")

    private val aliases = keys.associateBy(::camel) + mapOf(
        "web_dav_url" to "web_dav_url",
        "web_dav_account" to "web_dav_account",
        "selectText" to "text_select_able",
        "appTtsEngine" to "tts_engine",
        "doubleHorizontalPage" to "double_page_horizontal",
        "contentReadAloudMod" to "content_select_speak_mod",
        "welcomeImagePath" to "welcome_image",
        "welcomeImagePathDark" to "welcome_image_dark",
        "autoRefreshOnStart" to "auto_refresh_book",
        "isKeepScreenOn" to "keep_screen_on",
        "readStyleSelect" to "read_style_index", "comicStyleSelect" to "comic_style_index",
        "showRss" to "show_rss", "webDavUrl" to "web_dav_url", "webDavAccount" to "web_dav_account", "webDavPassword" to "web_dav_password",
        "pageAnim" to "page_animation", "brightness" to "brightness_day",
        "brightnessNight" to "brightness_night", "replaceEnableDefault" to "replace_rule_enabled_by_default",
        "clickActionTL" to "tap_top_left", "clickActionTC" to "tap_top_center", "clickActionTR" to "tap_top_right",
        "clickActionML" to "tap_middle_left", "clickActionMC" to "tap_middle_center", "clickActionMR" to "tap_middle_right",
        "clickActionBL" to "tap_bottom_left", "clickActionBC" to "tap_bottom_center", "clickActionBR" to "tap_bottom_right",
    )

    private val booleanKeys = setOf(
        "audio_play_use_wake_lock",
        "auto_change_source",
        "auto_check_new_backup",
        "auto_refresh_book",
        "bookInfoDeleteAlert",
        "brightness_vw_pos",
        "change_source_check_author",
        "change_source_load_info",
        "change_source_load_toc",
        "change_source_load_word_count",
        "disable_click_scroll",
        "disable_horizontal_page_snap",
        "disable_manga_page_anim",
        "disable_manga_scale",
        "enable_custom_export",
        "enable_manga_eink",
        "enable_manga_gray",
        "enable_manga_horizontal_scroll",
        "enable_read_record",
        "enable_review",
        "export_no_chapter_name",
        "export_picture_file",
        "export_to_webdav",
        "export_use_replace",
        "hide_manga_title",
        "hide_navigation_bar",
        "hide_status_bar",
        "ignore_audio_focus",
        "imm_navigation_bar",
        "import_keep_enable",
        "import_keep_group",
        "import_keep_name",
        "is_comic",
        "is_cronet",
        "is_transparent_status_bar",
        "keep_screen_on",
        "key_page_on_long_press",
        "load_cover_only_wifi",
        "media_button_on_exit",
        "mouse_wheel_page",
        "no_anim_scroll_page",
        "only_latest_backup",
        "open_book_info_by_click_title",
        "optimize_render",
        "padding_display_cutouts",
        "parallel_export_book",
        "pause_read_aloud_while_phone_calls",
        "precision_search",
        "previewImageByClick",
        "preview_image_by_click",
        "read_aloud_by_media_button",
        "read_bar_style_follow_page",
        "read_body_to_lh",
        "reader_dark_status_icon",
        "reader_line_spacing_android_scale_migrated",
        "reader_show_footer_line",
        "reader_show_header_line",
        "reader_underline",
        "record_heap_dump",
        "record_log",
        "replace_rule_enabled_by_default",
        "share_layout",
        "show_add_to_shelf_alert",
        "show_bookshelf_fast_scroller",
        "show_discovery",
        "show_last_update_time",
        "show_manga_ui",
        "show_read_title_bar_addition",
        "show_rss",
        "show_unread",
        "show_wait_up_count",
        "stream_read_aloud_audio",
        "syncBookProgress",
        "syncBookProgressPlus",
        "text_bottom_justify",
        "text_full_justify",
        "text_select_able",
        "toc_count_words",
        "toc_ui_use_replace",
        "tts_follow_system_rate",
        "use_anti_alias",
        "use_default_cover",
        "use_zh_layout",
        "volume_key_page",
        "volume_key_page_on_play",
        "welcome_show_icon",
        "welcome_show_icon_dark",
        "welcome_show_text",
        "welcome_show_text_dark",
    )
    private val uiBooleanAliases = mapOf(
        "show_rss" to "showRss", "show_discovery" to "showDiscovery",
        "auto_refresh_book" to "autoRefreshOnStart", "keep_screen_on" to "keepScreenOn",
        "show_add_to_shelf_alert" to "showAddToShelfAlert",
    )
    private fun booleanValue(value: JsonPrimitive): Boolean? = value.booleanOrNull ?: when (value.content) {
        "1" -> true
        "0" -> false
        else -> null
    }

    private fun homeName(value: String?): String = when (value) {
        "1", "explore", "discovery" -> "discovery"
        "2", "rss" -> "rss"
        "3", "my", "person", "settings" -> "settings"
        else -> "bookshelf"
    }

    private fun restoreUiAlias(defaults: NSUserDefaults, key: String, value: JsonPrimitive): Boolean {
        uiBooleanAliases[key]?.let { alias ->
            val enabled = if (value is JsonNull) key in setOf("show_rss", "show_discovery", "show_add_to_shelf_alert")
                else booleanValue(value) ?: return true
            defaults.setBool(enabled, key)
            defaults.setBool(enabled, alias)
            return true
        }
        if (key == "default_home_page") {
            val name = homeName(value.takeUnless { it is JsonNull }?.content)
            defaults.setObject(name, key)
            defaults.setInteger(listOf("bookshelf", "discovery", "rss", "settings").indexOf(name).toLong(), "defaultHomePage")
            return true
        }
        return false
    }

    fun getConfig(defaults: NSUserDefaults, key: String): String? = runCatching {
        json.parseToJsonElement(defaults.stringForKey(RAW_CONFIG) ?: "{}").jsonObject[key]?.toString()
    }.getOrNull()

    fun setConfig(defaults: NSUserDefaults, key: String, value: String?) {
        val config = json.parseToJsonElement(defaults.stringForKey(RAW_CONFIG) ?: "{}").jsonObject.toMutableMap()
        if (value == null) config.remove(key) else config[key] = json.parseToJsonElement(value)
        defaults.setObject(JsonObject(config).toString(), RAW_CONFIG)
        defaults.synchronize()
    }

    fun readerStyle(preset: ReaderPreset, themeMode: String?): ReaderStylePreferences =
        preset.styleForVariant(
            (ThemeMode.entries.firstOrNull { it.name == themeMode } ?: ThemeMode.SYSTEM).readerVisualVariant())

    fun loadThemes(defaults: NSUserDefaults): List<ThemePreset> = runCatching {
        defaults.stringForKey(THEMES)?.let { json.decodeFromString<List<ThemePreset>>(it) }
            ?: DefaultUiPresets.themePresets
    }.getOrDefault(DefaultUiPresets.themePresets)

    fun export(defaults: NSUserDefaults, readers: List<ReaderPreset>, themes: List<ThemePreset>): PreferencesBackupData {
        val values = runCatching {
            json.parseToJsonElement(defaults.stringForKey(RAW_CONFIG) ?: "{}").jsonObject.toMutableMap()
        }.getOrDefault(mutableMapOf())
        keys.forEach { key ->
            val value = defaults.objectForKey(key)
            when {
                value == null -> values[key] = JsonNull
                key in booleanKeys -> values[key] = JsonPrimitive(defaults.boolForKey(key))
                else -> when (value) {
                    is String -> values[key] = JsonPrimitive(value)
                    is Boolean -> values[key] = JsonPrimitive(value)
                    is NSNumber -> values[key] = json.parseToJsonElement(value.stringValue)
                    is Number -> values[key] = JsonPrimitive(value.toDouble())
                }
            }
        }
        uiBooleanAliases.forEach { (canonical, alias) ->
            if (defaults.objectForKey(alias) != null) values[canonical] = JsonPrimitive(defaults.boolForKey(alias))
        }
        if (defaults.objectForKey("defaultHomePage") != null) {
            values["default_home_page"] = JsonPrimitive(homeName(defaults.integerForKey("defaultHomePage").toString()))
        }
        return PreferencesBackupData(JsonObject(values), readers, themes)
    }

    fun restore(defaults: NSUserDefaults, data: PreferencesBackupData, ignored: Set<String>) {
        val retained = runCatching {
            json.parseToJsonElement(defaults.stringForKey(RAW_CONFIG) ?: "{}").jsonObject.toMutableMap()
        }.getOrDefault(mutableMapOf())
        // Canonical snapshot values take precedence over preserved Android aliases.
        data.appConfig.entries.sortedBy { if (it.key in keys) 1 else 0 }.forEach { (sourceKey, element) ->
            val key = aliases[sourceKey] ?: sourceKey
            if (!isAllowed(key, ignored)) return@forEach
            retained[sourceKey] = element
            if (key !in keys) return@forEach
            if (sourceKey == "bookshelfLayout") {
                (element as? JsonPrimitive)?.intOrNull?.let {
                    defaults.setObject(BookshelfLayoutMode.fromLegacyIndex(it).name, "bookshelf_layout_mode")
                }
            }
            val value = element as? JsonPrimitive ?: return@forEach
            if (restoreUiAlias(defaults, key, value)) return@forEach
            when {
                value is JsonNull -> defaults.removeObjectForKey(key)
                key == "theme_mode" -> {
                    val mode = when (value.content) {
                        "0" -> ThemeMode.SYSTEM.name
                        "1" -> ThemeMode.LIGHT.name
                        "2" -> ThemeMode.DARK.name
                        "3" -> ThemeMode.E_INK.name
                        else -> value.content
                    }
                    if (ThemeMode.entries.any { it.name == mode }) defaults.setObject(mode, key)
                }
                key in booleanKeys -> booleanValue(value)?.let { defaults.setBool(it, key) }
                value.isString -> defaults.setObject(value.content, key)
                value.booleanOrNull != null -> defaults.setBool(value.booleanOrNull!!, key)
                value.doubleOrNull != null -> defaults.setDouble(value.doubleOrNull!!, key)
            }
        }
        defaults.setObject(JsonObject(retained).toString(), RAW_CONFIG)
        if (BackupRestoreIgnoreKeys.READ_CONFIG !in ignored && data.readConfig.isNotEmpty()) {
            defaults.setObject(json.encodeToString(data.readConfig), "custom_reader_presets")
        }
        if (BackupRestoreIgnoreKeys.THEME_CONFIG !in ignored && data.themeConfig.isNotEmpty()) {
            defaults.setObject(json.encodeToString(data.themeConfig), THEMES)
            val selectedName = defaults.stringForKey("theme_preset_name")
            if (data.themeConfig.none { it.themeName == selectedName }) {
                val dark = defaults.stringForKey("theme_mode") == ThemeMode.DARK.name
                val selectedTheme = data.themeConfig.firstOrNull { it.isNightTheme == dark } ?: data.themeConfig.first()
                defaults.setObject(selectedTheme.themeName, "theme_preset_name")
            }
        }
        defaults.setBool(true, "initialized")
        defaults.synchronize()
    }

    private fun isAllowed(key: String, ignored: Set<String>): Boolean = when {
        key in setOf("backup_restore_ignored_keys", "backup_path", "default_book_tree_uri", "webDavDeviceName") -> false
        BackupRestoreIgnoreKeys.READ_CONFIG in ignored && (key.startsWith("reader_") || key.startsWith("tap_") || key == "android.readConfig" || key == "android.shareReadConfig" || key in readerKeys) -> false
        BackupRestoreIgnoreKeys.THEME_MODE in ignored && key == "theme_mode" -> false
        BackupRestoreIgnoreKeys.THEME_CONFIG in ignored && (key in themeKeys || key == "android.themeConfig") -> false
        BackupRestoreIgnoreKeys.COVER_CONFIG in ignored && key in setOf("android.coverRule.json", "android.coverConfig.json", "use_default_cover", "load_cover_only_wifi", "coverShowName", "coverShowAuthor", "coverShowNameN", "coverShowAuthorN") -> false
        BackupRestoreIgnoreKeys.BOOKSHELF_LAYOUT in ignored && key.startsWith("bookshelf_layout") -> false
        BackupRestoreIgnoreKeys.SHOW_RSS in ignored && key == "show_rss" -> false
        BackupRestoreIgnoreKeys.THREAD_COUNT in ignored && key == "thread_count" -> false
        else -> true
    }
    private val readerKeys = setOf("read_style_index", "comic_style_index", "share_layout", "hide_status_bar", "hide_navigation_bar", "auto_read_speed", "page_animation", "brightness_day", "brightness_night", "text_full_justify", "text_bottom_justify")
    private val themeKeys = setOf("theme_preset_name", "colorPrimary", "colorAccent", "colorBackground", "colorBottomBackground", "colorPrimaryNight", "colorAccentNight", "colorBackgroundNight", "colorBottomBackgroundNight", "backgroundImage", "backgroundImageNight", "backgroundImageBlurring", "backgroundImageNightBlurring")
}
