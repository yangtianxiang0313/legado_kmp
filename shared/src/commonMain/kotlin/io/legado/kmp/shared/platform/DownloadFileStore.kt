package io.legado.kmp.shared.platform

import okio.Sink

internal data class DownloadedFile(
    val fileName: String,
    val path: String,
    val size: Long,
    val modifiedAt: Long,
)

internal expect class DownloadFileStore() {
    fun createTemporaryPath(): String
    fun openSink(path: String): Sink
    fun commit(temporaryPath: String, fileName: String): DownloadedFile
    fun removeTemporary(path: String)
    fun listCompleted(): List<DownloadedFile>
}
