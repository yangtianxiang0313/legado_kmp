package io.legado.kmp.shared.facade

import io.legado.kmp.shared.domain.localbook.RemoteBookDownloader
import io.legado.kmp.shared.domain.localbook.RemoteBookOrigin
import io.legado.kmp.shared.domain.localbook.archiveContainerName
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookType
import io.legado.kmp.shared.model.RemoteBook
import io.legado.kmp.shared.platform.AppFilesDirectory
import io.legado.kmp.shared.platform.DownloadFileStore
import io.legado.kmp.shared.platform.FileAccess
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import okio.ByteString.Companion.toByteString

class WebDavRemoteBookDownloader(
    private val settingsFacade: SettingsFacade,
    private val fileAccess: FileAccess,
    private val appFilesDirectory: AppFilesDirectory,
) : RemoteBookDownloader {

    override suspend fun download(book: Book): Book? =
        remoteBookOperation("RECOVERY_FAILED", "无法恢复远程书籍，请检查原服务器或重新下载；已有文件未被覆盖") {
            val context = currentCoroutineContext()
            context.ensureActive()
            if (book.archiveContainerName != null || book.type and BookType.ARCHIVE != 0) return@remoteBookOperation null
            val origin = RemoteBookOrigin.parse(book.origin) ?: return@remoteBookOperation null
            require(book.isLocal) { "只能恢复本地书籍" }
            val targetPath = recoveryTargetPath(book.bookUrl)
            if (fileAccess.exists(book.bookUrl)) return@remoteBookOperation book
            val access = settingsFacade.remoteBookAccessForOrigin(origin)
            val filename = book.originName.ifBlank { targetPath.substringAfterLast('/') }
            requireSingleRemoteBook(filename)
            requireSingleRemoteBook(origin.url.substringBefore('?'))
            val remoteBook = RemoteBook(filename, origin.url, 0, 0, filename.substringAfterLast('.', ""))
            val bytes = access.manager.downloadRemoteBook(remoteBook)
            context.ensureActive()
            validateRemoteBookBytes(bytes, targetPath) { context.ensureActive() }
            requireLocalBookDigest(targetPath, bytes)
            context.ensureActive()
            val store = DownloadFileStore()
            val temporary = stageRemoteBookBytes(store, bytes)
            try {
                val parent = targetPath.substringBeforeLast('/')
                require(fileAccess.createDirectory(parent)) { "无法创建书籍恢复目录" }
                context.ensureActive()
                withContext(NonCancellable) {
                    context.ensureActive()
                    if (fileAccess.exists(targetPath)) {
                        // A concurrent recovery may have published first. Never replace its file.
                        require(fileAccess.read(targetPath).contentEquals(bytes)) { "书籍恢复目标已被其他文件占用" }
                        return@withContext book
                    }
                    context.ensureActive()
                    require(fileAccess.move(temporary, targetPath)) { "书籍恢复目标已被占用或无法保存，未覆盖已有文件" }
                    // Preserve the original database key and every piece of user state.
                    book
                }
            } finally {
                try { store.removeTemporary(temporary) } catch (_: Exception) { }
            }
        }

    private fun recoveryTargetPath(bookUrl: String): String {
        // A database key is not a filename suggestion. Never recover to a different basename.
        require(bookUrl.startsWith('/') && bookUrl.split('/').drop(1).all { segment ->
            segment.isNotEmpty() && segment != "." && segment != ".." && segment.none { it == '\\' || it.code < 32 || it.code == 127 }
        }) { "书籍原本地身份无效，请重新导入" }
        val root = appFilesDirectory.path().trimEnd('/')
        val documents = root.removeSuffix("/Library/Application Support").takeIf { it != root }?.plus("/Documents/")
        fun identity(path: String): String = if (path.startsWith("/private/var/")) path.removePrefix("/private") else path
        val key = identity(bookUrl)
        if (key.startsWith(identity(root) + "/") || (documents != null && key.startsWith(identity(documents)))) return bookUrl

        // Mirror FileAccess's iOS sandbox rebinding without changing the stored database key.
        // Swift's content-addressed originals live in Application Support/LocalBooks, not Documents.
        if ("/Containers/Data/Application/" in bookUrl) {
            val localMarker = "/Library/Application Support/LocalBooks/"
            val local = bookUrl.substringAfter(localMarker, "")
            if (local.isNotBlank()) return "$root/LocalBooks/$local"
            val document = bookUrl.substringAfter("/Documents/", "")
            if (documents != null && document.isNotBlank()) return documents + document
        }
        throw RecoverableSharedException("REMOTE_BOOK_LOCAL_IDENTITY_INVALID", "书籍原本地位置已失效，请重新导入并关联来源")
    }

    private fun requireLocalBookDigest(path: String, bytes: ByteArray) {
        fun identity(value: String): String = if (value.startsWith("/private/var/")) value.removePrefix("/private") else value
        val root = appFilesDirectory.path().trimEnd('/') + "/LocalBooks/"
        val relative = identity(path).substringAfter(identity(root), "")
        if (relative.isEmpty()) return
        val parts = relative.split('/')
        require(parts.size == 2) { "本地书籍原件身份无效，未发布恢复文件" }
        val directory = parts[0]
        val hash = directory.substringAfter('-', "")
        val extension = directory.substringBefore('-')
        require(hash.length == 64 && hash.all { it in "0123456789abcdef" } &&
            extension == parts[1].substringAfterLast('.', "").lowercase()) { "本地书籍原件身份无效，未发布恢复文件" }
        if (bytes.toByteString().sha256().hex() != hash) throw RecoverableSharedException(
            "REMOTE_BOOK_CONTENT_CHANGED", "原服务器书籍内容已改变，未覆盖本地原件；请重新下载导入",
        )
    }
}
