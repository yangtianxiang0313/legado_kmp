package io.legado.kmp.shared.facade

import io.legado.kmp.shared.preferences.BookshelfLayoutMode
import kotlinx.serialization.json.*

/** PreferKey values and the storage types read by Android 5f5d314 AppConfig/ReadBookConfig. */
internal object AndroidBackupExportPreferenceKeys {
    private val aliases = mapOf(
        "web_dav_url" to "web_dav_url", "web_dav_account" to "web_dav_account",
        "web_dav_password" to "web_dav_password", "webDavUrl" to "web_dav_url",
        "webDavAccount" to "web_dav_account", "webDavPassword" to "web_dav_password",
        "read_style_index" to "readStyleSelect", "comic_style_index" to "comicStyleSelect",
        "text_select_able" to "selectText", "tts_engine" to "appTtsEngine",
        "tts_follow_system_rate" to "ttsFollowSys", "tts_speech_rate" to "ttsSpeechRate",
        "tts_timer_minutes" to "ttsTimer", "double_page_horizontal" to "doubleHorizontalPage",
        "content_select_speak_mod" to "contentReadAloudMod", "welcome_image" to "welcomeImagePath",
        "welcome_image_dark" to "welcomeImagePathDark", "brightness_day" to "brightness",
        "brightness_night" to "nightBrightness", "brightnessNight" to "nightBrightness",
        "reader_chinese_mode" to "chineseConverterType",
        "replace_rule_enabled_by_default" to "replaceEnableDefault",
        "auto_refresh_book" to "auto_refresh",
        "export_to_webdav" to "webDavCacheBackup", "is_cronet" to "Cronet",
        "use_anti_alias" to "antiAlias", "show_read_title_bar_addition" to "showReadTitleAddition",
        "is_transparent_status_bar" to "transparentStatusBar",
        "audio_play_use_wake_lock" to "audioPlayWakeLock",
        "tap_top_left" to "clickActionTopLeft", "tap_top_center" to "clickActionTopCenter",
        "tap_top_right" to "clickActionTopRight", "tap_middle_left" to "clickActionMiddleLeft",
        "tap_middle_center" to "clickActionMiddleCenter", "tap_middle_right" to "clickActionMiddleRight",
        "tap_bottom_left" to "clickActionBottomLeft", "tap_bottom_center" to "clickActionBottomCenter",
        "tap_bottom_right" to "clickActionBottomRight",
        "clickActionTL" to "clickActionTopLeft", "clickActionTC" to "clickActionTopCenter",
        "clickActionTR" to "clickActionTopRight", "clickActionML" to "clickActionMiddleLeft",
        "clickActionMC" to "clickActionMiddleCenter", "clickActionMR" to "clickActionMiddleRight",
        "clickActionBL" to "clickActionBottomLeft", "clickActionBC" to "clickActionBottomCenter",
        "clickActionBR" to "clickActionBottomRight",
    )

    private val stringKeys = setOf(
        "themeMode", "web_dav_url", "web_dav_account", "web_dav_password", "webDavDir",
        "userAgent", "appTtsEngine", "screenOrientation", "doubleHorizontalPage", "progressBarBehavior",
        "defaultHomePage", "bookExportFileName", "bookImportFileName", "episodeExportFileName",
        "keep_light",
        "exportCharset", "searchScope", "searchGroup", "mangaFooterConfig",
        "mangaColorFilter", "updateToVariant",
        "backgroundImage", "backgroundImageNight", "welcomeImagePath", "welcomeImagePathDark",
        "defaultCover", "defaultCoverDark", "backupUri", "defaultBookTreeUri", "webDavDeviceName",
    )
    private val intKeys = setOf(
        "bookshelfLayout", "bookshelfSort", "bookGroupStyle", "threadCount", "readStyleSelect",
        "comicStyleSelect", "autoReadSpeed", "brightness", "nightBrightness", "ttsSpeechRate", "ttsTimer",
        "chineseConverterType", "preDownloadNum", "mangaPreDownloadNum", "mangaAutoPageSpeed", "webPort",
        "sourceEditMaxLine", "imageRetainNum", "bitmapCacheSize", "batchChangeSourceDelay",
        "clickActionTopLeft", "clickActionTopCenter", "clickActionTopRight", "clickActionMiddleLeft",
        "clickActionMiddleCenter", "clickActionMiddleRight", "clickActionBottomLeft",
        "clickActionBottomCenter", "clickActionBottomRight", "pageTouchSlop",
        "colorPrimary", "colorAccent", "colorBackground", "colorBottomBackground",
        "colorPrimaryNight", "colorAccentNight", "colorBackgroundNight", "colorBottomBackgroundNight",
        "backgroundImageBlurring", "backgroundImageNightBlurring", "exportType", "contentReadAloudMod",
        "mangaEInkThreshold", "saveTabPosition", "system_typefaces",
    )
    private val booleanKeys = setOf(
        "showUnread", "showLastUpdateTime", "showWaitUpCount", "showBookshelfFastScroller", "process_text",
        "showDiscovery", "showRss", "enableReview", "useDefaultCover", "loadCoverOnlyWifi", "coverShowName",
        "coverShowAuthor", "coverShowNameN", "coverShowAuthorN", "hideStatusBar", "hideNavigationBar",
        "precisionSearch", "ttsFollowSys", "recordLog", "enableCustomExport", "webDavCacheBackup",
        "exportNoChapterName", "exportPictureFile", "changeSourceCheckAuthor", "changeSourceLoadToc",
        "changeSourceLoadInfo", "changeSourceLoadWordCount", "selectText", "shareLayout", "readBodyToLh",
        "textFullJustify", "textBottomJustify", "transparentStatusBar", "immNavigationBar",
        "replaceEnableDefault", "autoChangeSource", "importKeepName", "importKeepGroup", "importKeepEnable",
        "syncBookProgress", "syncBookProgressPlus", "Cronet", "antiAlias", "disableClickScroll",
        "enableMangaHorizontalScroll", "hideMangaTitle", "enableMangaEInk", "disableHorizontalPageSnap",
        "enableMangaGray", "auto_refresh", "exportUseReplace", "useZhLayout", "tocUiUseReplace",
        "tocCountWords", "enableReadRecord", "welcomeShowText", "welcomeShowTextDark", "welcomeShowIcon",
        "welcomeShowIconDark", "showAddToShelfAlert", "ignoreAudioFocus", "parallelExportBook", "noAnimScrollPage",
        "webServiceWakeLock", "audioPlayWakeLock", "readAloudWakeLock", "onlyLatestBackup", "brightnessVwPos",
        "openBookInfoByClickTitle", "previewImageByClick", "keyPageOnLongPress", "volumeKeyPage",
        "volumeKeyPageOnPlay", "mouseWheelPage", "recordHeapDump", "optimizeRender", "streamReadAloudAudio",
        "pauseReadAloudWhilePhoneCalls", "readAloudByMediaButton", "showMangaUi", "disableMangaScale",
        "disableMangaPageAnim", "paddingDisplayCutouts", "autoCheckNewBackup", "showReadTitleAddition",
        "readBarStyleFollowPage", "bookInfoDeleteAlert",
    )
    private val longKeys = setOf("remoteServerId")
    private val nativeKeys = stringKeys + intKeys + booleanKeys + longKeys
    // BackupConfig.ignorePrefKeys: these values are not portable even between Android devices.
    private val excluded = setOf(
        "backupUri", "backup_path", "defaultBookTreeUri", "default_book_tree_uri", "webDavDeviceName",
        "defaultCover", "defaultCoverDark", "launcherIcon", "bitmapCacheSize", "webServiceWakeLock",
        "readAloudWakeLock", "audioPlayWakeLock", "backup_restore_ignored_keys", "reader_preset_name",
        "theme_preset_name", "page_animation", "pageAnim", "keep_screen_on",
        "reader_line_spacing_android_scale_migrated", "tts_voice_identifier", "bookshelf_layout_mode",
    )

    fun config(original: JsonObject, warnings: MutableList<String>): MutableMap<String, JsonElement> {
        val result = linkedMapOf<String, JsonElement>()
        // Raw Android values first; canonical KMP values win over stale aliases, including null removal.
        original.entries.sortedBy { if (('_' in it.key && it.key !in nativeKeys) || aliases[it.key] == it.key) 1 else 0 }
            .forEach { (key, value) ->
                if (key.startsWith("android.") || (key.startsWith("reader_") && key !in aliases) ||
                    key in excluded) return@forEach
                val target = aliases[key] ?: if (key in nativeKeys) key else camel(key)
                if (target in excluded) return@forEach
                if (value is JsonNull) {
                    result.remove(target)
                    return@forEach
                }
                val normalized = normalize(target, value)
                if (normalized != null) result[target] = normalized else {
                    warnings += "部分 iOS 专用或类型不兼容的偏好仅保留在 KMP metadata，未写入 Android config.xml。"
                }
            }
        original["theme_mode"]?.let { value ->
            result.remove("themeMode")
            val mode = (value as? JsonPrimitive)?.content
            val mapped = when (mode) {
                "SYSTEM", "0" -> "0"
                "LIGHT", "1" -> "1"
                "DARK", "2" -> "2"
                "E_INK", "3" -> "3"
                else -> null
            }
            mapped?.let { result["themeMode"] = JsonPrimitive(it) }
        }
        (original["bookshelf_layout_mode"] as? JsonPrimitive)?.content?.let { name ->
            BookshelfLayoutMode.entries.firstOrNull { it.name == name }?.let {
                result["bookshelfLayout"] = JsonPrimitive(it.legacyIndex)
            }
        }
        (result["defaultHomePage"] as? JsonPrimitive)?.content?.let { name ->
            result["defaultHomePage"] = JsonPrimitive(when (name) {
                "0", "bookshelf" -> "bookshelf"
                "1", "discovery", "explore" -> "explore"
                "2", "rss" -> "rss"
                "3", "settings", "person", "my" -> "my"
                else -> name
            })
        }
        return result
    }

    fun xmlType(key: String, value: JsonPrimitive): String = when {
        value.isString -> "string"
        value.booleanOrNull != null -> "boolean"
        key in longKeys -> "long"
        value.intOrNull != null -> "int"
        value.longOrNull != null -> "long"
        else -> "float"
    }

    /** Names whose literal PreferKey values differ from the iOS restore codec's camel-case aliases. */
    fun importConfig(original: JsonObject): JsonObject {
        val result = original.toMutableMap()
        val nativeToCanonical = mapOf(
            "auto_refresh" to "auto_refresh_book",
            "nightBrightness" to "brightness_night", "chineseConverterType" to "reader_chinese_mode",
            "ttsFollowSys" to "tts_follow_system_rate", "ttsTimer" to "tts_timer_minutes",
            "webDavCacheBackup" to "export_to_webdav", "Cronet" to "is_cronet", "antiAlias" to "use_anti_alias",
            "showReadTitleAddition" to "show_read_title_bar_addition",
            "transparentStatusBar" to "is_transparent_status_bar",
            "audioPlayWakeLock" to "audio_play_use_wake_lock",
            "clickActionTopLeft" to "tap_top_left", "clickActionTopCenter" to "tap_top_center",
            "clickActionTopRight" to "tap_top_right", "clickActionMiddleLeft" to "tap_middle_left",
            "clickActionMiddleCenter" to "tap_middle_center", "clickActionMiddleRight" to "tap_middle_right",
            "clickActionBottomLeft" to "tap_bottom_left", "clickActionBottomCenter" to "tap_bottom_center",
            "clickActionBottomRight" to "tap_bottom_right",
        )
        nativeToCanonical.forEach { (native, canonical) -> original[native]?.let { result[canonical] = it } }
        return JsonObject(result)
    }

    private fun normalize(key: String, value: JsonElement): JsonElement? {
        val primitive = value as? JsonPrimitive ?: return null
        return when {
            key in stringKeys -> JsonPrimitive(primitive.content)
            key in booleanKeys -> (primitive.booleanOrNull ?: when (primitive.content) {
                "1" -> true
                "0" -> false
                else -> null
            })?.let(::JsonPrimitive)
            key == "saveTabPosition" && primitive.booleanOrNull != null ->
                JsonPrimitive(if (primitive.booleanOrNull == true) 1 else 0)
            key in intKeys -> (primitive.intOrNull ?: primitive.doubleOrNull?.takeIf {
                it.isFinite() && it >= Int.MIN_VALUE && it <= Int.MAX_VALUE && it == it.toInt().toDouble()
            }?.toInt())?.let(::JsonPrimitive)
            key in longKeys -> primitive.longOrNull?.let(::JsonPrimitive)
            // Preserve unknown native keys without changing their spelling or inventing nested JSON strings.
            '_' !in key && '.' !in key && (primitive.isString || primitive.booleanOrNull != null ||
                primitive.longOrNull != null || primitive.floatOrNull?.isFinite() == true) -> primitive
            else -> null
        }
    }

    private fun camel(key: String): String = key.split('_').mapIndexed { index, part ->
        if (index == 0) part else part.replaceFirstChar { it.uppercase() }
    }.joinToString("")
}
