package io.legado.kmp.shared.facade

import io.legado.kmp.shared.model.BackupData
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.*
import okio.utf8Size

data class AndroidBackupExport(val base64Zip: String, val warnings: List<String>)

/** Serializes the same 15 entity lists consumed by Android Restore.fileToListT. */
internal class AndroidBackupExporter {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val credentials = BackupCredentialCodec()

    fun fromPayload(payload: String, password: String?): AndroidBackupExport = guarded {
        require(payload.utf8Size() <= BackupZipWriter.MAX_ENTRY_BYTES) { "备份 JSON 超过 64 MB" }
        val original = json.parseToJsonElement(payload) as? JsonObject ?: error("备份必须为 JSON 对象")
        val root = credentials.decode(original, password)
        require(root.keys.any { it in AndroidBackupExportTables.files.values || it == "preferences" }) {
            "没有可导出的备份数据"
        }
        root.filterKeys { it in AndroidBackupExportTables.files.values }.forEach { (key, value) ->
            validateBackupRows(key, value as? JsonArray ?: error("备份表必须为数组"))
        }
        fromData(json.decodeFromJsonElement(BackupData.serializer(), root), password)
    }

    @OptIn(ExperimentalEncodingApi::class)
    fun fromData(data: BackupData, password: String?): AndroidBackupExport = guarded {
        val warnings = mutableListOf(
            "Android 备份不是整体加密：仅服务器列表与 WebDAV 密码按原生 BackupAES 加密，书源请求头、规则和变量仍为明文。",
            "KMP 扩展快照另存为 metadata；Android 不使用此文件，Android 重新备份后不会保留这些扩展。",
            "ZIP 不包含本地书原文件、字体、背景、封面或欢迎页图片，也不包含正文、Cookie 和独立脚本大变量缓存；资源需在目标设备另行导入。",
        )
        checkCounts(data)
        AndroidBackupExportBudget.check(data)
        // This also enforces the existing JSON backup policy: credentials require a nonblank password.
        val portable = credentials.encode(data, password)
        require(portable.utf8Size() <= BackupZipWriter.MAX_ENTRY_BYTES) { "KMP 扩展快照超过 64 MB" }
        val root = json.encodeToJsonElement(BackupData.serializer(), data).jsonObject
        val writer = BackupZipWriter()
        val digests = linkedMapOf<String, String>()
        try {
            fun put(file: String, text: String) {
                writer.text(file, text)
                digests[file] = AndroidBackupExportMetadata.digest(text)
            }
            AndroidBackupExportTables.files.forEach { (file, field) ->
                val rows = root.getValue(field).jsonArray
                validateBackupRows(field, rows)
                val native = AndroidBackupExportTables.exportRows(field, rows).toString()
                // Unlike Android Backup.kt, encryption failure never falls back to plaintext servers.
                put(file, if (file == "servers.json") AndroidBackupCipher.encrypt(native, password.orEmpty()) else native)
            }
            AndroidBackupPreferencesExport(warnings).files(data.preferences, password.orEmpty()).forEach { (file, text) ->
                put(file, text)
            }
            if (data.bookshelf.any { it.isLocal }) {
                warnings += "本地书仅导出书架记录和进度，不包含原书文件；Android 本地路径不可迁移，需重新导入原书。"
            }
            if (data.bookshelf.any { isDevicePath(it.coverUrl) || isDevicePath(it.customCoverUrl) } ||
                data.bookGroup.any { isDevicePath(it.cover) }) {
                warnings += "本地封面图片文件未迁移，书架和分组仅保留原封面引用；目标设备需重新选择图片。"
            }
            writer.text(AndroidBackupExportMetadata.FILE, AndroidBackupExportMetadata.encode(portable, digests))
            AndroidBackupExport(Base64.encode(writer.finish()), warnings.distinct())
        } finally {
            writer.clear()
        }
    }

    private fun checkCounts(data: BackupData) {
        val lists = listOf(data.bookshelf, data.bookmark, data.bookGroup, data.bookSource, data.rssSource,
            data.rssStar, data.replaceRule, data.readRecord, data.searchHistory, data.sourceSub,
            data.txtTocRule, data.httpTTS, data.keyboardAssists, data.dictRule, data.servers)
        require(lists.all { it.size <= 100_000 } && lists.sumOf { it.size.toLong() } <= 200_000L) {
            "备份记录超过导出上限（单表十万条，总计二十万条）"
        }
    }

    private fun isDevicePath(value: String?): Boolean = value != null && (
        value.startsWith('/') || value.startsWith("file:", true) || value.startsWith("content:", true))

    private inline fun guarded(block: () -> AndroidBackupExport): AndroidBackupExport = try {
        block()
    } catch (error: CancellationException) {
        throw error
    } catch (error: RecoverableSharedException) {
        throw error
    } catch (_: Exception) {
        // JSON/parser/crypto exceptions may contain snippets of credential-bearing input.
        throw RecoverableSharedException("ANDROID_BACKUP_EXPORT_FAILED", "Android 备份导出失败：数据格式无效、超过大小上限或凭据加密失败，未修改任何数据")
    }
}
