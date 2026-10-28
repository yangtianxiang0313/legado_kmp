package io.legado.kmp.shared.facade

import io.legado.kmp.shared.model.BackupData
import io.legado.kmp.shared.preferences.AndroidBackupPreferences
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

internal data class CloudBackupPayload(val payload: String, val warnings: List<String>)

/** All archive entries and recognized tables are checked before the first repository write. */
@OptIn(ExperimentalEncodingApi::class)
internal suspend fun decodeCloudBackup(bytes: ByteArray, password: String?): CloudBackupPayload {
    try {
        currentCoroutineContext().ensureActive()
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
            ))
            val credentials = mutableMapOf<String, String>()
            archive.names().forEach { name ->
                currentCoroutineContext().ensureActive()
                val content = archive.raw(name) ?: error("Missing ZIP entry")
                if (name == "servers.json" || name == "config.xml") {
                    credentials[name] = content.decodeToString(throwOnInvalidSequence = true)
                }
            }
            validateCloudArchiveCredentials(credentials, password.orEmpty())
            val result = AndroidBackupArchive().convert(Base64.encode(bytes), password.orEmpty())
            CloudBackupPayload(result.payload, result.warnings)
        } else {
            CloudBackupPayload(bytes.decodeToString(throwOnInvalidSequence = true).removePrefix("\uFEFF"), emptyList())
        }
        currentCoroutineContext().ensureActive()
        val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
        val original = json.parseToJsonElement(converted.payload) as? JsonObject ?: error("Not a JSON object")
        val root = BackupCredentialCodec().decode(original, password)
        require(root.keys.any { it in CLOUD_BACKUP_TABLES || it == "preferences" })
        root.forEach { (key, value) ->
            if (key in CLOUD_BACKUP_TABLES) validateBackupRows(key, value as? JsonArray ?: error("Not an array"))
        }
        root["preferences"]?.let { require(it is JsonObject || it is JsonNull) }
        // Match SettingsBackupSupport's non-coercing model decode, including every preference/preset.
        json.decodeFromJsonElement(BackupData.serializer(), root)
        return converted
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (error: RecoverableSharedException) {
        when (error.code) {
            "BACKUP_PASSWORD_REQUIRED", "BACKUP_DECRYPTION_FAILED", "UNSUPPORTED_BACKUP_ENCRYPTION",
            "INVALID_BACKUP_ENCRYPTION" -> throw error
            else -> cloudBackupError("CLOUD_BACKUP_INVALID_ARCHIVE", "云端 ZIP 或旧版 JSON 备份无效，未恢复任何数据")
        }
    } catch (_: Exception) {
        cloudBackupError("CLOUD_BACKUP_INVALID_ARCHIVE", "云端 ZIP 或旧版 JSON 备份无效，未恢复任何数据")
    }
}

private fun validateCloudArchiveCredentials(entries: Map<String, String>, password: String) {
    try {
        entries["servers.json"]?.let { content ->
            if (!content.trimStart().startsWith('[')) {
                val decrypted = AndroidBackupCipher.decrypt(content, password)
                val rows = Json.parseToJsonElement(decrypted) as? JsonArray ?: error("Invalid servers")
                validateBackupRows("servers", rows)
            }
        }
        val config = AndroidBackupPreferences.parse(entries.filterKeys { it == "config.xml" })?.appConfig
        listOf("webDavPassword", "web_dav_password").forEach { key ->
            (config?.get(key) as? JsonPrimitive)?.contentOrNull?.takeIf { it.isNotEmpty() }?.let {
                AndroidBackupCipher.decrypt(it, password)
            }
        }
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (_: Exception) {
        // Unlike interactive Android import, cloud restore must not silently drop a bad credential
        // section and then replace the rest of a working account configuration.
        cloudBackupError("BACKUP_DECRYPTION_FAILED", "备份密码不正确或凭据数据已损坏，未恢复任何数据")
    }
}

private val CLOUD_BACKUP_TABLES = setOf(
    "bookshelf", "bookSource", "rssSource", "replaceRule", "bookGroup", "bookmark", "txtTocRule",
    "dictRule", "searchHistory", "readRecord", "rssStar", "sourceSub", "httpTTS", "keyboardAssists", "servers",
)
