package io.legado.kmp.shared.facade

import io.legado.kmp.shared.domain.repository.BookRepository
import io.legado.kmp.shared.domain.remote.RemoteBookManager
import io.legado.kmp.shared.domain.remote.RemoteBookWebDav
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.Server
import io.legado.kmp.shared.domain.repository.ServerRepository
import io.legado.kmp.shared.model.BookProgress
import io.legado.kmp.shared.model.RemoteBook
import io.legado.kmp.shared.network.WebDavClient
import io.legado.kmp.shared.preferences.AppPreferencesStore
import io.legado.kmp.shared.util.currentTimeMillis
import kotlinx.datetime.Clock
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

open class SettingsWebDavSupport(
    private val preferencesStore: AppPreferencesStore,
    private val bookRepository: BookRepository?,
    private val serverRepository: ServerRepository? = null,
) {
    // MARK: - WebDAV Operations

    private val webDavClient = WebDavClient()
    private val progressJson = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val readerProgressCloud by lazy { ReaderProgressCloudSupport(preferencesStore, bookRepository) }

    companion object {
        /** W-10: Default WebDAV URL for jianguoyun (坚果云). Mirrors legado AppWebDav.defaultWebDavUrl. */
        const val DEFAULT_WEBDAV_URL = "https://dav.jianguoyun.com/dav/"
    }

    private suspend fun getWebDavConfig(): Triple<String, String, String>? {
        val config = preferencesStore.runtimeConfig.first()
        val url = config.webDavUrl?.takeIf { it.isNotBlank() } ?: return null
        val account = config.webDavAccount?.takeIf { it.isNotBlank() } ?: return null
        val password = config.webDavPassword?.takeIf { it.isNotBlank() } ?: return null
        return Triple(url, account, password)
    }

    /**
     * W-10: Get the root WebDAV URL, applying jianguoyun default if user URL is empty.
     * Mirrors legado AppWebDav.rootWebDavUrl property.
     */
    private suspend fun getRootWebDavUrl(): String? {
        val config = preferencesStore.runtimeConfig.first()
        val configUrl = config.webDavUrl?.trim()
        // If no account/password configured, WebDAV is not usable
        val account = config.webDavAccount?.takeIf { it.isNotBlank() } ?: return null
        val password = config.webDavPassword?.takeIf { it.isNotBlank() } ?: return null
        var url = if (configUrl.isNullOrEmpty()) DEFAULT_WEBDAV_URL else configUrl
        if (!url.endsWith("/")) url += "/"
        config.webDavDir.trim().takeIf { it.isNotEmpty() }?.let {
            url = "$url$it/"
        }
        return url
    }

    /**
     * W-10: Check whether current WebDAV URL is jianguoyun (坚果云).
     * Mirrors legado AppWebDav.isJianGuoYun.
     */
    suspend fun isJianGuoYun(): Boolean {
        return try {
            val root = getRootWebDavUrl() ?: return false
            root.startsWith(DEFAULT_WEBDAV_URL, ignoreCase = true)
        } catch (e: kotlin.coroutines.cancellation.CancellationException) {
            throw e
        } catch (e: Throwable) {
            CrashCollector.record("SettingsFacade", "isJianGuoYun", error = e)
            false
        }
    }

    private suspend fun getProgressUrl(name: String, author: String): String? {
        val root = getRootWebDavUrl() ?: return null
        val fileName = "${name}_${author}".replace(Regex("[\\\\/:*?\"<>|]"), "_") + ".json"
        return "${root}bookProgress/$fileName"
    }

    suspend fun isWebDavConfigured(): Boolean {
        return try {
            getWebDavConfig() != null
        } catch (e: kotlin.coroutines.cancellation.CancellationException) {
            throw e
        } catch (e: Throwable) {
            CrashCollector.record("SettingsFacade", "isWebDavConfigured", error = e)
            false
        }
    }

    suspend fun checkWebDavConnection(): Boolean {
        return try {
            val (url, account, password) = getWebDavConfig() ?: return false
            webDavClient.check(url, account, password)
        } catch (e: kotlin.coroutines.cancellation.CancellationException) {
            throw e
        } catch (e: Throwable) {
            CrashCollector.record("SettingsFacade", "checkWebDavConnection", error = e)
            false
        }
    }

    suspend fun initWebDavDirs(): Boolean {
        return try {
            val root = getRootWebDavUrl() ?: return false
            val (_, account, password) = getWebDavConfig() ?: return false
            webDavClient.makeDir(root, account, password)
            webDavClient.makeDir("${root}bookProgress/", account, password)
            webDavClient.makeDir("${root}books/", account, password)
            true
        } catch (e: kotlin.coroutines.cancellation.CancellationException) {
            throw e
        } catch (e: Throwable) {
            CrashCollector.record("SettingsFacade", "initWebDavDirs", error = e)
            false
        }
    }

    /**
     * W-01: Check whether any WebDAV backup exists.
     * Mirrors legado AppWebDav.hasBackUp().
     */
    suspend fun hasBackUp(): Boolean {
        val root = getRootWebDavUrl() ?: return false
        val (_, account, password) = getWebDavConfig() ?: return false
        return try {
            val files = webDavClient.listFiles(root, account, password)
            files.any { it.displayName.startsWith("backup") }
        } catch (e: kotlin.coroutines.cancellation.CancellationException) {
            throw e
        } catch (e: Throwable) {
            CrashCollector.record("SettingsFacade", "hasBackUp", error = e)
            false
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun uploadBookProgress(book: Book) {
        runRecoverable("SettingsFacade.uploadBookProgress") {
            readerProgressCloud.upload(book)
        }
    }

    /**
     * W-06: Upload book progress using a BookProgress object directly.
     * Overload that accepts a pre-constructed BookProgress instead of a Book.
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun uploadBookProgress(progress: BookProgress) {
        runRecoverable("SettingsFacade.uploadBookProgress") {
            readerProgressCloud.upload(progress)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun getBookProgress(bookName: String, bookAuthor: String): BookProgress? {
        return runRecoverable("SettingsFacade.getBookProgress") {
            readerProgressCloud.read(bookName, bookAuthor)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun syncReaderBookProgress(book: Book): SyncProgressResult =
        runRecoverable("SettingsFacade.syncReaderBookProgress") { readerProgressCloud.sync(book) }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun uploadBookToWebDav(book: Book, fileBytes: ByteArray) {
        runRecoverable("SettingsFacade.uploadBookToWebDav") {
            val root = getRootWebDavUrl()
                ?: throw RecoverableSharedException("WEBDAV_NOT_CONFIGURED", "WebDAV not configured")
            val (_, account, password) = getWebDavConfig()
                ?: throw RecoverableSharedException("WEBDAV_NOT_CONFIGURED", "WebDAV not configured")
            val fileName = book.originName.ifBlank { "${book.name}.txt" }
            val putUrl = "${root}books/$fileName"
            webDavClient.upload(putUrl, account, password, fileBytes)
        }
    }

    /**
     * W-04/W-05: Upload a file to WebDAV books directory using a file path.
     * The platform layer reads the file bytes and passes them here.
     * This overload accepts a custom file name for the upload target.
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun uploadFileToWebDav(fileName: String, fileBytes: ByteArray, subDir: String = "books") {
        runRecoverable("SettingsFacade.uploadFileToWebDav") {
            val root = getRootWebDavUrl()
                ?: throw RecoverableSharedException("WEBDAV_NOT_CONFIGURED", "WebDAV not configured")
            val (_, account, password) = getWebDavConfig()
                ?: throw RecoverableSharedException("WEBDAV_NOT_CONFIGURED", "WebDAV not configured")
            val putUrl = "$root$subDir/$fileName"
            webDavClient.upload(putUrl, account, password, fileBytes)
        }
    }

    /**
     * W-02: Get the last backup file info from WebDAV.
     * Mirrors legado AppWebDav.lastBackUp(): finds the most recent backup file
     * by comparing lastModify timestamps.
     *
     * @return Pair of (displayName, lastModifyTimestamp) or null if no backup found
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun lastBackUp(): Pair<String, Long>? {
        return runRecoverable("SettingsFacade.lastBackUp") {
            val root = getRootWebDavUrl() ?: return@runRecoverable null
            val (_, account, password) = getWebDavConfig() ?: return@runRecoverable null
            try {
                val files = webDavClient.listFiles(root, account, password)
                var lastBackupName: String? = null
                var lastBackupTime: Long = 0
                for (file in files) {
                    if (file.displayName.startsWith("backup")) {
                        if (lastBackupName == null || file.lastModify > lastBackupTime) {
                            lastBackupName = file.displayName
                            lastBackupTime = file.lastModify
                        }
                    }
                }
                if (lastBackupName != null) Pair(lastBackupName, lastBackupTime) else null
            } catch (_: Exception) {
                null
            }
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun backupToWebDav(backupJson: String) {
        runRecoverable("SettingsFacade.backupToWebDav") {
            val root = getRootWebDavUrl()
                ?: throw RecoverableSharedException("WEBDAV_NOT_CONFIGURED", "WebDAV not configured")
            val (_, account, password) = getWebDavConfig()
                ?: throw RecoverableSharedException("WEBDAV_NOT_CONFIGURED", "WebDAV not configured")
            val deviceName = preferencesStore.runtimeConfig.first().webDavDeviceName ?: "legado"
            val timestamp = Clock.System.now().toEpochMilliseconds()
            val fileName = "backup${deviceName}_$timestamp.json"
            webDavClient.upload("$root$fileName", account, password, backupJson.encodeToByteArray(), "application/json")
        }
    }

    suspend fun getWebDavBackupNames(): List<String> {
        val root = getRootWebDavUrl() ?: return emptyList()
        val (_, account, password) = getWebDavConfig() ?: return emptyList()
        return try {
            webDavClient.listFiles(root, account, password)
                .filter { it.displayName.startsWith("backup") }
                .sortedByDescending { it.lastModify }
                .map { it.displayName }
        } catch (e: kotlin.coroutines.cancellation.CancellationException) {
            throw e
        } catch (e: Throwable) {
            CrashCollector.record("SettingsFacade", "getWebDavBackupNames", error = e)
            emptyList()
        }
    }

    suspend fun restoreFromWebDav(name: String): String? {
        val root = getRootWebDavUrl() ?: return null
        val (_, account, password) = getWebDavConfig() ?: return null
        return try {
            val bytes = webDavClient.download("$root$name", account, password)
            bytes.decodeToString()
        } catch (e: kotlin.coroutines.cancellation.CancellationException) {
            throw e
        } catch (e: Throwable) {
            CrashCollector.record("SettingsFacade", "restoreFromWebDav", mapOf("name" to name), e)
            null
        }
    }

    // MARK: - Download All Book Progress (W-03)

    /**
     * Download all book progress from WebDAV and update local books whose remote progress
     * is ahead of the local progress. Mirrors legado AppWebDav.downloadAllBookProgress().
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun downloadAllBookProgress() {
        runRecoverable("SettingsFacade.downloadAllBookProgress") {
            val (_, account, password) = getWebDavConfig() ?: return@runRecoverable
            val root = getRootWebDavUrl() ?: return@runRecoverable
            val repo = bookRepository ?: return@runRecoverable
            val progressDir = "${root}bookProgress/"
            val progressFiles = try {
                webDavClient.listFiles(progressDir, account, password)
            } catch (cancelled: kotlin.coroutines.cancellation.CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                return@runRecoverable
            }
            val fileMap = hashMapOf<String, io.legado.kmp.shared.network.WebDavFile>()
            progressFiles.forEach { fileMap[it.displayName] = it }

            val allBooks = repo.getAllBooks()
            for (book in allBooks) {
                val progressFileName = buildProgressFileName(book.name, book.author)
                val webDavFile = fileMap[progressFileName] ?: continue
                if (webDavFile.lastModify <= book.syncTime) {
                    continue
                }
                val bookProgress = getBookProgress(book.name, book.author) ?: continue
                if (bookProgress.durChapterIndex > book.durChapterIndex
                    || (bookProgress.durChapterIndex == book.durChapterIndex
                            && bookProgress.durChapterPos > book.durChapterPos)
                ) {
                    val updated = book.copy(
                        durChapterIndex = bookProgress.durChapterIndex,
                        durChapterPos = bookProgress.durChapterPos,
                        durChapterTitle = bookProgress.durChapterTitle,
                        durChapterTime = bookProgress.durChapterTime,
                        syncTime = currentTimeMillis()
                    )
                    // A settings sync must not replace metadata or progress saved while GET was pending.
                    kotlinx.coroutines.currentCoroutineContext().ensureActive()
                    repo.updateReadingProgressIfUnchanged(book, updated)
                }
            }
        }
    }

    private fun buildProgressFileName(name: String, author: String): String {
        return "${name}_${author}".replace(Regex("[\\\\/:*?\"<>|]"), "_") + ".json"
    }

    // MARK: - WC-05/WC-06: WebDAV file operations

    /**
     * WC-05/WC-06: Get metadata for a specific WebDAV file by URL.
     * Uses PROPFIND with Depth:0 to retrieve file info.
     * copy() and move() are already available on WebDavClient (WC-03/WC-04).
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun getWebDavFile(fileUrl: String): io.legado.kmp.shared.network.WebDavFile? {
        return runRecoverable("SettingsFacade.getWebDavFile") {
            val (_, account, password) = getWebDavConfig()
                ?: throw RecoverableSharedException("WEBDAV_NOT_CONFIGURED", "WebDAV not configured")
            try {
                // listFiles with Depth:1 returns children; use the parent to find the specific file
                val parentUrl = fileUrl.trimEnd('/').substringBeforeLast('/') + "/"
                val files = webDavClient.listFiles(parentUrl, account, password)
                val normalizedTarget = fileUrl.trimEnd('/')
                files.firstOrNull {
                    it.path.trimEnd('/') == normalizedTarget
                }
            } catch (_: Exception) {
                null
            }
        }
    }

    /**
     * WC-05: Copy a WebDAV resource. Delegates to WebDavClient.copy().
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun copyWebDavFile(fromUrl: String, toUrl: String, overwrite: Boolean = true): Boolean {
        return runRecoverable("SettingsFacade.copyWebDavFile") {
            val (_, account, password) = getWebDavConfig()
                ?: throw RecoverableSharedException("WEBDAV_NOT_CONFIGURED", "WebDAV not configured")
            webDavClient.copy(fromUrl, toUrl, account, password, overwrite)
        }
    }

    /**
     * WC-06: Move a WebDAV resource. Delegates to WebDavClient.move().
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun moveWebDavFile(fromUrl: String, toUrl: String, overwrite: Boolean = true): Boolean {
        return runRecoverable("SettingsFacade.moveWebDavFile") {
            val (_, account, password) = getWebDavConfig()
                ?: throw RecoverableSharedException("WEBDAV_NOT_CONFIGURED", "WebDAV not configured")
            webDavClient.move(fromUrl, toUrl, account, password, overwrite)
        }
    }

    // MARK: - Remote Book Management (W-08, RB-01..RB-06)

    /**
     * Create a default RemoteBookWebDav instance based on current WebDAV configuration.
     * Returns null if WebDAV is not configured.
     */
    suspend fun getDefaultBookWebDav(): RemoteBookManager? {
        return try {
            val config = preferencesStore.runtimeConfig.first()
            if (config.remoteServerId > 0) {
                val selected = serverRepository?.get(config.remoteServerId) ?: return null
                val selectedConfig = selected.config?.let {
                    progressJson.decodeFromString(Server.WebDavConfig.serializer(), it)
                } ?: return null
                if (selectedConfig.url.isBlank()) return null
                val manager = RemoteBookWebDav(
                    rootBookUrl = selectedConfig.url.trim().let { if (it.endsWith("/")) it else "$it/" },
                    username = selectedConfig.username,
                    password = selectedConfig.password,
                    webDavClient = webDavClient,
                    serverID = selected.id,
                )
                manager.initDir()
                return manager
            }
            val (_, account, password) = getWebDavConfig() ?: return null
            val root = getRootWebDavUrl() ?: return null
            val booksUrl = "${root}books/"
            val manager = RemoteBookWebDav(
                rootBookUrl = booksUrl,
                username = account,
                password = password,
                webDavClient = webDavClient,
                serverID = config.remoteServerId.takeIf { it > 0 }
            )
            manager.initDir()
            manager
        } catch (e: kotlin.coroutines.cancellation.CancellationException) {
            throw e
        } catch (e: Throwable) {
            CrashCollector.record("SettingsFacade", "getDefaultBookWebDav", error = e)
            null
        }
    }

    /**
     * Get list of remote books at the given path (or default books root).
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun getRemoteBookList(path: String? = null): List<RemoteBook> {
        return runRecoverable("SettingsFacade.getRemoteBookList") {
            val manager = getDefaultBookWebDav()
                ?: throw RecoverableSharedException("WEBDAV_NOT_CONFIGURED", "WebDAV not configured")
            val config = preferencesStore.runtimeConfig.first()
            val root = if (config.remoteServerId > 0) {
                serverRepository?.get(config.remoteServerId)?.config?.let {
                    progressJson.decodeFromString(Server.WebDavConfig.serializer(), it).url.trim()
                }?.takeIf { it.isNotBlank() }
            } else getRootWebDavUrl()?.plus("books/")
            val targetPath = path ?: root
                ?: throw RecoverableSharedException("WEBDAV_NOT_CONFIGURED", "WebDAV not configured")
            manager.getRemoteBookList(targetPath)
        }
    }

    /**
     * Download a remote book's content as raw bytes.
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun downloadRemoteBook(remoteBook: RemoteBook): ByteArray {
        return runRecoverable("SettingsFacade.downloadRemoteBook") {
            val manager = getDefaultBookWebDav()
                ?: throw RecoverableSharedException("WEBDAV_NOT_CONFIGURED", "WebDAV not configured")
            manager.downloadRemoteBook(remoteBook)
        }
    }

    /**
     * Upload a book file to remote storage.
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun uploadRemoteBook(fileName: String, fileBytes: ByteArray) {
        runRecoverable("SettingsFacade.uploadRemoteBook") {
            val manager = getDefaultBookWebDav()
                ?: throw RecoverableSharedException("WEBDAV_NOT_CONFIGURED", "WebDAV not configured")
            manager.upload(fileName, fileBytes)
        }
    }

    /**
     * Delete a remote book by its URL/path.
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun deleteRemoteBook(remoteBookUrl: String) {
        runRecoverable("SettingsFacade.deleteRemoteBook") {
            val manager = getDefaultBookWebDav()
                ?: throw RecoverableSharedException("WEBDAV_NOT_CONFIGURED", "WebDAV not configured")
            manager.delete(remoteBookUrl)
        }
    }
}
