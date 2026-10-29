package io.legado.kmp.shared.facade

import io.legado.kmp.shared.model.BackupData
import io.legado.kmp.shared.preferences.AndroidBackupPreferences
import io.legado.kmp.shared.preferences.BackupRestoreIgnoreKeys
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

/** Holds decrypted, strictly decoded data only; never expose it through generated data-class APIs. */
internal class CloudBackupPayload(
    val payload: String,
    val summary: BackupRestoreResult,
    val warnings: List<String>,
)

/** All archive entries and recognized tables are checked before the first repository write. */
@OptIn(ExperimentalEncodingApi::class)
internal suspend fun decodeCloudBackup(
    bytes: ByteArray, password: String?, ignoredKeys: Set<String>,
): CloudBackupPayload {
    val context = currentCoroutineContext()
    val checkActive: () -> Unit = { context.ensureActive() }
    try {
        checkActive()
        require(bytes.isNotEmpty() && bytes.size <= WebDavBackupStore.MAX_ARCHIVE_BYTES)
        val converted = if (bytes.size >= 4 && bytes[0] == 0x50.toByte() && bytes[1] == 0x4b.toByte()) {
            val archive = BackupZipReader(bytes, BackupZipReader.Limits(
                maxArchiveBytes = WebDavBackupStore.MAX_ARCHIVE_BYTES,
                maxEntries = 1024,
                maxEntryBytes = 64 * 1024 * 1024,
                maxTotalBytes = 256 * 1024 * 1024,
                validateName = { name ->
                    // Android Backup.kt emits flat JSON/config entries, not file-system paths.
                    cloudBackupSegment(name)
                },
            ), checkActive = checkActive)
            val credentials = mutableMapOf<String, String>()
            archive.names().forEach { name ->
                checkActive()
                val content = archive.raw(name) ?: error("Missing ZIP entry")
                if (name == "servers.json" || name == "config.xml") {
                    credentials[name] = content.decodeToString(throwOnInvalidSequence = true)
                }
                checkActive()
            }
            validateCloudArchiveCredentials(credentials, password.orEmpty(), checkActive)
            checkActive()
            val encoded = Base64.encode(bytes)
            checkActive()
            AndroidBackupArchive().convert(encoded, password.orEmpty(), checkActive)
        } else {
            AndroidBackupImport(bytes.decodeToString(throwOnInvalidSequence = true).removePrefix("\uFEFF"), emptyList())
        }
        checkActive()
        val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
        val original = json.parseToJsonElement(converted.payload) as? JsonObject ?: error("Not a JSON object")
        checkActive()
        val root = BackupCredentialCodec().decode(original, password)
        checkActive()
        require(root.keys.any { it in CLOUD_BACKUP_TABLES || it == "preferences" })
        root.forEach { (key, value) ->
            checkActive()
            if (key in CLOUD_BACKUP_TABLES) {
                validateBackupRows(key, value as? JsonArray ?: error("Not an array"), checkActive)
            }
        }
        root["preferences"]?.let { require(it is JsonObject || it is JsonNull) }
        // Match SettingsBackupSupport's non-coercing model decode, including every preference/preset.
        val data = json.decodeFromJsonElement(BackupData.serializer(), root)
        checkActive()
        val summary = cloudBackupSummary(data, ignoredKeys, checkActive)
        val warnings = converted.warnings.toMutableList()
        warnings += "数量为参与恢复的备份记录数；已有记录会合并，不等于新增数量。"
        if (BackupRestoreIgnoreKeys.LOCAL_BOOK in ignoredKeys && summary.bookCount != data.bookshelf.size) {
            warnings += "已按恢复忽略项跳过本地书籍，书架数量不包含这些记录。"
        }
        if (data.preferences != null && ignoredKeys.isNotEmpty()) {
            warnings += "备份包含设置；设置仍按当前恢复忽略项选择性应用，不表示全部覆盖。"
            if (BackupRestoreIgnoreKeys.READ_CONFIG in ignoredKeys) {
                warnings += "阅读配置已设为忽略：保留当前阅读预设和阅读布局，其他未忽略设置仍会恢复。"
            }
        }
        checkActive()
        // Commit this exact validated model without retaining the backup password or decrypting again.
        // SettingsFacade still parses the canonical JSON, but it no longer decrypts untrusted input.
        val payload = json.encodeToString(BackupData.serializer(), data)
        checkActive()
        return CloudBackupPayload(payload, summary, warnings.toList())
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (error: RecoverableSharedException) {
        findFacadeRequestCancellation(error)?.let { throw it }
        checkActive()
        when (error.code) {
            "BACKUP_PASSWORD_REQUIRED", "BACKUP_DECRYPTION_FAILED", "UNSUPPORTED_BACKUP_ENCRYPTION",
            "INVALID_BACKUP_ENCRYPTION", "CLOUD_BACKUP_LIMIT" -> throw error
            else -> cloudBackupError("CLOUD_BACKUP_INVALID_ARCHIVE", "云端 ZIP 或旧版 JSON 备份无效，未恢复任何数据")
        }
    } catch (error: Exception) {
        findFacadeRequestCancellation(error)?.let { throw it }
        checkActive()
        cloudBackupError("CLOUD_BACKUP_INVALID_ARCHIVE", "云端 ZIP 或旧版 JSON 备份无效，未恢复任何数据")
    }
}

private fun validateCloudArchiveCredentials(
    entries: Map<String, String>, password: String, checkActive: () -> Unit,
) {
    try {
        checkActive()
        entries["servers.json"]?.let { content ->
            if (!content.trimStart().startsWith('[')) {
                val decrypted = AndroidBackupCipher.decrypt(content, password)
                checkActive()
                val rows = Json.parseToJsonElement(decrypted) as? JsonArray ?: error("Invalid servers")
                checkActive()
                validateBackupRows("servers", rows, checkActive)
            }
        }
        checkActive()
        val config = AndroidBackupPreferences.parse(entries.filterKeys { it == "config.xml" })?.appConfig
        checkActive()
        listOf("webDavPassword", "web_dav_password").forEach { key ->
            checkActive()
            (config?.get(key) as? JsonPrimitive)?.contentOrNull?.takeIf { it.isNotEmpty() }?.let {
                AndroidBackupCipher.decrypt(it, password)
                checkActive()
            }
        }
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (error: Exception) {
        findFacadeRequestCancellation(error)?.let { throw it }
        checkActive()
        // Unlike interactive Android import, cloud restore must not silently drop a bad credential
        // section and then replace the rest of a working account configuration.
        cloudBackupError("BACKUP_DECRYPTION_FAILED", "备份密码不正确或凭据数据已损坏，未恢复任何数据")
    }
}

private fun cloudBackupSummary(
    data: BackupData, ignoredKeys: Set<String>, checkActive: () -> Unit,
): BackupRestoreResult {
    val books = data.bookshelf.count {
        checkActive()
        BackupRestoreIgnoreKeys.LOCAL_BOOK !in ignoredKeys || !it.isLocal
    }
    val counts = listOf(books, data.bookSource.size, data.rssSource.size, data.replaceRule.size,
        data.bookGroup.size, data.bookmark.size, data.txtTocRule.size, data.dictRule.size, data.searchHistory.size,
        data.readRecord.size, data.rssStar.size, data.sourceSub.size, data.httpTTS.size,
        data.keyboardAssists.size, data.servers.size)
    if (counts.any { it > 100_000 } || counts.sumOf { it.toLong() } > 200_000L) {
        cloudBackupError("CLOUD_BACKUP_LIMIT", "备份记录超过恢复上限（单表十万条，总计二十万条），未恢复任何数据")
    }
    checkActive()
    return BackupRestoreResult(
        bookCount = books,
        bookSourceCount = data.bookSource.size,
        rssSourceCount = data.rssSource.size,
        replaceRuleCount = data.replaceRule.size,
        bookGroupCount = data.bookGroup.size,
        bookmarkCount = data.bookmark.size,
        txtTocRuleCount = data.txtTocRule.size,
        dictRuleCount = data.dictRule.size,
        searchHistoryCount = data.searchHistory.size,
        readRecordCount = data.readRecord.size,
        rssStarCount = data.rssStar.size,
        sourceSubCount = data.sourceSub.size,
        httpTTSCount = data.httpTTS.size,
        keyboardAssistCount = data.keyboardAssists.size,
        serverCount = data.servers.size,
        preferencesRestored = data.preferences != null,
    )
}

private val CLOUD_BACKUP_TABLES = setOf(
    "bookshelf", "bookSource", "rssSource", "replaceRule", "bookGroup", "bookmark", "txtTocRule",
    "dictRule", "searchHistory", "readRecord", "rssStar", "sourceSub", "httpTTS", "keyboardAssists", "servers",
)
