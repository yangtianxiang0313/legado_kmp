package io.legado.kmp.shared.facade

import io.legado.kmp.shared.platform.FileAccess
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

internal class RemoteBookUploadFileSnapshot(
    val path: String,
    val fileName: String,
    val byteCount: Long,
    val lastModified: Long,
) {
    override fun toString(): String = "RemoteBookUploadFileSnapshot(redacted)"
}

/** The platform owns the trusted, immutable local copy until finish/discard has settled. */
internal suspend fun prepareRemoteBookUploadFile(files: FileAccess, path: String): RemoteBookUploadFileSnapshot =
    withContext(Dispatchers.Default) {
        requireRemoteBookSession(path.length <= 16_384 && path.startsWith('/') && !path.endsWith('/') &&
            !path.startsWith("//") && path.none { it.isISOControl() || it == '\\' } &&
            path.removePrefix("/").split('/').none { it.isEmpty() || it == "." || it == ".." },
            RemoteBookSessionProblem.LOCAL_FILE)
        currentCoroutineContext().ensureActive()
        val modified = files.lastModified(path)
            ?: throw RemoteBookSessionFailure(RemoteBookSessionProblem.UPLOAD_LOCAL_CHANGED)
        val size = files.getSize(path)
        requireRemoteBookSession(size in 1L..MAX_REMOTE_BOOK_UPLOAD_BYTES, RemoteBookSessionProblem.UPLOAD_FILE_LIMIT)
        val snapshot = RemoteBookUploadFileSnapshot(path, path.substringAfterLast('/'), size, modified)
        currentCoroutineContext().ensureActive()
        val source = files.openRead(path)
        try {
            currentCoroutineContext().ensureActive()
            requireRemoteBookSession(source.size == size, RemoteBookSessionProblem.UPLOAD_LOCAL_CHANGED)
        } finally {
            source.closeSource()
        }
        validateRemoteBookUploadFile(files, snapshot)
        snapshot
    }

/** Metadata only; do not reopen or read the content that native URLSession will stream. */
internal suspend fun validateRemoteBookUploadFile(files: FileAccess, snapshot: RemoteBookUploadFileSnapshot) {
    withContext(Dispatchers.Default) {
        currentCoroutineContext().ensureActive()
        val modified = files.lastModified(snapshot.path)
        val size = files.getSize(snapshot.path)
        val endingModified = files.lastModified(snapshot.path)
        currentCoroutineContext().ensureActive()
        requireRemoteBookSession(modified == snapshot.lastModified && endingModified == snapshot.lastModified &&
            size == snapshot.byteCount, RemoteBookSessionProblem.UPLOAD_LOCAL_CHANGED)
    }
}

private const val MAX_REMOTE_BOOK_UPLOAD_BYTES = 2L * 1024 * 1024 * 1024
