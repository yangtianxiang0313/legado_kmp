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
        if (fileStore.lastModified(LocalBookFileBinding.path(book)) != null) return book
        check(LocalBookFileBinding.boundPath(book) == null) { "Retained local book file is missing" }
        return recover(book)
    }

    suspend fun read(book: Book): ResolvedLocalBook {
        val path = LocalBookFileBinding.path(book)
        try {
            return ResolvedLocalBook(book, fileStore.read(path))
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            if (LocalBookFileBinding.boundPath(book) != null) throw error
            // Resolve a moved/archive/remote book only after an actual read failure.
        }

        val resolvedBook = resolve(book)
        val bytes = fileStore.read(LocalBookFileBinding.path(resolvedBook))
        return ResolvedLocalBook(resolvedBook, bytes)
    }

    suspend fun openRead(book: Book): ResolvedLocalBookSource {
        val path = LocalBookFileBinding.path(book)
        try {
            return ResolvedLocalBookSource(book, fileStore.openRead(path))
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            if (LocalBookFileBinding.boundPath(book) != null) throw error
            val resolvedBook = resolve(book)
            return ResolvedLocalBookSource(resolvedBook, fileStore.openRead(LocalBookFileBinding.path(resolvedBook)))
        }
    }

    suspend fun lastModified(book: Book): Long? {
        fileStore.lastModified(LocalBookFileBinding.path(book))?.let { return it }
        if (LocalBookFileBinding.boundPath(book) != null) return null
        val recoveredBook = resolve(book)
        return fileStore.lastModified(LocalBookFileBinding.path(recoveredBook))
    }

    private suspend fun recover(book: Book): Book {
        val archiveRecovered = if (book.archiveContainerName != null) {
            archiveRecovery.recover(book)
        } else {
            null
        }
        if (archiveRecovered != null && fileStore.lastModified(LocalBookFileBinding.path(archiveRecovered)) != null) {
            return archiveRecovered
        }

        val remoteRecovered = if (book.archiveContainerName == null && book.origin.startsWith(BookType.WEBDAV_TAG, true)) {
            remoteBookDownloader.download(book)
        } else {
            null
        }
        if (remoteRecovered != null) {
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
    get() = if (archiveContainerName == null && type and BookType.ARCHIVE == 0) RemoteBookOrigin.parseOrNull(origin)?.url else null
