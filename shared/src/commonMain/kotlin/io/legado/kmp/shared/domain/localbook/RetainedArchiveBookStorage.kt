package io.legado.kmp.shared.domain.localbook

import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.platform.AppFilesDirectory
import io.legado.kmp.shared.platform.FileAccess
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import okio.ByteString.Companion.toByteString

data class ArchiveBookEntry(val path: String, val fileName: String, val size: Long, val format: String)
data class ArchiveBookListing(val archiveId: String, val fileName: String, val entries: List<ArchiveBookEntry>)

/** Stores immutable originals and regenerates only generated, app-owned extraction paths. */
class RetainedArchiveBookStorage(
    private val files: FileAccess,
    private val directory: AppFilesDirectory,
) : ArchiveBookRecovery {
    private val mutex = Mutex()
    private val archiveFiles = RetainedArchiveBookFiles(files)

    suspend fun prepare(path: String): ArchiveBookListing = withContext(Dispatchers.Default) {
        mutex.withLock { prepareLocked(path) }
    }

    private suspend fun prepareLocked(path: String): ArchiveBookListing {
        val format = path.substringAfterLast('.', "").lowercase()
        require(format in RetainedArchiveOrigins.FORMATS) { "仅支持 ZIP、RAR 和 7z 压缩包" }
        val context = currentCoroutineContext()
        val staged = archiveFiles.copy(path, "${root()}/Archives")
        return archiveFiles.withStaged(staged) {
            val entries = archiveFiles.withReader(staged.path, format) { archive, source ->
                val selected = validatedEntries(archive) { context.ensureActive() }.mapNotNull { entry ->
                    context.ensureActive()
                    val extension = entry.path.substringAfterLast('.', "").lowercase()
                    if (extension !in RetainedArchiveOrigins.BOOK_FORMATS ||
                        entry.path.split('/').any { it == "__MACOSX" } ||
                        entry.path.substringAfterLast('/').startsWith("._")) return@mapNotNull null
                    ArchiveBookEntry(entry.path, entry.path.substringAfterLast('/'), entry.size, extension)
                }
                require(hashBookArchiveSource(source, BookFileArchiveLimits.ARCHIVE_BYTES) {
                    context.ensureActive()
                } == staged.digest) { "压缩包在预检期间发生变化" }
                selected
            }
            require(entries.isNotEmpty()) { "压缩包内没有可导入的 TXT/EPUB/PDF/UMD/MOBI 书籍" }
            val id = staged.digest.sha256
            context.ensureActive()
            require(retainedFormats(id).none { it != format }) { "保留的压缩包格式存在歧义，请先处理冲突原包" }
            archiveFiles.publish(staged, archivePath(id, format), BookFileArchiveLimits.ARCHIVE_BYTES)
            ArchiveBookListing(id, path.substringAfterLast('/'), entries)
        }
    }

    /** Share the storage lock across facade instances, through the database commit. */
    internal suspend fun <T> withExtractedEntry(
        archiveId: String,
        entryPath: String,
        block: suspend (RetainedArchiveBookFile) -> T,
    ): T = mutex.withLock {
        val extracted = withContext(Dispatchers.Default) {
            // The Swift-facing import API has no format; never choose among competing originals.
            RetainedArchiveIdentity(archiveId, entryPath, "zip").validate()
            val formats = retainedFormats(archiveId)
            require(formats.isNotEmpty()) { "保留的原始压缩包不存在，请重新选择原包" }
            require(formats.size == 1) { "保留的压缩包格式存在歧义，无法确定原包" }
            val identity = RetainedArchiveIdentity(archiveId, entryPath, formats.single())
            RetainedArchiveBookFile(identity, extractLocked(identity))
        }
        // No dispatcher hop or cancellation check after block: a completed DB commit wins a late cancel.
        block(extracted)
    }

    private suspend fun extractLocked(identity: RetainedArchiveIdentity): String {
        identity.validate()
        val context = currentCoroutineContext()
        return archiveFiles.withReader(archivePath(identity.archiveId, identity.format), identity.format) { archive, source ->
            require(hashBookArchiveSource(source, BookFileArchiveLimits.ARCHIVE_BYTES) {
                context.ensureActive()
            }.sha256 == identity.archiveId) { "保留的原始压缩包校验失败，请重新选择原包" }
            val entry = validatedEntries(archive) { context.ensureActive() }.firstOrNull { it.path == identity.entryPath }
                ?: error("压缩包中不存在选中的书籍：${identity.entryPath}")
            require(entry.size > 0L) { "不能导入空书籍" }
            val path = extractedPath(identity.archiveId, identity.entryPath)
            val staged = extractEntry(archive, entry, path.substringBeforeLast('/'))
            archiveFiles.withStaged(staged) {
                require(hashBookArchiveSource(source, BookFileArchiveLimits.ARCHIVE_BYTES) {
                    context.ensureActive()
                }.sha256 == identity.archiveId) { "保留的原始压缩包在解压期间发生变化" }
                if (identity.entryPath.endsWith(".epub", ignoreCase = true)) {
                    archiveFiles.withReader(staged.path, "zip") { epub, _ -> epub.validateAll() }
                }
                context.ensureActive()
                archiveFiles.publish(staged, path, BookFileArchiveLimits.ENTRY_BYTES)
                path
            }
        }
    }

    private suspend fun extractEntry(
        archive: BookFileArchiveReader,
        entry: BookArchiveMember,
        parent: String,
    ): StagedArchiveBookFile {
        val context = currentCoroutineContext()
        val temporary = archiveFiles.temporary(parent)
        val output = BookArchiveFileOutput(temporary, BookFileArchiveLimits.ENTRY_BYTES)
        var handedOff = false
        var primary: Throwable? = null
        try {
            val length = archive.extract(entry.path) { bytes ->
                context.ensureActive()
                output.write(bytes)
            }
            require(length == entry.size) { "压缩书籍实际长度与目录不一致" }
            context.ensureActive()
            output.finish()
            val digest = hashBookArchiveFile(files, temporary, BookFileArchiveLimits.ENTRY_BYTES) {
                context.ensureActive()
            }
            require(digest.size == entry.size) { "压缩书籍写入不完整" }
            return StagedArchiveBookFile(temporary, digest).also { handedOff = true }
        } catch (error: Throwable) {
            primary = error
            throw error
        } finally {
            if (!handedOff) {
                try { output.abort() } catch (cleanup: Throwable) {
                    val original = primary
                    if (original == null) throw cleanup
                    original.addSuppressed(cleanup)
                }
            }
        }
    }

    override suspend fun recover(book: Book): Book? = withContext(Dispatchers.Default) {
        val identity = RetainedArchiveOrigins.decode(book.origin) ?: return@withContext null
        mutex.withLock {
            requireIdentity(book, identity)
            if (files.lastModified(book.bookUrl) != null) return@withLock book
            // Recovery uses only the origin's format, not another same-ID extension on disk.
            extractLocked(identity)
            // Keep the database key, chapters, reading configuration and progress after relocation.
            book.takeIf { files.lastModified(it.bookUrl) != null }
        }
    }

    internal fun requireIdentity(book: Book, identity: RetainedArchiveIdentity) {
        identity.validate()
        val expected = extractedPath(identity.archiveId, identity.entryPath)
        val expectedKey = checkNotNull(storageKey(expected)) { "压缩书籍生成路径无效" }
        require(book.isLocal && storageKey(book.bookUrl) == expectedKey &&
            RetainedArchiveOrigins.decode(book.origin) == identity) {
            "压缩书籍路径或来源与原身份不一致，未修改已有书籍"
        }
    }

    internal fun extractedPath(archiveId: String, entryPath: String): String {
        RetainedArchiveIdentity(archiveId, entryPath, "zip").validate()
        val entryId = entryPath.encodeToByteArray().toByteString().sha256().hex()
        val extension = entryPath.substringAfterLast('.').lowercase()
        return "${root()}/ArchiveBooks/$archiveId/$entryId.$extension"
    }

    internal fun storageKey(path: String): String? {
        if (!path.startsWith('/') || path.drop(1).split('/').any {
            it.isEmpty() || it == "." || it == ".." || it.any { char -> char.code < 32 || char == '\\' }
        }) return null
        val key = path.substringAfter("/LocalBooks/ArchiveBooks/", missingDelimiterValue = "")
        val parts = key.split('/')
        if (parts.size != 2 || !isDigest(parts[0])) return null
        val fileName = parts[1]
        if (!isDigest(fileName.substringBeforeLast('.', "")) ||
            fileName.substringAfterLast('.', "") !in RetainedArchiveOrigins.BOOK_FORMATS) return null
        return key
    }

    private fun root(): String = "${directory.path().trimEnd('/')}/LocalBooks"
    private fun archivePath(id: String, format: String): String = "${root()}/Archives/$id.$format"

    private suspend fun retainedFormats(id: String): List<String> {
        val formats = mutableListOf<String>()
        for (format in RetainedArchiveOrigins.FORMATS) {
            currentCoroutineContext().ensureActive()
            if (files.exists(archivePath(id, format))) formats += format
        }
        return formats
    }

    private fun validatedEntries(archive: BookFileArchiveReader, checkCancelled: () -> Unit): List<BookArchiveMember> {
        val entries = archive.entries()
        require(entries.size <= BookFileArchiveLimits.ENTRIES) { "压缩包条目数量超过限制" }
        val names = mutableSetOf<String>()
        var total = 0L
        for (entry in entries) {
            checkCancelled()
            validateRetainedArchivePath(entry.path)
            require(!entry.path.endsWith('/')) { "压缩包书籍目录包含非文件项" }
            require(names.add(entry.path.lowercase())) { "压缩包包含重名或大小写冲突的路径：${entry.path}" }
            require(entry.size in 0L..BookFileArchiveLimits.ENTRY_BYTES) {
                "压缩包文件长度无效或超过 2 GiB：${entry.path}"
            }
            require(entry.size <= BookFileArchiveLimits.TOTAL_BYTES - total) { "压缩包解压总量超过 16 GiB" }
            total += entry.size
        }
        checkCancelled()
        return entries
    }

    private fun isDigest(value: String): Boolean = value.length == 64 && value.all { it in "0123456789abcdef" }
}
