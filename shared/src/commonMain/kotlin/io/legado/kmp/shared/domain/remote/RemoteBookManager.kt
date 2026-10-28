package io.legado.kmp.shared.domain.remote

import io.legado.kmp.shared.model.RemoteBook

/**
 * Abstract remote book manager matching legado RemoteBookManager.
 * Provides operations for listing, downloading, uploading and deleting
 * books on a remote storage backend.
 */
abstract class RemoteBookManager {

    /**
     * Get list of remote books at the given path.
     */
    @Throws(Exception::class)
    abstract suspend fun getRemoteBookList(path: String): List<RemoteBook>

    /**
     * Get a single remote book by path.
     */
    @Throws(Exception::class)
    abstract suspend fun getRemoteBook(path: String): RemoteBook?

    /**
     * Download a remote book. Returns the raw file bytes.
     */
    @Throws(Exception::class)
    abstract suspend fun downloadRemoteBook(remoteBook: RemoteBook): ByteArray

    /**
     * Upload a book's file bytes to the remote storage.
     */
    @Throws(Exception::class)
    abstract suspend fun upload(fileName: String, fileBytes: ByteArray)

    /**
     * Delete a remote book by its URL/path.
     */
    @Throws(Exception::class)
    abstract suspend fun delete(remoteBookUrl: String)
}
