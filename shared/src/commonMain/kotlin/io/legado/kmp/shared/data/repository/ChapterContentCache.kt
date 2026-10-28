package io.legado.kmp.shared.data.repository

import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.platform.FileAccess
import io.legado.kmp.shared.util.md5Hex
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

/** File operations here require the caller to hold the directory's [ChapterCacheLocks] lease. */
internal class ChapterContentCache(private val fileAccess: FileAccess) {
    suspend fun usesUrls(directory: String): Boolean = fileAccess.exists(formatMarkerPath(directory))

    suspend fun chapterPath(directory: String, chapter: BookChapter, suffix: String = "nb"): String {
        val name = if (usesUrls(directory)) urlFileName(chapter, suffix) else chapter.getFileName(suffix)
        return "$directory/$name"
    }

    fun urlFileName(chapter: BookChapter, suffix: String = "nb"): String {
        return "url-${chapter.url.md5Hex()}.$suffix"
    }

    fun isPrivateFile(name: String): Boolean = name == FORMAT_MARKER || urlFilePattern.matches(name)

    suspend fun prepare(directory: String, chapters: List<BookChapter>) {
        if (usesUrls(directory)) return
        currentCoroutineContext().ensureActive()
        check(fileAccess.createDirectory(directory)) { "Failed to create chapter cache: $directory" }

        // Abandoned copies are invisible in legacy mode and must not survive a retry.
        for (name in fileAccess.listFiles(directory)) {
            currentCoroutineContext().ensureActive()
            if (urlFilePattern.matches(name)) {
                check(fileAccess.delete("$directory/$name")) { "Failed to remove staged chapter cache: $name" }
            }
        }
        for (chapter in chapters) {
            copyLegacyFile(directory, chapter, "nb")
            copyLegacyFile(directory, chapter, "nr")
        }

        val marker = formatMarkerPath(directory)
        try {
            currentCoroutineContext().ensureActive()
            check(fileAccess.write(marker, "url-md5-v1".encodeToByteArray())) {
                "Failed to publish chapter cache format: $directory"
            }
            currentCoroutineContext().ensureActive()
        } catch (failure: Throwable) {
            // A suspended marker write may have completed before reporting cancellation.
            withContext(NonCancellable) {
                try {
                    if (fileAccess.exists(marker)) {
                        check(fileAccess.delete(marker)) { "Failed to roll back chapter cache format: $directory" }
                    }
                } catch (cleanupFailure: Throwable) {
                    failure.addSuppressed(cleanupFailure)
                }
            }
            throw failure
        }
    }

    suspend fun deleteDirectory(directory: String): Boolean {
        var success = true
        val files = fileAccess.listFiles(directory)
        for (name in files) {
            currentCoroutineContext().ensureActive()
            if (name != FORMAT_MARKER && !fileAccess.delete("$directory/$name")) success = false
        }
        // Retain URL mode after partial deletion instead of reviving retained legacy files.
        if (!success) return false
        if (FORMAT_MARKER in files && !fileAccess.delete(formatMarkerPath(directory))) return false
        return fileAccess.delete(directory)
    }

    suspend fun moveDirectory(oldDirectory: String, newDirectory: String): Boolean {
        if (!fileAccess.exists(oldDirectory)) return true
        // Never merge another book's files or expose its marker over a partial copy.
        if (fileAccess.listFiles(newDirectory).isNotEmpty()) return false
        if (fileAccess.exists(newDirectory) && !fileAccess.delete(newDirectory)) return false
        currentCoroutineContext().ensureActive()
        // A whole-directory move retains nested image caches and cannot leave a half-copied target.
        return fileAccess.move(oldDirectory, newDirectory)
    }

    private suspend fun copyLegacyFile(directory: String, chapter: BookChapter, suffix: String) {
        currentCoroutineContext().ensureActive()
        val source = "$directory/${chapter.getFileName(suffix)}"
        if (!fileAccess.exists(source)) return
        val data = fileAccess.read(source)
        currentCoroutineContext().ensureActive()
        val target = "$directory/${urlFileName(chapter, suffix)}"
        check(fileAccess.write(target, data)) { "Failed to copy chapter cache: $source -> $target" }
    }

    private fun formatMarkerPath(directory: String): String = "$directory/$FORMAT_MARKER"

    private companion object {
        const val FORMAT_MARKER = ".chapter-cache-url-v1"
        val urlFilePattern = Regex("url-[0-9a-f]{32}\\.(nb|nr)")
    }
}
