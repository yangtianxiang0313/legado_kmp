package io.legado.kmp.shared.facade

import io.legado.kmp.shared.model.BackupData
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.*
import okio.ByteString.Companion.encodeUtf8

/** Extra precision for KMP-to-KMP round trips; Android's native files remain independently usable. */
internal object AndroidBackupExportMetadata {
    const val FILE = "legado-kmp-metadata.json"
    private const val FORMAT = "legado-kmp-android-archive-v1"
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    fun digest(text: String): String = text.encodeUtf8().sha256().hex()

    fun encode(portable: String, digests: Map<String, String>): String = buildJsonObject {
        put("format", FORMAT)
        put("files", JsonObject(digests.mapValues { JsonPrimitive(it.value) }))
        put("snapshot", json.parseToJsonElement(portable))
    }.toString()

    fun restore(
        text: String?, nativeFiles: Map<String, String>, password: String, warnings: MutableList<String>,
    ): BackupData? {
        if (text == null) return null
        return try {
            val root = json.parseToJsonElement(text).jsonObject
            require(root["format"] == JsonPrimitive(FORMAT))
            val digests = root.getValue("files").jsonObject
            // Never let an old snapshot override edited, missing or additional recognized native files.
            require(digests.keys == nativeFiles.keys)
            require(digests.all { (file, value) -> value == JsonPrimitive(digest(nativeFiles.getValue(file))) })
            val snapshot = root.getValue("snapshot").jsonObject
            val decoded = BackupCredentialCodec().decode(snapshot, password)
            val result = json.decodeFromJsonElement(BackupData.serializer(), decoded)
            val encoded = json.encodeToJsonElement(BackupData.serializer(), result).jsonObject
            AndroidBackupExportTables.files.values.forEach { field ->
                validateBackupRows(field, encoded.getValue(field).jsonArray)
            }
            result
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            warnings += "KMP metadata 不匹配、损坏或密码不正确；已忽略扩展快照，仅使用 Android 原生文件恢复。"
            null
        }
    }
}
