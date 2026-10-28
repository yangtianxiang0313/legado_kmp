package io.legado.kmp.shared.domain.localbook

import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookType
import kotlin.coroutines.cancellation.CancellationException

interface LocalBookFileStore {
    suspend fun read(path: String): ByteArray
    suspend fun lastModified(path: String): Long?
    suspend fun openRead(path: String): LocalBookByteSource
}

interface ArchiveBookRecovery {
    suspend fun recover(book: Book): Book?
}

interface RemoteBookDownloader {
    suspend fun download(book: Book): Book?
}

class LocalBookFileResolver(
    private val fileStore: LocalBookFileStore,
    private val archiveRecovery: ArchiveBookRecovery,
    private val remoteBookDownloader: RemoteBookDownloader
) {
    suspend fun resolve(book: Book): Book {
        if (fileStore.lastModified(book.bookUrl) != null) return book
        return recover(book)
    }

    suspend fun read(book: Book): ResolvedLocalBook {
        try {
            return ResolvedLocalBook(book, fileStore.read(book.bookUrl))
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            // Resolve a moved/archive/remote book only after an actual read failure.
        }

        val resolvedBook = resolve(book)
        val bytes = fileStore.read(resolvedBook.bookUrl)
        return ResolvedLocalBook(resolvedBook, bytes)
    }

    suspend fun openRead(book: Book): ResolvedLocalBookSource {
        try {
            return ResolvedLocalBookSource(book, fileStore.openRead(book.bookUrl))
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            val resolvedBook = resolve(book)
            return ResolvedLocalBookSource(resolvedBook, fileStore.openRead(resolvedBook.bookUrl))
        }
    }

    suspend fun lastModified(book: Book): Long? {
        fileStore.lastModified(book.bookUrl)?.let { return it }
        val recoveredBook = resolve(book)
        return fileStore.lastModified(recoveredBook.bookUrl)
    }

    private suspend fun recover(book: Book): Book {
        val archiveRecovered = if (book.archiveContainerName != null) {
            archiveRecovery.recover(book)
        } else {
            null
        }
        if (archiveRecovered != null && fileStore.lastModified(archiveRecovered.bookUrl) != null) {
            return archiveRecovered
        }

        val remoteRecovered = if (book.remoteUrl != null) {
            remoteBookDownloader.download(book)
        } else {
            null
        }
        if (remoteRecovered != null && fileStore.lastModified(remoteRecovered.bookUrl) != null) {
            return remoteRecovered
        }

        return book
    }
}

data class ResolvedLocalBook(
    val book: Book,
    val bytes: ByteArray
)

data class ResolvedLocalBookSource(val book: Book, val source: LocalBookByteSource)

val Book.archiveContainerName: String?
    get() = when {
        origin.startsWith("${BookType.LOCAL_TAG}::") -> origin.substringAfter("::")
        origin.startsWith("${BookType.LEGACY_LOCAL_TAG}::") -> origin.substringAfter("::")
        else -> null
    }?.takeIf { it.isNotBlank() }

val Book.remoteUrl: String?
    get() = when {
        origin.startsWith(BookType.WEBDAV_TAG) -> origin.removePrefix(BookType.WEBDAV_TAG)
        origin.startsWith("webDav::") -> origin.removePrefix("webDav::")
        origin.startsWith("webdav::") -> origin.removePrefix("webdav::")
        else -> null
    }?.takeIf { it.isNotBlank() }
