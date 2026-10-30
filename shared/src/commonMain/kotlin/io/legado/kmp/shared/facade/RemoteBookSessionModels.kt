package io.legado.kmp.shared.facade

import io.legado.kmp.shared.model.RemoteBook

/** Opaque handle for one fixed account/root snapshot; it contains no credentials. */
data class RemoteBookSession(
    val id: String,
    val rootUrl: String,
    val serverId: Long,
    val title: String,
) {
    override fun toString(): String = "RemoteBookSession(redacted)"
}

/** One opaque PUT intent. Only the issuing facade can validate or consume this instance. */
class PreparedRemoteBookUpload internal constructor(
    val url: String,
    headers: Map<String, String>,
    val localPath: String,
    val fileName: String,
    val byteCount: Long,
) {
    private val requestHeaders = headers.toMap()
    val headers: Map<String, String> get() = requestHeaders.toMap()

    override fun toString(): String = "PreparedRemoteBookUpload(redacted)"
}

/** One terminal callback. Mutation cancellation can include an explicit uncertain-outcome message. */
data class RemoteBookTransferResult(
    val session: RemoteBookSession? = null,
    val books: List<RemoteBook> = emptyList(),
    val request: WebBookFileRequest? = null,
    val remoteBook: RemoteBook? = null,
    val errorMessage: String? = null,
    val isCancelled: Boolean = false,
    val upload: PreparedRemoteBookUpload? = null,
) {
    override fun toString(): String = "RemoteBookTransferResult(redacted)"
}
