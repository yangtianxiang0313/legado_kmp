package io.legado.kmp.shared.platform

/**
 * Platform abstraction for ZIP archive operations
 * Used for EPUB and other archive format parsing
 */
expect class ZipHandler {

    /**
     * Extract a single file from ZIP archive
     * @param zipFile Path to ZIP file
     * @param entryPath Path inside ZIP to extract
     * @return Extracted file content as ByteArray
     */
    suspend fun extractEntry(zipFile: String, entryPath: String): ByteArray?

    /**
     * Extract entire ZIP archive to destination directory
     * @param zipFile Path to ZIP file
     * @param destDir Destination directory path
     * @return true if extraction successful
     */
    suspend fun extractAll(zipFile: String, destDir: String): Boolean

    /**
     * List all entries in ZIP archive
     * @param zipFile Path to ZIP file
     * @return List of entry paths in the ZIP
     */
    suspend fun listEntries(zipFile: String): List<String>

    /**
     * Check if file is a valid ZIP archive
     * @param zipFile Path to file
     * @return true if valid ZIP
     */
    suspend fun isValidZip(zipFile: String): Boolean

    /**
     * Get uncompressed size of a ZIP entry
     * @param zipFile Path to ZIP file
     * @param entryPath Path inside ZIP
     * @return Uncompressed size in bytes, or null if entry not found
     */
    suspend fun getEntrySize(zipFile: String, entryPath: String): Long?
}
