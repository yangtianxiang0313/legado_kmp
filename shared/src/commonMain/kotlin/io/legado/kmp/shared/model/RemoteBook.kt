package io.legado.kmp.shared.model

import io.legado.kmp.shared.network.WebDavFile

/**
 * Remote book model representing a book file on a remote server (e.g. WebDAV).
 * Mirrors legado RemoteBook.
 */
data class RemoteBook(
    val filename: String,
    val path: String,
    val size: Long,
    val lastModify: Long,
    val contentType: String = "folder",
    val isOnBookShelf: Boolean = false
) {
    val isDir: Boolean get() = contentType == "folder"

    companion object {
        private val bookFileRegex = Regex(".*\\.(txt|epub|umd|pdf|mobi|azw3|azw)", RegexOption.IGNORE_CASE)
        private val archiveFileRegex = Regex(".*\\.(zip|rar|7z)$", RegexOption.IGNORE_CASE)

        /**
         * Create a RemoteBook from a WebDavFile.
         * Directories keep contentType as "folder".
         * Files get the file extension as contentType.
         */
        fun fromWebDavFile(webDavFile: WebDavFile): RemoteBook {
            val ct = if (webDavFile.isDir) {
                "folder"
            } else {
                webDavFile.displayName.substringAfterLast(".")
            }
            return RemoteBook(
                filename = webDavFile.displayName,
                path = webDavFile.path,
                size = webDavFile.size,
                lastModify = webDavFile.lastModify,
                contentType = ct,
            )
        }

        /**
         * Returns true if the WebDavFile represents a supported book format, archive, or directory.
         */
        fun isBookOrDir(webDavFile: WebDavFile): Boolean {
            return webDavFile.isDir
                || bookFileRegex.matches(webDavFile.displayName)
                || archiveFileRegex.matches(webDavFile.displayName)
        }
    }
}
