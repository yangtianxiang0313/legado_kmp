package io.legado.kmp.shared.platform

import io.legado.kmp.shared.domain.localbook.LocalBookByteSource

/**
 * Platform abstraction for file operations
 * expect class to be implemented separately for Android and iOS
 */
expect class FileAccess() {

    /**
     * Opens a read-only random-access source without reading file content.
     * This is synchronous: callers must run it and source reads on Default.
     * The caller owns the returned source and must close it.
     */
    @Throws(Exception::class)
    fun openRead(path: String): LocalBookByteSource

    /**
     * Read file content as ByteArray
     * @param path File path
     * @return File content
     */
    suspend fun read(path: String): ByteArray

    /**
     * Write content to file
     * @param path File path
     * @param data Content to write
     */
    suspend fun write(path: String, data: ByteArray): Boolean

    /**
     * Check if file exists
     * @param path File path
     * @return true if file exists
     */
    suspend fun exists(path: String): Boolean

    /**
     * Delete a file
     * @param path File path
     * @return true if deleted successfully
     */
    suspend fun delete(path: String): Boolean

    /**
     * Get file size in bytes
     * @param path File path
     * @return File size in bytes, or 0 if file doesn't exist
     */
    suspend fun getSize(path: String): Long

    /**
     * Get file last modified time in milliseconds.
     * Returns null when the file does not exist.
     */
    suspend fun lastModified(path: String): Long?

    /**
     * List files in directory
     * @param path Directory path
     * @return List of file names in the directory
     */
    suspend fun listFiles(path: String): List<String>

    /**
     * Create directory if it doesn't exist
     * @param path Directory path
     * @return true if created or already exists
     */
    suspend fun createDirectory(path: String): Boolean

    /** Move a file or whole directory to an absent destination without merging or overwriting it. */
    suspend fun move(fromPath: String, toPath: String): Boolean
}
