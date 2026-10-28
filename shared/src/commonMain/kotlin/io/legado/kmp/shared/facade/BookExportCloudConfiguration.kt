package io.legado.kmp.shared.facade

import io.legado.kmp.shared.preferences.AppRuntimeConfig

internal const val BOOK_EXPORT_CLOUD_MAX_BYTES = 128 * 1024 * 1024

internal fun bookExportCloudMatches(config: CloudBackupConfiguration, current: AppRuntimeConfig): Boolean =
    config.matches(current) && config.snapshot.exportToWebDav == current.exportToWebDav

internal fun bookExportCloudContentType(fileName: String, data: ByteArray): String {
    if (data.isEmpty() || data.size > BOOK_EXPORT_CLOUD_MAX_BYTES) {
        throw BookExportCloudFailure(BookExportCloudMessage.FILE_SIZE)
    }
    try {
        // This is a decoded filename, not an already encoded URL path; % and # are encoded exactly once below.
        if (fileName.isBlank() || fileName in setOf(".", "..") ||
            fileName.any { it.isISOControl() || it == '/' || it == '\\' } ||
            fileName.encodeToByteArray(throwOnInvalidSequence = true).size > 160 ||
            fileName != fileName.trim() || fileName.endsWith('.') ||
            fileName.substringBeforeLast('.', "").isBlank()
        ) throw BookExportCloudFailure(BookExportCloudMessage.FILE_NAME)
    } catch (_: Throwable) {
        throw BookExportCloudFailure(BookExportCloudMessage.FILE_NAME)
    }
    return when (fileName.substringAfterLast('.', "").lowercase()) {
        // Export settings may select a non-UTF-8 charset; do not invent a charset declaration.
        "txt" -> "text/plain"
        "zip" -> "application/zip"
        "epub" -> "application/epub+zip"
        else -> throw BookExportCloudFailure(BookExportCloudMessage.FILE_TYPE)
    }
}
