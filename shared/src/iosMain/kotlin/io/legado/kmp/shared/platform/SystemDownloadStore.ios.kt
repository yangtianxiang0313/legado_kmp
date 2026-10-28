@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class, kotlinx.cinterop.BetaInteropApi::class)

package io.legado.kmp.shared.platform

import io.legado.kmp.shared.domain.runtime.FileDownloadStatus
import io.legado.kmp.shared.domain.runtime.FileDownloadTask
import io.legado.kmp.shared.domain.runtime.validateDownloadFileName
import io.legado.kmp.shared.source.IosSourceStateCrypto
import io.legado.kmp.shared.source.IosSourceStateKeychain
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.alloc
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.ptr
import kotlinx.cinterop.toKString
import kotlinx.cinterop.usePinned
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.decodeFromJsonElement
import okio.ByteString.Companion.encodeUtf8
import okio.ByteString.Companion.toByteString
import platform.Foundation.*
import platform.posix.EINTR
import platform.posix.ENOENT
import platform.posix.O_CLOEXEC
import platform.posix.O_NOFOLLOW
import platform.posix.O_NONBLOCK
import platform.posix.O_RDONLY
import platform.posix.S_IFDIR
import platform.posix.S_IFMT
import platform.posix.S_IFREG
import platform.posix.errno
import platform.posix.free
import platform.posix.fstat
import platform.posix.lstat
import platform.posix.pread
import platform.posix.realpath
import platform.posix.stat
import platform.posix.close as posixClose
import platform.posix.open as posixOpen

/** Synchronous persistence boundary; the service owns NSURLSession and callback scheduling. */
internal class SystemDownloadStore() {
    private val manager: NSFileManager get() = NSFileManager.defaultManager
    private val files = DownloadFileStore()
    private val json = Json { encodeDefaults = true }

    fun loadTasks(): List<FileDownloadTask> = guarded("下载任务记录无法读取或已损坏，请重新载入已完成文件") {
        val directory = recordsDirectory(create = false) ?: return@guarded emptyList()
        val path = "$directory/$RECORDS_NAME"
        val bytes = readBounded(path, MAX_RECORD_BYTES) ?: return@guarded emptyList()
        protectFile(path)
        val elements = json.parseToJsonElement(bytes.decodeToString(throwOnInvalidSequence = true))
        require(elements is JsonArray && elements.size <= MAX_RECORDS)
        validateTasks(json.decodeFromJsonElement<List<FileDownloadTask>>(elements))
    }

    fun saveTasks(tasks: List<FileDownloadTask>) {
        guarded("下载任务记录无法安全保存，请检查存储空间") {
            require(tasks.size <= MAX_RECORDS)
            val validated = validateTasks(tasks.toList())
            val bytes = json.encodeToString(validated).encodeToByteArray()
            require(bytes.size <= MAX_RECORD_BYTES)
            val directory = checkNotNull(recordsDirectory(create = true))
            writeProtected("$directory/$RECORDS_NAME", bytes.toNativeData(), MAX_RECORD_BYTES)
        }
    }

    fun readResume(id: String): NSData? = locked {
        // Invalid/unavailable caches are a retry from zero, never a reason to decode native archives.
        try {
            val uuid = nativeId(id)
            val directory = resumeDirectory(create = false) ?: return@locked null
            val path = "$directory/$uuid.resume-v1"
            val header = resumeHeader(uuid)
            val bytes = readBounded(path, MAX_RESUME_BYTES + header.size + TAG_BYTES) ?: return@locked null
            protectFile(path)
            val end = bytes.size - TAG_BYTES
            require(end > header.size && end - header.size <= MAX_RESUME_BYTES)
            require(header.indices.all { bytes[it] == header[it] })
            val tag = authenticateResume(bytes, end, createKey = false)
            require(IosSourceStateCrypto.tagsEqual(tag, bytes.copyOfRange(end, bytes.size)))
            bytes.copyOfRange(header.size, end).toNativeData()
        } catch (_: Exception) {
            null
        }
    }

    fun writeResume(id: String, data: NSData?) {
        guarded("下载续传缓存无法安全保存，请从头重试") {
            val uuid = nativeId(id)
            val directory = resumeDirectory(create = data != null) ?: return@guarded
            val path = "$directory/$uuid.resume-v1"
            if (data == null) {
                val info = fileInfo(path) ?: return@guarded
                require(info.isRegular && info.links == 1uL)
                check(manager.removeItemAtPath(path, null))
                return@guarded
            }
            require(data.length > 0uL && data.length <= MAX_RESUME_BYTES.toULong())
            val payload = ByteArray(data.length.toInt())
            payload.usePinned { pinned -> data.getBytes(pinned.addressOf(0), data.length) }
            val header = resumeHeader(uuid)
            val authenticated = header + payload
            val envelope = authenticated + authenticateResume(authenticated, authenticated.size, createKey = true)
            writeProtected(path, envelope.toNativeData(), MAX_RESUME_BYTES + header.size + TAG_BYTES)
        }
    }

    /** Call synchronously inside didFinishDownloadingToURL, before its temporary location expires. */
    fun commit(location: NSURL, fileName: String): DownloadedFile = guarded("下载文件无效或无法安全保存") {
        val name = validateDownloadFileName(fileName)
        require(location.isFileURL() && location.baseURL == null)
        require(location.host.isNullOrEmpty() || location.host == "localhost")
        require(location.user == null && location.password == null && location.query == null && location.fragment == null)
        val nativeSource = checkNotNull(location.path)
        // NSURLSession may use Darwin's no-symlink traversal alias. Validate its sandbox identity,
        // but retain the original alias for stat/move instead of removing the OS protection.
        val source = sandboxPath(
            if (nativeSource.startsWith("/.nofollow/")) nativeSource.removePrefix("/.nofollow") else nativeSource,
        )
        val temporary = sandboxPath(NSTemporaryDirectory().trimEnd('/'))
        val caches = systemDirectory(NSCachesDirectory)
        // Both foreground and background URLSession use disposable locations, not Documents/Downloads.
        require(source.startsWith("$temporary/") || source.startsWith("$caches/"))
        require(ensureDirectory(source.substringBeforeLast('/'), create = false))
        val info = checkNotNull(fileInfo(nativeSource))
        require(info.isRegular && info.size >= 0)
        val root = downloadsDirectory()
        // DownloadFileStore performs a move with collision suffixes and never overwrites a destination.
        val completed = files.commit(nativeSource, name)
        checkedCompleted(completed, root)
    }

    fun listCompleted(): List<DownloadedFile> = guarded("已完成下载目录无法安全读取") {
        completedFiles()
    }

    private fun validateTasks(tasks: List<FileDownloadTask>): List<FileDownloadTask> {
        require(tasks.size <= MAX_RECORDS)
        val completed = if (tasks.any { it.status == FileDownloadStatus.COMPLETED || it.localPath != null }) {
            completedFiles().associateBy { it.fileName }
        } else emptyMap()
        val ids = HashSet<String>()
        val paths = HashSet<String>()
        return tasks.mapNotNull { task ->
            require(task.bytesDownloaded >= 0 && (task.totalBytes == null || task.totalBytes >= 0))
            require(task.updatedAt >= 0 && (task.errorMessage?.length ?: 0) <= 4096)
            task.url?.let(::validateUrl)
            val isCompleted = task.status == FileDownloadStatus.COMPLETED
            if (task.id.startsWith("file:")) {
                require(isCompleted && task.url == null && task.id == "file:${task.fileName}")
                require(ids.add(task.id))
            } else {
                require(ids.add(nativeId(task.id)))
                require(isCompleted || task.url != null)
            }
            if (isCompleted) {
                // Moving one delivered file must not discard unrelated resumable tasks.
                val file = completed[task.fileName] ?: return@mapNotNull null
                require(isCompletedPath(checkNotNull(task.localPath), file))
                require(paths.add(file.path))
                task.copy(localPath = file.path, bytesDownloaded = file.size, totalBytes = file.size)
            } else {
                require(task.localPath == null && validateDownloadFileName(task.fileName) == task.fileName)
                task
            }
        }
    }

    private fun validateUrl(value: String) {
        require(value.isNotEmpty() && value.length <= MAX_URL_BYTES && value.encodeToByteArray().size <= MAX_URL_BYTES)
        require(value.none { it.isWhitespace() || it.code < 32 || it.code in 127..159 || it == '\\' })
        require(!ENCODED_CONTROL.containsMatchIn(value))
        val parsed = checkNotNull(NSURLComponents.componentsWithString(value))
        require(parsed.scheme?.lowercase() in setOf("http", "https") && !parsed.host.isNullOrBlank())
        require(parsed.user == null && parsed.password == null && parsed.URL != null)
    }

    private fun completedFiles(): List<DownloadedFile> {
        val root = downloadsDirectory()
        return files.listCompleted().mapNotNull { file ->
            val path = sandboxPath(file.path)
            require(path == "$root/${file.fileName}" && safeCompletedName(file.fileName))
            val info = fileInfo(path) ?: return@mapNotNull null
            if (!info.isRegular || info.size < 0) return@mapNotNull null
            file.copy(path = path, size = info.size)
        }
    }

    private fun checkedCompleted(file: DownloadedFile, root: String): DownloadedFile {
        val path = sandboxPath(file.path)
        require(safeCompletedName(file.fileName) && path == "$root/${file.fileName}")
        require(ensureDirectory(root, create = false))
        val info = checkNotNull(fileInfo(path))
        require(info.isRegular && info.size >= 0)
        return file.copy(path = path, size = info.size)
    }

    private fun isCompletedPath(stored: String, file: DownloadedFile): Boolean {
        if (!cleanAbsolutePath(stored)) return false
        if (runCatching { sandboxPath(stored) }.getOrNull() == file.path) return true
        // Restored installations may retain an old container UUID. Never read that recorded path.
        val marker = "/Containers/Data/Application/"
        val offset = stored.lastIndexOf(marker)
        if (offset < 0) return false
        val prefix = stored.substring(0, offset)
        val device = prefix == "/var/mobile" || prefix == "/private/var/mobile"
        val simulator = SIMULATOR_PREFIX.matches(prefix)
        if (!device && !simulator) return false
        val relative = stored.substring(offset + marker.length)
        val container = relative.substringBefore('/')
        return UUID.matches(container) && relative == "$container/Documents/Downloads/${file.fileName}"
    }

    private fun safeCompletedName(name: String): Boolean =
        name.isNotEmpty() && !name.startsWith('.') && name == name.trim() &&
            name.encodeToByteArray().size <= 255 &&
            name.none { it == '/' || it == '\\' || it == ':' || it.code < 32 || it.code in 127..159 }

    private fun nativeId(id: String): String {
        require(UUID.matches(id))
        return id.uppercase()
    }

    private fun resumeHeader(uuid: String): ByteArray = "$RESUME_PREFIX$uuid\n".encodeToByteArray()

    private fun authenticateResume(bytes: ByteArray, count: Int, createKey: Boolean): ByteArray {
        val secret = IosSourceStateKeychain.load(create = createKey)
        return try {
            // Domain separation keeps this MAC independent from source-state encryption/authentication.
            val key = "legado-system-download-resume-key:1".encodeUtf8().hmacSha256(secret.toByteString())
            bytes.toByteString(0, count).hmacSha256(key).toByteArray()
        } finally {
            secret.fill(0)
        }
    }

    private fun downloadsDirectory(): String {
        val documents = systemDirectory(NSDocumentDirectory)
        val path = "$documents/Downloads"
        check(ensureDirectory(path, create = true))
        return path
    }

    private fun recordsDirectory(create: Boolean): String? {
        val support = systemDirectory(NSApplicationSupportDirectory)
        if (!ensureDirectory(support, create)) return null
        val path = "$support/SystemDownloads"
        if (!ensureDirectory(path, create, privateDirectory = true)) return null
        return path
    }

    private fun resumeDirectory(create: Boolean): String? {
        val root = recordsDirectory(create) ?: return null
        val path = "$root/Resume"
        return path.takeIf { ensureDirectory(it, create, privateDirectory = true) }
    }

    private fun systemDirectory(kind: NSSearchPathDirectory): String {
        val url = manager.URLForDirectory(kind, NSUserDomainMask, null, false, null)
        return sandboxPath(checkNotNull(url?.path))
    }

    private val rawHome: String get() = NSHomeDirectory().trimEnd('/')

    private fun canonicalHome(): String {
        val pointer = checkNotNull(realpath(rawHome, null))
        return try {
            pointer.toKString().trimEnd('/').also { require(cleanAbsolutePath(it)) }
        } finally {
            free(pointer)
        }
    }

    private fun sandboxPath(path: String): String {
        require(cleanAbsolutePath(path))
        val home = canonicalHome()
        return when {
            path == home || path.startsWith("$home/") -> path
            path == rawHome || path.startsWith("$rawHome/") -> home + path.removePrefix(rawHome)
            else -> error("下载路径不在应用容器内")
        }
    }

    private fun cleanAbsolutePath(path: String): Boolean =
        path.startsWith('/') && path.length <= 4096 &&
            path.none { it.code < 32 || it.code in 127..159 } &&
            path.substring(1).split('/').all { it.isNotEmpty() && it != "." && it != ".." }

    private fun ensureDirectory(path: String, create: Boolean, privateDirectory: Boolean = false): Boolean {
        val home = canonicalHome()
        require(path == home || path.startsWith("$home/"))
        require(fileInfo(home)?.isDirectory == true)
        var current = home
        for (component in path.removePrefix(home).split('/').filter { it.isNotEmpty() }) {
            current += "/$component"
            var info = fileInfo(current)
            if (info == null) {
                if (!create) return false
                val attributes = if (current == path && privateDirectory) directoryAttributes else null
                // Create one component at a time, never through an unchecked symlink parent.
                manager.createDirectoryAtPath(current, false, attributes, null)
                info = fileInfo(current)
            }
            require(info?.isDirectory == true)
        }
        if (privateDirectory) check(manager.setAttributes(directoryAttributes, path, null))
        return true
    }

    private fun protectFile(path: String) {
        val info = checkNotNull(fileInfo(path))
        require(info.isRegular && info.links == 1uL)
        check(manager.setAttributes(fileAttributes, path, null))
    }

    private fun writeProtected(path: String, data: NSData, maxBytes: Int) {
        require(data.length > 0uL && data.length <= maxBytes.toULong())
        check(ensureDirectory(path.substringBeforeLast('/'), create = false, privateDirectory = true))
        fileInfo(path)?.let { require(it.isRegular && it.links == 1uL) }
        check(data.writeToFile(
            path,
            NSDataWritingAtomic or NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication,
            null,
        ))
        protectFile(path)
    }

    private fun readBounded(path: String, maxBytes: Int): ByteArray? {
        check(ensureDirectory(path.substringBeforeLast('/'), create = false))
        val descriptor = posixOpen(path, O_RDONLY or O_CLOEXEC or O_NOFOLLOW or O_NONBLOCK)
        if (descriptor < 0) {
            if (errno == ENOENT) {
                // A dangling symlink is not an absent cache/record.
                require(fileInfo(path) == null)
                return null
            }
            error("无法打开下载记录文件")
        }
        return try {
            val length = memScoped {
                val info = alloc<stat>()
                check(fstat(descriptor, info.ptr) == 0)
                require((info.st_mode.toInt() and S_IFMT.toInt()) == S_IFREG.toInt() && info.st_nlink.toULong() == 1uL)
                require(info.st_size in 1..maxBytes.toLong())
                info.st_size.toInt()
            }
            val bytes = ByteArray(length)
            bytes.usePinned { pinned ->
                var offset = 0
                while (offset < length) {
                    val count = pread(descriptor, pinned.addressOf(offset), (length - offset).toULong(), offset.toLong())
                    when {
                        count > 0 -> offset += count.toInt()
                        count < 0 && errno == EINTR -> Unit
                        else -> error("下载记录文件不完整")
                    }
                }
            }
            memScoped {
                val info = alloc<stat>()
                check(fstat(descriptor, info.ptr) == 0 && info.st_size == length.toLong())
            }
            bytes
        } finally {
            posixClose(descriptor)
        }
    }

    private data class FileInfo(val mode: Int, val size: Long, val links: ULong) {
        val isRegular: Boolean get() = (mode and S_IFMT.toInt()) == S_IFREG.toInt()
        val isDirectory: Boolean get() = (mode and S_IFMT.toInt()) == S_IFDIR.toInt()
    }

    private fun fileInfo(path: String): FileInfo? = memScoped {
        val info = alloc<stat>()
        if (lstat(path, info.ptr) != 0) {
            if (errno == ENOENT) return@memScoped null
            error("无法核对下载文件属性")
        }
        FileInfo(info.st_mode.toInt(), info.st_size, info.st_nlink.toULong())
    }

    private fun ByteArray.toNativeData(): NSData = usePinned { pinned ->
        NSData.create(bytes = pinned.addressOf(0), length = size.toULong())
    }

    private inline fun <T> guarded(message: String, block: () -> T): T = locked {
        try {
            block()
        } catch (_: Exception) {
            // Native/parser errors may contain paths, signed URLs, or credentials; never propagate them.
            throw IllegalStateException(message)
        }
    }

    private inline fun <T> locked(block: () -> T): T {
        lock.lock()
        return try {
            block()
        } finally {
            lock.unlock()
        }
    }

    private companion object {
        const val RECORDS_NAME = "records-v1.json"
        const val MAX_RECORDS = 2048
        const val MAX_RECORD_BYTES = 4 * 1024 * 1024
        const val MAX_RESUME_BYTES = 32 * 1024 * 1024
        const val MAX_URL_BYTES = 16 * 1024
        const val RESUME_PREFIX = "legado-system-download-resume:1\n"
        const val TAG_BYTES = 32
        val UUID = Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
        val SIMULATOR_PREFIX = Regex("/.+/CoreSimulator/Devices/[0-9a-fA-F-]{36}/data")
        val ENCODED_CONTROL = Regex("%(?:0[0-9a-f]|1[0-9a-f]|7f)", RegexOption.IGNORE_CASE)
        val lock = NSRecursiveLock()
        val directoryAttributes: Map<Any?, Any> = mapOf(
            NSFileProtectionKey to checkNotNull(NSFileProtectionCompleteUntilFirstUserAuthentication),
            NSFilePosixPermissions to 448, // 0700
        )
        val fileAttributes: Map<Any?, Any> = mapOf(
            NSFileProtectionKey to checkNotNull(NSFileProtectionCompleteUntilFirstUserAuthentication),
            NSFilePosixPermissions to 384, // 0600
        )
    }
}
