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

/** One terminal callback. Mutation cancellation can include an explicit uncertain-outcome message. */
data class RemoteBookTransferResult(
    val session: RemoteBookSession? = null,
    val books: List<RemoteBook> = emptyList(),
    val request: WebBookFileRequest? = null,
    val remoteBook: RemoteBook? = null,
    val errorMessage: String? = null,
    val isCancelled: Boolean = false,
) {
    override fun toString(): String = "RemoteBookTransferResult(redacted)"
}
