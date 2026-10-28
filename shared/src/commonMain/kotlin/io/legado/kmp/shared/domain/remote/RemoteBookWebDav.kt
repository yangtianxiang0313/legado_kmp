package io.legado.kmp.shared.domain.remote

import io.legado.kmp.shared.model.RemoteBook
import io.legado.kmp.shared.network.WebDavClient

/**
 * WebDAV implementation of RemoteBookManager.
 * Mirrors legado RemoteBookWebDav.
 */
class RemoteBookWebDav(
    private val rootBookUrl: String,
    private val username: String,
    private val password: String,
    private val webDavClient: WebDavClient,
    val serverID: Long? = null
) : RemoteBookManager() {

    /**
     * Ensure the root book directory exists on the WebDAV server.
     */
    suspend fun initDir() {
        webDavClient.makeDir(rootBookUrl, username, password)
    }

    override suspend fun getRemoteBookList(path: String): List<RemoteBook> {
        val webDavFiles = webDavClient.listFiles(path, username, password)
        return webDavFiles
            .filter { RemoteBook.isBookOrDir(it) }
            .map { RemoteBook.fromWebDavFile(it) }
    }

    override suspend fun getRemoteBook(path: String): RemoteBook? {
        val files = webDavClient.listFiles(path, username, password)
        // PROPFIND with Depth:1 returns the resource itself plus children.
        // We look for an exact match on path.
        val normalized = path.trimEnd('/')
        val file = files.firstOrNull {
            it.path.trimEnd('/') == normalized
        } ?: return null
        return RemoteBook.fromWebDavFile(file)
    }

    override suspend fun downloadRemoteBook(remoteBook: RemoteBook): ByteArray {
        return webDavClient.download(remoteBook.path, username, password)
    }

    override suspend fun upload(fileName: String, fileBytes: ByteArray) {
        val putUrl = if (rootBookUrl.endsWith("/")) {
            "$rootBookUrl$fileName"
        } else {
            "$rootBookUrl/$fileName"
        }
        webDavClient.upload(putUrl, username, password, fileBytes)
    }

    override suspend fun delete(remoteBookUrl: String) {
        webDavClient.delete(remoteBookUrl, username, password)
    }
}
