package io.legado.kmp.shared.facade

import io.legado.kmp.shared.model.BackupData
import io.legado.kmp.shared.preferences.AndroidBackupPreferences
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.*

/** Result is validated before any row or preference is written. */
data class AndroidBackupImport(val payload: String, val warnings: List<String>)

/** Converts Android Legado's multi-file ZIP into the same restore model used by iOS backups. */
class AndroidBackupArchive {
    private val json = Json { ignoreUnknownKeys = true; coerceInputValues = true; encodeDefaults = true }

    /** Accepts existing plain/protected KMP JSON, while producing Android's native multi-file ZIP. */
    @Throws(RecoverableSharedException::class)
    fun export(payload: String, password: String? = null): AndroidBackupExport =
        AndroidBackupExporter().fromPayload(payload, password)

    internal fun exportData(data: BackupData, password: String?): AndroidBackupExport =
        AndroidBackupExporter().fromData(data, password)

    @OptIn(ExperimentalEncodingApi::class)
    @Throws(RecoverableSharedException::class)
    fun convert(base64Zip: String, password: String): AndroidBackupImport {
        try {
            require(base64Zip.length <= 180 * 1024 * 1024) { "备份 ZIP 超过 128 MB" }
            val archive = BackupZipReader(Base64.decode(base64Zip))
            val recognized = archive.names().intersect(tableFiles.keys + preferenceFiles)
            require(recognized.isNotEmpty()) { "ZIP 中没有找到 Android 阅读备份数据" }
            val warnings = mutableListOf<String>()
            val entries = recognized.associateWith { archive.text(it) ?: error("备份文件读取失败：$it") }.toMutableMap()
            val root = linkedMapOf<String, JsonElement>()
            tableFiles.forEach { (file, field) ->
                entries[file]?.let { original ->
                    val text = if (file == "servers.json" && !original.trimStart().startsWith('[')) {
                        try {
                            AndroidBackupCipher.decrypt(original, password).also { require(json.parseToJsonElement(it) is JsonArray) }
                        } catch (_: Exception) {
                            warnings += "服务器配置未恢复：备份密码不正确或加密数据已损坏。"
                            return@forEach
                        }
                    } else original
                    val rows = json.parseToJsonElement(text) as? JsonArray
                        ?: error("$file 必须包含 JSON 数组")
                    validateBackupRows(field, rows)
                    root[field] = AndroidBackupExportTables.importRows(field, rows)
                }
            }
            preferenceFiles.filter { it.endsWith(".json") }.forEach { file ->
                entries[file]?.let { text ->
                    val element = json.parseToJsonElement(text)
                    if (file in setOf("readConfig.json", "readBookConfig.json", "themeConfig.json")) {
                        require(element is JsonArray && element.all { it is JsonObject }) { "$file 必须是配置对象数组" }
                    } else require(element is JsonObject) { "$file 必须是 JSON 对象" }
                }
            }
            AndroidBackupPreferences.parse(entries)?.let { preferences ->
                val config = preferences.appConfig.toMutableMap()
                listOf("webDavPassword", "web_dav_password").forEach { key ->
                    (config[key] as? JsonPrimitive)?.contentOrNull?.takeIf { it.isNotEmpty() }?.let { encrypted ->
                        try {
                            config[key] = JsonPrimitive(AndroidBackupCipher.decrypt(encrypted, password))
                        } catch (_: Exception) {
                            config.remove(key)
                            warnings += "WebDAV 密码未恢复：备份密码不正确或密码数据未加密，请重新填写。"
                        }
                    }
                }
                root["preferences"] = json.encodeToJsonElement(preferences.copy(
                    appConfig = AndroidBackupExportPreferenceKeys.importConfig(JsonObject(config)),
                ))
            }
            require(root.isNotEmpty()) { "备份中没有可恢复的数据；请检查备份密码和文件内容" }
            // Deserialize all rows now, so malformed tables cannot cause a partial restore.
            val nativeData = json.decodeFromJsonElement(BackupData.serializer(), JsonObject(root))
            val metadata = try {
                archive.text(AndroidBackupExportMetadata.FILE)
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                warnings += "KMP metadata 无法读取；已忽略扩展快照，仅使用 Android 原生文件恢复。"
                null
            }
            val data = AndroidBackupExportMetadata.restore(metadata, entries, password, warnings) ?: nativeData
            val androidStyles = data.preferences?.appConfig?.get("android.readConfig") as? JsonArray
            if (androidStyles.orEmpty().any { element ->
                    val style = element as? JsonObject ?: return@any false
                    val font = (style["textFont"] as? JsonPrimitive)?.contentOrNull.orEmpty()
                    listOf("bgType", "bgTypeNight", "bgTypeEInk").any {
                        ((style[it] as? JsonPrimitive)?.intOrNull ?: 0) != 0
                    } || '/' in font || '\\' in font || font.endsWith(".ttf", true) || font.endsWith(".otf", true)
                }) {
                warnings += "Android 自定义字体和背景图片文件未包含在备份中，已使用系统字体与默认背景；需要在 iOS 重新选择。"
            }
            if (data.bookshelf.any { it.isLocal }) {
                warnings += "本地书籍仅恢复书架记录，Android 本地文件路径不会迁移；请重新导入原书文件，或在忽略项中跳过本地书籍。"
            }
            return AndroidBackupImport(json.encodeToString(BackupData.serializer(), data), warnings)
        } catch (error: CancellationException) {
            throw error
        } catch (error: RecoverableSharedException) {
            throw error
        } catch (_: Exception) {
            throw RecoverableSharedException("INVALID_ANDROID_BACKUP", "Android 备份无法读取：文件损坏、格式无效或超过大小上限")
        }
    }

    private companion object {
        val tableFiles = AndroidBackupExportTables.files
        val preferenceFiles = setOf("config.xml", "readConfig.json", "readBookConfig.json", "shareReadConfig.json",
            "themeConfig.json", "coverConfig.json", "coverRule.json", "directLinkUploadRule.json")
    }
}

internal fun validateBackupRows(field: String, rows: JsonArray) {
    val identity = when (field) {
        "bookshelf" -> "bookUrl"
        "bookSource" -> "bookSourceUrl"
        "rssSource" -> "sourceUrl"
        "rssStar" -> "link"
        "readRecord" -> "bookName"
        "searchHistory" -> "word"
        "sourceSub", "httpTTS" -> "url"
        "keyboardAssists" -> "key"
        "dictRule", "txtTocRule" -> "name"
        "bookmark" -> "bookName"
        "replaceRule" -> "pattern"
        "bookGroup" -> "groupId"
        "servers" -> "id"
        else -> error("未知的备份数据类型：$field")
    }
    rows.forEachIndexed { index, item ->
        val row = item as? JsonObject ?: error("$field 第 ${index + 1} 条不是 JSON 对象")
        require((row[identity] as? JsonPrimitive)?.contentOrNull?.isNotBlank() == true) {
            "$field 第 ${index + 1} 条缺少 $identity"
        }
    }
}
