package io.legado.kmp.shared.domain.localbook

import io.legado.kmp.shared.platform.FileAccess
import kotlin.random.Random
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

internal data class StagedArchiveBookFile(val path: String, val digest: BookArchiveFileDigest)

/** Publication only accepts complete generated files; no archive path becomes a filesystem path. */
internal class RetainedArchiveBookFiles(private val files: FileAccess) {
    suspend fun temporary(parent: String): String {
        currentCoroutineContext().ensureActive()
        check(files.createDirectory(parent)) { "无法创建本地归档目录" }
        while (true) {
            currentCoroutineContext().ensureActive()
            val candidate = "$parent/.archive-${Random.nextLong().toULong().toString(16)}-" +
                "${Random.nextLong().toULong().toString(16)}.part"
            if (!files.exists(candidate)) return candidate
        }
    }

    suspend fun copy(path: String, parent: String): StagedArchiveBookFile {
        val context = currentCoroutineContext()
        val temporary = temporary(parent)
        // The copy helper owns rollback until it returns a complete, closed output file.
        val digest = copyBookArchiveFile(files, path, temporary, BookFileArchiveLimits.ARCHIVE_BYTES) {
            context.ensureActive()
        }
        return StagedArchiveBookFile(temporary, digest)
    }

    suspend fun publish(staged: StagedArchiveBookFile, target: String, maximumBytes: Long) {
        val context = currentCoroutineContext()
        context.ensureActive()
        require(hashBookArchiveFile(files, staged.path, maximumBytes) { context.ensureActive() } == staged.digest) {
            "本次归档临时文件校验失败，未发布"
        }
        context.ensureActive()
        if (files.exists(target)) {
            require(hashBookArchiveFile(files, target, maximumBytes) { context.ensureActive() } == staged.digest) {
                "已存在的本地归档文件内容异常，未覆盖原文件"
            }
            return
        }
        check(files.createDirectory(target.substringBeforeLast('/'))) { "无法创建本地归档目录" }
        context.ensureActive()
        if (!files.move(staged.path, target)) {
            require(files.exists(target) &&
                hashBookArchiveFile(files, target, maximumBytes) { context.ensureActive() } == staged.digest
            ) { "保存归档失败，未覆盖已有文件" }
        }
    }

    suspend fun <T> withStaged(staged: StagedArchiveBookFile, action: suspend () -> T): T {
        var primary: Throwable? = null
        try {
            return action()
        } catch (error: Throwable) {
            primary = error
            throw error
        } finally {
            try {
                withContext(NonCancellable) {
                    check(!files.exists(staged.path) || files.delete(staged.path)) { "无法清理本次归档临时文件" }
                }
            } catch (cleanup: Throwable) {
                val original = primary
                if (original == null) throw cleanup
                original.addSuppressed(cleanup)
            }
        }
    }

    suspend fun <T> withReader(
        path: String,
        format: String,
        action: suspend (BookFileArchiveReader, LocalBookByteSource) -> T,
    ): T {
        val context = currentCoroutineContext()
        context.ensureActive()
        val source = files.openRead(path)
        var reader: BookFileArchiveReader? = null
        var primary: Throwable? = null
        try {
            require(source.size in 1L..BookFileArchiveLimits.ARCHIVE_BYTES) { "压缩包为空或超过 16 GiB" }
            val opened = NativeBookFileArchiveReader(source, format) { context.ensureActive() }
            reader = opened
            context.ensureActive()
            return action(opened, source)
        } catch (error: Throwable) {
            primary = error
            throw error
        } finally {
            var cleanup: Throwable? = null
            try { reader?.close() } catch (error: Throwable) { cleanup = error }
            try {
                source.closeSource()
            } catch (error: Throwable) {
                val first = cleanup
                if (first == null) cleanup = error else first.addSuppressed(error)
            }
            cleanup?.let { error ->
                val original = primary
                if (original == null) throw error
                original.addSuppressed(error)
            }
        }
    }
}
