package io.legado.kmp.shared.facade

import io.legado.kmp.shared.domain.localbook.BookArchiveZipReader
import io.legado.kmp.shared.domain.localbook.EpubArchive
import io.legado.kmp.shared.domain.localbook.EpubPackage
import io.legado.kmp.shared.domain.localbook.RemoteBookOrigin
import io.legado.kmp.shared.domain.localbook.requireRemoteBookWithinRoot
import io.legado.kmp.shared.domain.remote.RemoteBookManager
import io.legado.kmp.shared.domain.remote.RemoteBookWebDav
import io.legado.kmp.shared.model.RemoteBook
import io.legado.kmp.shared.network.HttpRequestConfig
import io.legado.kmp.shared.network.LegadoHttpClient
import io.legado.kmp.shared.network.WebDavClient
import io.legado.kmp.shared.platform.DownloadFileStore
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import okio.buffer
import okio.use
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi

/** Immutable account/root snapshot for legacy calls and origin-based recovery. */
internal class RemoteBookAccess(
    val serverID: Long,
    val root: String,
    private val username: String,
    private val password: String,
    webDavClient: WebDavClient,
) {
    private val delegate = RemoteBookWebDav(root, username, password, webDavClient, serverID)

    val manager: RemoteBookManager = object : RemoteBookManager() {
        override suspend fun getRemoteBookList(path: String): List<RemoteBook> =
            remoteBookOperation("LIST_FAILED", "无法读取远程书籍列表，请检查原服务器配置") {
                delegate.getRemoteBookList(requirePath(path)).mapNotNull { remote ->
                    try {
                        remote.copy(path = requirePath(remote.path))
                    } catch (_: Exception) {
                        null
                    }
                }
            }

        override suspend fun getRemoteBook(path: String): RemoteBook? {
            val target = requirePath(path)
            return getRemoteBookList(target).firstOrNull { it.path == target }
        }

        override suspend fun downloadRemoteBook(remoteBook: RemoteBook): ByteArray =
            remoteBookOperation("DOWNLOAD_FAILED", "无法下载远程书籍，请检查原服务器；已有文件未被覆盖") {
                download(remoteBook)
            }

        override suspend fun upload(fileName: String, fileBytes: ByteArray) {
            require(fileName.isNotBlank() && fileName.none { it in "/\\?#%" || it.code < 32 }) { "远程文件名无效" }
            requirePath(root + fileName)
            delegate.upload(fileName, fileBytes)
        }

        override suspend fun delete(remoteBookUrl: String) = delegate.delete(requirePath(remoteBookUrl))
    }

    fun requirePath(path: String): String = requireRemoteBookWithinRoot(path, root)
    fun origin(path: String): String = RemoteBookOrigin.create(requirePath(path), serverID).encoded

    @OptIn(ExperimentalEncodingApi::class)
    private suspend fun download(book: RemoteBook): ByteArray {
        require(!book.isDir) { "不能下载远程目录" }
        val path = requirePath(book.path)
        val client = LegadoHttpClient()
        try {
            currentCoroutineContext().ensureActive()
            // WebDavClient follows redirects. Reuse the existing no-redirect HTTP API for this GET
            // so even a same-host redirect outside the configured root cannot receive credentials.
            val response = client.execute(HttpRequestConfig(
                url = path,
                headers = mapOf("Authorization" to "Basic ${Base64.encode("$username:$password".encodeToByteArray())}"),
                followRedirects = false,
            ))
            currentCoroutineContext().ensureActive()
            require(response.statusCode == 200) { "远程书籍下载未返回完整文件" }
            requirePath(response.url)
            require(book.size <= 0 || book.size == response.body.size.toLong()) { "远程书籍长度已变化或下载不完整" }
            val declared = response.headers.entries.firstOrNull { it.key.equals("Content-Length", true) }
                ?.value?.toLongOrNull()
            val encoded = response.headers.entries.any { it.key.equals("Content-Encoding", true) && !it.value.equals("identity", true) }
            require(encoded || declared == null || declared == response.body.size.toLong()) { "远程书籍下载不完整" }
            val contentType = response.headers.entries.firstOrNull { it.key.equals("Content-Type", true) }?.value.orEmpty()
            require(!contentType.contains("text/html", true) && !contentType.contains("application/json", true) &&
                !contentType.contains("xml", true)) { "远程服务器返回的不是书籍文件" }
            return response.body
        } finally {
            client.close()
        }
    }
}

internal fun requireSingleRemoteBook(fileName: String, contentType: String = "") {
    if (fileName.substringAfterLast('.', "").lowercase() in setOf("zip", "rar", "7z") ||
        contentType.lowercase() in setOf("zip", "rar", "7z", "application/zip", "application/x-rar-compressed", "application/x-7z-compressed")
    ) throw RecoverableSharedException(
        "REMOTE_BOOK_ARCHIVE_REQUIRES_PLATFORM_IMPORT", "压缩包请使用新的平台多书导入流程，旧单书接口不能导入压缩包",
    )
}

/** Validate before publishing, including ZIP CRCs for EPUB; never turn an archive into an entry. */
internal fun validateRemoteBookBytes(bytes: ByteArray, fileName: String, checkActive: () -> Unit) {
    checkActive()
    require(bytes.isNotEmpty()) { "远程书籍文件为空" }
    val extension = fileName.substringAfterLast('.', "").lowercase()
    requireSingleRemoteBook(fileName)
    fun starts(vararg signature: Int): Boolean = bytes.size >= signature.size &&
        signature.indices.all { (bytes[it].toInt() and 255) == signature[it] }
    val zip = starts(0x50, 0x4b, 0x03, 0x04) || starts(0x50, 0x4b, 0x05, 0x06)
    if ((zip && extension != "epub") || starts(0x52, 0x61, 0x72, 0x21) || starts(0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c)) {
        throw RecoverableSharedException(
            "REMOTE_BOOK_ARCHIVE_REQUIRES_PLATFORM_IMPORT", "下载内容是压缩包，请使用新的平台多书导入流程",
        )
    }
    val head = bytes.decodeToString(0, minOf(1024, bytes.size)).trimStart('\uFEFF', ' ', '\r', '\n', '\t').lowercase()
    require(!head.startsWith("<!doctype html") && !head.startsWith("<html") && !head.startsWith("<?xml") &&
        !head.startsWith("<error") && !head.startsWith("{\"error\"")) { "远程服务器返回的不是书籍文件" }
    when (extension) {
        "epub" -> {
            require(zip) { "远程 EPUB 文件格式无效" }
            val archive = BookArchiveZipReader(bytes, checkActive)
            archive.entries().forEach { checkActive(); archive.read(it.path) }
            require(EpubPackage(EpubArchive(bytes, checkActive)).spinePaths().isNotEmpty()) { "远程 EPUB 目录无效" }
        }
        "pdf" -> require(head.startsWith("%pdf-") && bytes.decodeToString(maxOf(0, bytes.size - 1024), bytes.size).contains("%%EOF")) {
            "远程 PDF 文件无效或不完整"
        }
        "umd" -> require(starts(0x89, 0x9b, 0x9a, 0xde)) { "远程 UMD 文件格式无效" }
        "mobi", "azw", "azw3" -> require(bytes.size > 78 && bytes.decodeToString(60, 68) == "BOOKMOBI") {
            "远程 MOBI 文件格式无效"
        }
        "txt" -> require(bytes.any { it != 0.toByte() }) { "远程文本书籍内容无效" }
        else -> error("远程书籍格式不受支持")
    }
    checkActive()
}

/** Write exclusively to a disposable temporary file; commit is a separate cancellation boundary. */
internal suspend fun stageRemoteBookBytes(store: DownloadFileStore, bytes: ByteArray): String {
    val context = currentCoroutineContext()
    context.ensureActive()
    val temporary = store.createTemporaryPath()
    try {
        store.openSink(temporary).buffer().use { sink ->
            var offset = 0
            while (offset < bytes.size) {
                context.ensureActive()
                val count = minOf(64 * 1024, bytes.size - offset)
                sink.write(bytes, offset, count)
                offset += count
            }
        }
        context.ensureActive()
        return temporary
    } catch (error: Throwable) {
        try { store.removeTemporary(temporary) } catch (_: Exception) { }
        throw error
    }
}
