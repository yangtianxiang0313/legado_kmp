@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.legado.kmp.shared.platform

import io.legado.kmp.shared.domain.runtime.validateDownloadFileName
import okio.FileSystem
import okio.Path.Companion.toPath
import okio.Sink
import platform.Foundation.NSDate
import platform.Foundation.NSDocumentDirectory
import platform.Foundation.NSFileManager
import platform.Foundation.NSFileModificationDate
import platform.Foundation.NSFileSize
import platform.Foundation.NSFileType
import platform.Foundation.NSFileTypeDirectory
import platform.Foundation.NSFileTypeRegular
import platform.Foundation.NSNumber
import platform.Foundation.NSTemporaryDirectory
import platform.Foundation.NSUUID
import platform.Foundation.NSUserDomainMask
import platform.Foundation.timeIntervalSince1970

internal actual class DownloadFileStore actual constructor() {
    private val manager: NSFileManager get() = NSFileManager.defaultManager

    actual fun createTemporaryPath(): String =
        "${NSTemporaryDirectory().trimEnd('/')}/legado-download-${NSUUID().UUIDString}.part"

    actual fun openSink(path: String): Sink = FileSystem.SYSTEM.sink(path.toPath(), mustCreate = true)

    actual fun commit(temporaryPath: String, fileName: String): DownloadedFile {
        val name = validateDownloadFileName(fileName)
        val directory = directory()
        val dot = name.lastIndexOf('.').takeIf { it > 0 } ?: name.length
        val stem = name.substring(0, dot)
        val extension = name.substring(dot)
        for (suffix in 0..9999) {
            val candidate = if (suffix == 0) name else "$stem ($suffix)$extension"
            val destination = "$directory/$candidate"
            if (manager.fileExistsAtPath(destination)) continue
            // NSFileManager move refuses existing destinations, including a collision after the check.
            if (manager.moveItemAtPath(temporaryPath, destination, null)) {
                return requireNotNull(file(destination, candidate)) { "无法读取已下载文件" }
            }
            if (!manager.fileExistsAtPath(destination)) error("下载完成，但保存文件失败，请检查存储空间")
        }
        error("同名文件过多，请更换文件名")
    }

    actual fun removeTemporary(path: String) {
        manager.removeItemAtPath(path, null)
    }

    actual fun listCompleted(): List<DownloadedFile> {
        val directory = directory()
        val entries = manager.contentsOfDirectoryAtPath(directory, null) ?: error("无法读取下载目录")
        return entries.mapNotNull { entry ->
            val name = entry as? String ?: return@mapNotNull null
            if (name.startsWith('.') || '/' in name) return@mapNotNull null
            file("$directory/$name", name)
        }.sortedByDescending { it.modifiedAt }
    }

    private fun directory(): String {
        val documents = manager.URLForDirectory(
            directory = NSDocumentDirectory,
            inDomain = NSUserDomainMask,
            appropriateForURL = null,
            create = true,
            error = null,
        )?.path ?: error("无法访问文稿目录")
        val path = "$documents/Downloads"
        if (!manager.fileExistsAtPath(path)) {
            check(manager.createDirectoryAtPath(path, true, null, null)) { "无法创建下载目录" }
        }
        val attributes = manager.attributesOfItemAtPath(path, null)
        check(attributes?.get(NSFileType) == NSFileTypeDirectory) { "下载目录不是有效文件夹" }
        return path
    }

    private fun file(path: String, name: String): DownloadedFile? {
        val attributes = manager.attributesOfItemAtPath(path, null) ?: return null
        if (attributes[NSFileType] != NSFileTypeRegular) return null
        return DownloadedFile(
            fileName = name,
            path = path,
            size = (attributes[NSFileSize] as? NSNumber)?.longLongValue ?: 0,
            modifiedAt = (attributes[NSFileModificationDate] as? NSDate)
                ?.timeIntervalSince1970?.times(1000)?.toLong() ?: 0,
        )
    }
}
