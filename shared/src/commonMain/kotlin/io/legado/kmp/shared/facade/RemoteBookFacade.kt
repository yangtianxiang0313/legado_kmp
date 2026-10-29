package io.legado.kmp.shared.facade

import io.legado.kmp.shared.domain.repository.BookRepository
import io.legado.kmp.shared.domain.localbook.remoteBookOrigins
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.RemoteBook
import io.legado.kmp.shared.platform.AppFilesDirectory
import io.legado.kmp.shared.platform.DownloadFileStore
import io.legado.kmp.shared.platform.FileAccess
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

class RemoteBookFacade(
    private val settingsFacade: SettingsFacade,
    private val bookRepository: BookRepository,
    private val bookshelfFacade: BookshelfFacade,
    private val fileAccess: FileAccess? = null,
    private val appFilesDirectory: AppFilesDirectory? = null,
) {
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun list(path: String? = null): List<RemoteBook> =
        remoteBookOperation("LIST_FAILED", "无法读取远程书籍列表，请检查服务器配置") {
            val access = settingsFacade.currentRemoteBookAccess()
                ?: throw RecoverableSharedException("REMOTE_BOOK_SERVER_UNAVAILABLE", "远程书籍服务器未配置")
            val books = bookRepository.getAllBooks().filterNot { it.isNotShelf }
            val shelfUrls = books.map { it.bookUrl }.toSet()
            val origins = books.flatMap { it.remoteBookOrigins }.toSet()
            access.manager.getRemoteBookList(path ?: access.root).map { remoteBook ->
                remoteBook.copy(
                    isOnBookShelf = remoteBook.path in shelfUrls || origins.any {
                        it.url == remoteBook.path && (it.serverID == null || it.serverID == access.serverID)
                    },
                )
            }
        }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun download(remoteBook: RemoteBook): ByteArray =
        remoteBookOperation("DOWNLOAD_FAILED", "无法下载远程书籍，请检查原服务器配置") {
            require(!remoteBook.isDir) { "Cannot download a directory" }
            val access = settingsFacade.currentRemoteBookAccess()
                ?: throw RecoverableSharedException("REMOTE_BOOK_SERVER_UNAVAILABLE", "远程书籍服务器未配置")
            access.manager.downloadRemoteBook(remoteBook)
        }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun downloadAndImport(remoteBook: RemoteBook, groupId: Long = 0): Book =
        remoteBookOperation("IMPORT_FAILED", "远程书籍导入未完成，请重试；已有书籍未被覆盖") {
            val context = currentCoroutineContext()
            context.ensureActive()
            require(!remoteBook.isDir) { "Cannot download a directory" }
            requireSingleRemoteBook(remoteBook.filename, remoteBook.contentType)
            val access = settingsFacade.currentRemoteBookAccess()
                ?: throw RecoverableSharedException("REMOTE_BOOK_SERVER_UNAVAILABLE", "远程书籍服务器未配置")
            val remoteOrigin = access.origin(remoteBook.path)
            val bytes = access.manager.downloadRemoteBook(remoteBook)
            context.ensureActive()
            val filename = remoteBook.filename.sanitizedFileName()
            validateRemoteBookBytes(bytes, filename) { context.ensureActive() }
            val store = DownloadFileStore()
            val temporary = stageRemoteBookBytes(store, bytes)
            try {
                context.ensureActive()
                // Finish the original pipeline after publication; a late cancel cannot disguise a commit.
                withContext(NonCancellable) {
                    context.ensureActive()
                    val completed = store.commit(temporary, filename)
                    val imported = bookshelfFacade.importLocalBook(completed.path, groupId)
                    RemoteBookImportFacade(bookRepository).associateImportedBook(remoteOrigin, imported)
                }
            } finally {
                try { store.removeTemporary(temporary) } catch (_: Exception) { }
            }
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
