package io.legado.kmp.shared.domain.runtime

import kotlinx.serialization.Serializable

@Serializable
enum class FileDownloadStatus {
    QUEUED,
    DOWNLOADING,
    PAUSED,
    COMPLETED,
    FAILED,
    CANCELLED,
}

@Serializable
data class FileDownloadTask(
    val id: String,
    val url: String?,
    val fileName: String,
    val status: FileDownloadStatus,
    val bytesDownloaded: Long = 0,
    val totalBytes: Long? = null,
    val localPath: String? = null,
    val errorMessage: String? = null,
    val updatedAt: Long = 0,
) {
    val isActive: Boolean
        get() = status == FileDownloadStatus.QUEUED || status == FileDownloadStatus.DOWNLOADING

    val canPause: Boolean
        get() = isActive

    val canResume: Boolean
        get() = status == FileDownloadStatus.PAUSED

    val canRetry: Boolean
        get() = url != null && (status == FileDownloadStatus.FAILED || status == FileDownloadStatus.CANCELLED)
}

internal fun validateDownloadFileName(fileName: String): String {
    val name = fileName.trim()
    require(name.isNotEmpty() && !name.startsWith('.') && name.encodeToByteArray().size <= 180) {
        "文件名不能为空、以点开头或超过 180 字节"
    }
    require(name.none { it == '/' || it == '\\' || it == ':' || it.code < 32 || it.code == 127 }) {
        "文件名不能包含路径分隔符或控制字符"
    }
    return name
}
