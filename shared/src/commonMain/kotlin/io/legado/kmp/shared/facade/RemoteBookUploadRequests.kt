package io.legado.kmp.shared.facade

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch

/** Settle cancelled preparation and reclaim any unpublished handle before its terminal callback. */
internal fun remoteBookUploadPreparationRequest(
    onResult: (RemoteBookTransferResult) -> Unit,
    prepare: suspend () -> PreparedRemoteBookUpload,
    discard: suspend (PreparedRemoteBookUpload) -> Unit,
): FlowSubscription {
    val prepared = MutableStateFlow<PreparedRemoteBookUpload?>(null)
    val terminal = CompletableDeferred<RemoteBookTransferResult>()
    val deliveryScope = CoroutineScope(Dispatchers.Default)
    deliveryScope.launch {
        try {
            val result = terminal.await()
            val upload = prepared.value
            if (upload != null && upload !== result.upload) discard(upload)
            try {
                onResult(result)
            } catch (_: Throwable) {
                result.upload?.let { discard(it) }
                CrashCollector.record(
                    "RemoteBookTransferFacade",
                    "prepareUploadFileRequest.onResult",
                    error = IllegalStateException("Remote book transfer callback failed"),
                )
            }
        } finally {
            deliveryScope.cancel()
        }
    }
    return remoteBookTransferRequest("prepareUploadFileRequest", onResult = { terminal.complete(it) }) {
        val upload = prepare()
        prepared.value = upload
        RemoteBookTransferResult(upload = upload)
    }
}
