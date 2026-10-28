package io.legado.kmp.shared.facade

import io.legado.kmp.shared.domain.repository.BookRepository
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookType
import io.legado.kmp.shared.model.RemoteBook
import io.legado.kmp.shared.platform.AppFilesDirectory
import io.legado.kmp.shared.platform.FileAccess

class RemoteBookFacade(
    private val settingsFacade: SettingsFacade,
    private val bookRepository: BookRepository,
    private val bookshelfFacade: BookshelfFacade,
    private val fileAccess: FileAccess? = null,
    private val appFilesDirectory: AppFilesDirectory? = null,
) {
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun list(path: String? = null): List<RemoteBook> =
        runRecoverable("RemoteBookFacade.list") {
            val shelfKeys = bookRepository.getAllBooks()
                .map { it.bookUrl to it.origin }
                .toSet()
            settingsFacade.getRemoteBookList(path).map { remoteBook ->
                remoteBook.copy(
                    isOnBookShelf = shelfKeys.any { (bookUrl, origin) ->
                        bookUrl == remoteBook.path || origin == BookType.WEBDAV_TAG + remoteBook.path
                    }
                )
            }
        }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun download(remoteBook: RemoteBook): ByteArray =
        runRecoverable("RemoteBookFacade.download") {
            require(!remoteBook.isDir) { "Cannot download a directory" }
            settingsFacade.downloadRemoteBook(remoteBook)
        }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun downloadAndImport(remoteBook: RemoteBook, groupId: Long = 0): Book =
        runRecoverable("RemoteBookFacade.downloadAndImport") {
            require(!remoteBook.isDir) { "Cannot download a directory" }
            val access = requireNotNull(fileAccess) { "File access is unavailable" }
            val appDir = requireNotNull(appFilesDirectory) { "App files directory is unavailable" }
            val bytes = settingsFacade.downloadRemoteBook(remoteBook)
            val directory = appDir.path().trimEnd('/', '\\') + "/RemoteBooks"
            require(access.createDirectory(directory)) { "Failed to create remote book directory" }
            val targetPath = "$directory/${remoteBook.filename.sanitizedFileName()}"
            require(access.write(targetPath, bytes)) { "Failed to write remote book file" }
            val imported = bookshelfFacade.importLocalBook(targetPath, groupId).copy(
                origin = BookType.WEBDAV_TAG + remoteBook.path,
                originName = remoteBook.filename,
            )
            bookRepository.update(imported)
            imported
        }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun uploadLocalBook(path: String): RemoteBook =
        runRecoverable("RemoteBookFacade.uploadLocalBook") {
            val normalizedPath = path.trim()
            require(normalizedPath.isNotEmpty()) { "Local path is empty" }
            val access = requireNotNull(fileAccess) { "File access is unavailable" }
            val filename = normalizedPath.substringAfterLast('/').substringAfterLast('\\').sanitizedFileName()
            val bytes = access.read(normalizedPath)
            require(bytes.isNotEmpty()) { "Local book file is empty" }
            settingsFacade.uploadRemoteBook(filename, bytes)
            val uploaded = settingsFacade.getRemoteBookList()
                .firstOrNull { remoteBook -> !remoteBook.isDir && remoteBook.filename == filename }
            uploaded ?: RemoteBook(
                filename = filename,
                path = filename,
                size = bytes.size.toLong(),
                lastModify = 0L,
                contentType = filename.substringAfterLast('.', ""),
            )
        }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun uploadShelfBook(bookUrl: String): RemoteBook =
        runRecoverable("RemoteBookFacade.uploadShelfBook") {
            val book = requireNotNull(bookRepository.getBook(bookUrl)) { "Book not found: $bookUrl" }
            val access = requireNotNull(fileAccess) { "File access is unavailable" }
            val path = book.bookUrl.filePathFromBookUrl()
            require(path.isNotBlank()) { "Local path is empty" }
            require(access.exists(path)) { "Local book file does not exist: $path" }
            val filename = book.originName
                .ifBlank { book.name.ifBlank { path.substringAfterLast('/').substringAfterLast('\\') } }
                .sanitizedFileName()
            val bytes = access.read(path)
            require(bytes.isNotEmpty()) { "Local book file is empty" }
            settingsFacade.uploadBookToWebDav(book.copy(originName = filename), bytes)
            val uploaded = settingsFacade.getRemoteBookList()
                .firstOrNull { remoteBook -> !remoteBook.isDir && remoteBook.filename == filename }
            uploaded ?: RemoteBook(
                filename = filename,
                path = filename,
                size = bytes.size.toLong(),
                lastModify = 0L,
                contentType = filename.substringAfterLast('.', ""),
            )
        }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun delete(remoteBook: RemoteBook) {
        runRecoverable("RemoteBookFacade.delete") {
            settingsFacade.deleteRemoteBook(remoteBook.path)
        }
    }
}

private fun String.sanitizedFileName(): String {
    val cleaned = map { char ->
        if (char in setOf('/', '\\', ':', '*', '?', '"', '<', '>', '|')) '_' else char
    }.joinToString("")
    return cleaned.ifBlank { "remote-book.txt" }
}

private fun String.filePathFromBookUrl(): String {
    val trimmed = trim()
    return when {
        trimmed.startsWith("file://") -> trimmed.removePrefix("file://").decodePercentEscapes()
        else -> trimmed
    }
}

private fun String.decodePercentEscapes(): String {
    if ('%' !in this) return this
    val output = StringBuilder(length)
    var index = 0
    while (index < length) {
        if (this[index] == '%' && index + 2 < length) {
            val bytes = mutableListOf<Byte>()
            var scan = index
            while (scan + 2 < length && this[scan] == '%') {
                val value = substring(scan + 1, scan + 3).toIntOrNull(16) ?: break
                bytes += value.toByte()
                scan += 3
            }
            if (bytes.isNotEmpty()) {
                output.append(bytes.toByteArray().decodeToString())
                index = scan
                continue
            }
        }
        output.append(this[index])
        index += 1
    }
    return output.toString()
}
