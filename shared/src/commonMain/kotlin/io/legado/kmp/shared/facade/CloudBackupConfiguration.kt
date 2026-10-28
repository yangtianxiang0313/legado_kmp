package io.legado.kmp.shared.facade

import io.ktor.http.Url
import io.ktor.http.encodeURLPathPart
import io.legado.kmp.shared.preferences.AppRuntimeConfig
import kotlinx.datetime.Clock
import kotlinx.datetime.TimeZone
import kotlinx.datetime.toLocalDateTime
import okio.ByteString.Companion.encodeUtf8

/** Deliberately not a data class: credentials must never appear in toString or errors. */
internal class CloudBackupConfiguration(val snapshot: AppRuntimeConfig) {
    val account = snapshot.webDavAccount.orEmpty()
    val password = snapshot.webDavPassword.orEmpty()
    val root: String
    val origin: String
    val pathSegments: List<String>
    val scope: String

    init {
        if (account.isBlank() || password.isBlank()) {
            cloudBackupError("CLOUD_BACKUP_NOT_CONFIGURED", "请先填写 WebDAV 账号和密码")
        }
        if (':' in account || account.any { it.isISOControl() } || password.any { it.isISOControl() }) {
            cloudBackupError("CLOUD_BACKUP_INVALID_CONFIG", "WebDAV 账号或密码格式无效")
        }
        val raw = snapshot.webDavUrl?.trim().orEmpty().ifEmpty { DEFAULT_URL }
        val normalized = when {
            raw.startsWith("davs://", true) -> "https://" + raw.substring(7)
            raw.startsWith("dav://", true) -> "http://" + raw.substring(6)
            else -> raw
        }
        val parsed = cloudBackupUrl(normalized)
        origin = cloudBackupOrigin(parsed)
        val rootParts = cloudBackupPath(parsed.encodedPath)
        val directory = snapshot.webDavDir.trim().trim('/')
        val extra = if (directory.isEmpty()) emptyList() else directory.split('/').map(::cloudBackupSegment)
        pathSegments = rootParts + extra
        if (pathSegments.size > 64) invalidCloudPath()
        root = origin + "/" + pathSegments.joinToString("/") { it.encodeURLPathPart() } +
            if (pathSegments.isEmpty()) "" else "/"
        // Root, account and version only. Password rotation retains the same account's seen state.
        scope = ("legado-cloud-backup-v1\n$root\n${account.length}:$account").encodeUtf8().sha256().hex()
    }

    fun matches(current: AppRuntimeConfig): Boolean =
        snapshot.webDavUrl == current.webDavUrl && snapshot.webDavDir == current.webDavDir &&
            snapshot.webDavAccount == current.webDavAccount && snapshot.webDavPassword == current.webDavPassword &&
            snapshot.webDavDeviceName == current.webDavDeviceName &&
            snapshot.backupRestoreIgnoredKeys == current.backupRestoreIgnoredKeys

    fun fileUrl(name: String): String = root + cloudBackupName(name).encodeURLPathPart()

    fun backupName(): String {
        val date = Clock.System.now().toLocalDateTime(TimeZone.currentSystemDefault()).date.toString()
        val device = snapshot.webDavDeviceName?.trim().orEmpty().map {
            if (it.isISOControl() || it in "\\/:*?\"<>|%#") '_' else it
        }.joinToString("").take(120).trim().trim('.')
        // Android Backup.kt passes zipFileName to AppWebDav, not its local-only backupFileName.
        return cloudBackupName("backup$date${if (device.isEmpty()) "" else "-$device"}.zip")
    }

    companion object {
        const val DEFAULT_URL = "https://dav.jianguoyun.com/dav/"
    }
}

internal fun cloudBackupUrl(raw: String): Url {
    if (raw.length > 8192 || raw.any { it.isISOControl() || it == '\\' } || '?' in raw || '#' in raw ||
        !(raw.startsWith("https://", true) || raw.startsWith("http://", true))) {
        cloudBackupError("CLOUD_BACKUP_INVALID_PATH", "WebDAV 地址或备份路径无效")
    }
    // Validate before URL parsing can normalize dot segments or repeated slashes away.
    val authority = raw.substringAfter("://").substringBefore('/')
    if ('@' in authority || authority.isBlank()) invalidCloudPath()
    val rawPath = raw.substringAfter("://").substringAfter('/', "")
    cloudBackupPath("/$rawPath")
    val parsed = try { Url(raw) } catch (_: Exception) { invalidCloudPath() }
    if (parsed.protocol.name !in listOf("http", "https") || parsed.host.isBlank() ||
        !parsed.user.isNullOrEmpty() || !parsed.password.isNullOrEmpty()) invalidCloudPath()
    return parsed
}

internal fun cloudBackupOrigin(url: Url): String {
    val host = if (':' in url.host && !url.host.startsWith('[')) "[${url.host}]" else url.host
    val port = if (url.port == url.protocol.defaultPort) "" else ":${url.port}"
    return "${url.protocol.name.lowercase()}://${host.lowercase()}$port"
}

internal fun cloudBackupPath(path: String): List<String> {
    if ("//" in path) invalidCloudPath()
    val inner = path.removePrefix("/").removeSuffix("/")
    if (inner.isEmpty()) return emptyList()
    return inner.split('/').map { encoded ->
        val bytes = mutableListOf<Byte>()
        var cursor = 0
        while (cursor < encoded.length) {
            if (encoded[cursor] == '%') {
                if (cursor + 2 >= encoded.length) invalidCloudPath()
                val value = encoded.substring(cursor + 1, cursor + 3).toIntOrNull(16) ?: invalidCloudPath()
                bytes += value.toByte()
                cursor += 3
            } else {
                val next = encoded.indexOf('%', cursor).takeIf { it >= 0 } ?: encoded.length
                bytes.addAll(encoded.substring(cursor, next).encodeToByteArray().toList())
                cursor = next
            }
        }
        val segment = try { bytes.toByteArray().decodeToString(throwOnInvalidSequence = true) }
        catch (_: Exception) { invalidCloudPath() }
        cloudBackupSegment(segment)
    }
}

internal fun cloudBackupSegment(name: String): String {
    if (name.isBlank() || name == "." || name == ".." || name.length > 255 ||
        name.any { it.isISOControl() || it in "/\\%?#" }) invalidCloudPath()
    return name
}

internal fun cloudBackupName(name: String): String {
    cloudBackupSegment(name)
    if (!name.startsWith("backup", true) ||
        !(name.endsWith(".zip", true) || name.endsWith(".json", true))) {
        cloudBackupError("CLOUD_BACKUP_INVALID_NAME", "请选择有效的 backup ZIP 或旧版 JSON 备份")
    }
    return name
}

private fun invalidCloudPath(): Nothing =
    cloudBackupError("CLOUD_BACKUP_INVALID_PATH", "WebDAV 地址或备份路径无效")
