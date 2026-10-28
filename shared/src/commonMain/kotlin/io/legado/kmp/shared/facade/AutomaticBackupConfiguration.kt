package io.legado.kmp.shared.facade

import io.legado.kmp.shared.preferences.AppRuntimeConfig
import kotlinx.datetime.Clock
import kotlinx.datetime.TimeZone
import kotlinx.datetime.toLocalDateTime
import okio.ByteString.Companion.encodeUtf8

/** An immutable authorization boundary, not a printable credential-bearing data class. */
class AutomaticBackupConfiguration internal constructor(internal val snapshot: AppRuntimeConfig) {
    val configuredPath: String? = snapshot.backupPath?.takeIf { it.isNotBlank() }
    val onlyLatest: Boolean = snapshot.onlyLatestBackup
    // Automatic work must not silently select CloudBackupConfiguration's default public server.
    val hasCloudDestination: Boolean = !snapshot.webDavUrl.isNullOrBlank() &&
        !snapshot.webDavAccount.isNullOrBlank() && !snapshot.webDavPassword.isNullOrBlank()
    val isConfigured: Boolean = configuredPath != null || hasCloudDestination
    val archiveName: String = run {
        val date = Clock.System.now().toLocalDateTime(TimeZone.currentSystemDefault()).date.toString()
        val device = snapshot.webDavDeviceName.orEmpty()
        // Backup.getNowZipFileName + String.normalizeFileName: preserve the configured name,
        // replace only Android's reserved file characters, and never silently truncate it.
        val name = "backup$date${if (device.isBlank()) "" else "-$device"}.zip"
            .map { if (it in "\\/:*?\"<>|") '_' else it }.joinToString("")
        // Existing DAV path policy rejects control/%/# and overlong names explicitly.
        cloudBackupName(name)
    }
    internal val cloud: CloudBackupConfiguration? = if (hasCloudDestination) CloudBackupConfiguration(snapshot) else null
    /** Bind remembered encryption passwords to the destination/account, never to a newly restored account. */
    val passwordScope: String = buildString {
        append("legado-automatic-password-v1\n")
        append(cloud?.scope ?: "local")
        append('\n').append(configuredPath.orEmpty().length).append(':').append(configuredPath.orEmpty())
    }.encodeUtf8().sha256().hex()
    /** Schedule/retention changes get their own retry state; no password or password digest is persisted. */
    val identifier: String = buildString {
        append("legado-automatic-backup-v1\n").append(passwordScope)
        append('\n').append(onlyLatest)
        append('\n').append(snapshot.webDavDeviceName.orEmpty().length).append(':').append(snapshot.webDavDeviceName.orEmpty())
        snapshot.backupRestoreIgnoredKeys.sorted().forEach { append('\n').append(it.length).append(':').append(it) }
    }.encodeUtf8().sha256().hex()

    fun matchesConfiguration(other: AutomaticBackupConfiguration): Boolean = matches(other.snapshot)

    internal fun matches(current: AppRuntimeConfig): Boolean =
        snapshot.backupPath == current.backupPath && snapshot.onlyLatestBackup == current.onlyLatestBackup &&
            snapshot.webDavUrl == current.webDavUrl && snapshot.webDavDir == current.webDavDir &&
            snapshot.webDavAccount == current.webDavAccount && snapshot.webDavPassword == current.webDavPassword &&
            snapshot.webDavDeviceName == current.webDavDeviceName &&
            snapshot.backupRestoreIgnoredKeys == current.backupRestoreIgnoredKeys
}
