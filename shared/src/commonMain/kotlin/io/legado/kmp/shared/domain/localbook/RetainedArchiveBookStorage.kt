package io.legado.kmp.shared.domain.localbook

import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.platform.AppFilesDirectory
import io.legado.kmp.shared.platform.FileAccess
import kotlin.random.Random
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
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

    suspend fun prepare(path: String): ArchiveBookListing = withContext(Dispatchers.Default) {
        mutex.withLock { prepareLocked(path) }
    }

    private suspend fun prepareLocked(path: String): ArchiveBookListing {
        val format = path.substringAfterLast('.', "").lowercase()
        require(format in RetainedArchiveOrigins.FORMATS) { "仅支持 ZIP、RAR 和 7z 压缩包" }
        val bytes = readBounded(path)
        val context = currentCoroutineContext()
        val archive = openBookArchive(bytes, format) { context.ensureActive() }
        val entries = validatedEntries(archive) { context.ensureActive() }.mapNotNull { entry ->
            context.ensureActive()
            val extension = entry.path.substringAfterLast('.', "").lowercase()
            if (extension !in RetainedArchiveOrigins.BOOK_FORMATS || entry.path.split('/').any { it == "__MACOSX" } ||
                entry.path.substringAfterLast('/').startsWith("._")) return@mapNotNull null
            ArchiveBookEntry(entry.path, entry.path.substringAfterLast('/'), entry.size, extension)
        }
        require(entries.isNotEmpty()) { "压缩包内没有可导入的 TXT/EPUB/PDF/UMD/MOBI 书籍" }
        val id = bytes.toByteString().sha256().hex()
        context.ensureActive()
        require(retainedFormats(id).none { it != format }) { "保留的压缩包格式存在歧义，请先处理冲突原包" }
        publish(archivePath(id, format), bytes)
        return ArchiveBookListing(id, path.substringAfterLast('/'), entries)
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
        val bytes = readBounded(archivePath(identity.archiveId, identity.format))
        val context = currentCoroutineContext()
        require(bytes.toByteString().sha256().hex() == identity.archiveId) {
            "保留的原始压缩包校验失败，请重新选择原包"
        }
        context.ensureActive()
        val archive = openBookArchive(bytes, identity.format) { context.ensureActive() }
        val entry = validatedEntries(archive) { context.ensureActive() }.firstOrNull { it.path == identity.entryPath }
            ?: error("压缩包中不存在选中的书籍：${identity.entryPath}")
        val extracted = archive.read(identity.entryPath)
        context.ensureActive()
        require(extracted.size.toLong() == entry.size && extracted.size <= BookArchiveLimits.ENTRY_BYTES) {
            "压缩书籍实际长度与目录不一致或超过 64 MiB"
        }
        require(extracted.isNotEmpty()) { "不能导入空书籍" }
        if (identity.entryPath.endsWith(".epub", ignoreCase = true)) {
            // Validate every inner ZIP entry before publishing an extracted EPUB.
            val epub = BookArchiveZipReader(extracted) { context.ensureActive() }
            epub.entries().forEach { epub.read(it.path) }
        }
        val path = extractedPath(identity.archiveId, identity.entryPath)
        publish(path, extracted)
        return path
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

    private fun validatedEntries(archive: BookArchiveReader, checkCancelled: () -> Unit): List<BookArchiveMember> {
        val entries = archive.entries()
        require(entries.size <= BookArchiveLimits.ENTRIES) { "压缩包超过 4096 项" }
        val names = mutableSetOf<String>()
        var total = 0L
        for (entry in entries) {
            checkCancelled()
            validateRetainedArchivePath(entry.path)
            require(!entry.path.endsWith('/')) { "压缩包书籍目录包含非文件项" }
            require(names.add(entry.path.lowercase())) { "压缩包包含重名或大小写冲突的路径：${entry.path}" }
            require(entry.size in 0..BookArchiveLimits.ENTRY_BYTES.toLong()) {
                "压缩包文件长度无效或超过 64 MiB：${entry.path}"
            }
            total += entry.size
            require(total <= BookArchiveLimits.TOTAL_BYTES) { "压缩包解压总量超过 256 MiB" }
        }
        checkCancelled()
        return entries
    }

    private suspend fun readBounded(path: String): ByteArray {
        currentCoroutineContext().ensureActive()
        val source = files.openRead(path)
        var failure: Throwable? = null
        try {
            require(source.size in 1..BookArchiveLimits.ARCHIVE_BYTES.toLong()) { "压缩归档文件为空或超过 128 MiB" }
            val result = ByteArray(source.size.toInt())
            var offset = 0
            while (offset < result.size) {
                currentCoroutineContext().ensureActive()
                val length = minOf(1024 * 1024, result.size - offset)
                val chunk = source.read(offset.toLong(), length)
                require(chunk.isNotEmpty() && chunk.size <= length) { "压缩归档文件在读取期间被截断或长度异常" }
                chunk.copyInto(result, offset)
                offset += chunk.size
            }
            currentCoroutineContext().ensureActive()
            return result
        } catch (error: Throwable) {
            failure = error
            throw error
        } finally {
            try {
                source.closeSource()
            } catch (closeError: Throwable) {
                val original = failure
                if (original == null) throw closeError
                original.addSuppressed(closeError)
            }
        }
    }

    private suspend fun publish(path: String, bytes: ByteArray) {
        currentCoroutineContext().ensureActive()
        if (files.exists(path)) {
            require(files.getSize(path) == bytes.size.toLong() && readBounded(path).contentEquals(bytes)) {
                "已存在的本地归档文件内容异常，未覆盖原文件"
            }
            return
        }
        val parent = path.substringBeforeLast('/')
        check(files.createDirectory(parent)) { "无法创建本地归档目录" }
        currentCoroutineContext().ensureActive()
        var temporary: String
        do {
            currentCoroutineContext().ensureActive()
            temporary = "$parent/.archive-${Random.nextLong().toULong().toString(16)}-" +
                "${Random.nextLong().toULong().toString(16)}.part"
        } while (files.exists(temporary))
        var failure: Throwable? = null
        try {
            currentCoroutineContext().ensureActive()
            check(files.write(temporary, bytes)) { "无法保存本地归档文件" }
            currentCoroutineContext().ensureActive()
            check(files.getSize(temporary) == bytes.size.toLong()) { "本地归档文件写入不完整" }
            currentCoroutineContext().ensureActive()
            if (!files.move(temporary, path)) {
                require(files.exists(path) && readBounded(path).contentEquals(bytes)) { "保存归档失败，未覆盖已有文件" }
            }
        } catch (error: Throwable) {
            failure = error
            throw error
        } finally {
            try {
                withContext(NonCancellable) {
                    check(!files.exists(temporary) || files.delete(temporary)) { "无法清理本次归档临时文件" }
                }
            } catch (cleanupError: Throwable) {
                val original = failure
                if (original == null) throw cleanupError
                original.addSuppressed(cleanupError)
            }
        }
    }

    private fun isDigest(value: String): Boolean = value.length == 64 && value.all { it in "0123456789abcdef" }
}
