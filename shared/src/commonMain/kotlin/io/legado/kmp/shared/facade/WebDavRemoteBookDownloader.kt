package io.legado.kmp.shared.facade

import io.legado.kmp.shared.domain.localbook.RemoteBookDownloader
import io.legado.kmp.shared.domain.localbook.remoteUrl
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.RemoteBook
import io.legado.kmp.shared.platform.AppFilesDirectory
import io.legado.kmp.shared.platform.FileAccess

class WebDavRemoteBookDownloader(
    private val settingsFacade: SettingsFacade,
    private val fileAccess: FileAccess,
    private val appFilesDirectory: AppFilesDirectory,
) : RemoteBookDownloader {

    override suspend fun download(book: Book): Book? {
        val remotePath = book.remoteUrl ?: return null
        val manager = settingsFacade.getDefaultBookWebDav() ?: return null
        val remoteBook = manager.getRemoteBook(remotePath) ?: RemoteBook(
            filename = book.originName.ifBlank { remotePath.remoteFileName() },
            path = remotePath,
            size = 0L,
            lastModify = 0L,
            contentType = remotePath.substringAfterLast('.', ""),
        )
        if (remoteBook.isDir) return null

        val bytes = manager.downloadRemoteBook(remoteBook)
        val filename = remoteBook.filename.ifBlank { remotePath.remoteFileName() }.sanitizedFileName()
        val targetPath = recoverTargetPath(book.bookUrl, filename)
        val parent = targetPath.parentPath()
        if (parent.isNotBlank()) {
            fileAccess.createDirectory(parent)
        }
        if (!fileAccess.write(targetPath, bytes)) return null
        return book.copy(
            bookUrl = targetPath,
            originName = book.originName.ifBlank { filename },
        )
    }

    private fun recoverTargetPath(currentPath: String, filename: String): String {
        val normalized = currentPath.trim()
        if (normalized.isNotEmpty() && normalized.parentPath().isNotBlank()) {
            return normalized
        }
        return appFilesDirectory.path().trimEnd('/', '\\') + "/RemoteBooks/$filename"
    }
}

private fun String.remoteFileName(): String =
    trimEnd('/', '\\').substringAfterLast('/').substringAfterLast('\\').ifBlank { "remote-book.txt" }

private fun String.parentPath(): String =
    trimEnd('/', '\\').substringBeforeLast('/', missingDelimiterValue = "")

private fun String.sanitizedFileName(): String {
    val cleaned = map { char ->
        if (char in setOf('/', '\\', ':', '*', '?', '"', '<', '>', '|')) '_' else char
    }.joinToString("")
    return cleaned.ifBlank { "remote-book.txt" }
}
