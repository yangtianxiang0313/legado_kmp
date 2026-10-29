package io.legado.kmp.shared.facade

import io.legado.kmp.shared.bootstrap.SharedBootstrap
import io.legado.kmp.shared.domain.localbook.RemoteBookOrigin
import io.legado.kmp.shared.domain.localbook.remoteBookOrigins
import io.legado.kmp.shared.domain.repository.BookRepository
import io.legado.kmp.shared.domain.repository.ServerRepository
import io.legado.kmp.shared.model.RemoteBook
import io.legado.kmp.shared.network.ScopedWebDavClient
import io.legado.kmp.shared.platform.FileAccess
import io.legado.kmp.shared.preferences.AppPreferencesStore
import kotlin.coroutines.cancellation.CancellationException
import kotlin.random.Random
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.koin.mp.KoinPlatformTools

/** Fixed-account DAV management/preparation only. The platform owns GET, atomic storage and import. */
class RemoteBookTransferFacade(
    private val preferences: AppPreferencesStore,
    private val servers: ServerRepository,
    private val files: FileAccess,
    private val books: BookRepository,
) {
    private val mutex = Mutex()
    private val sessions = linkedMapOf<String, RemoteBookSessionState>()

    companion object {
        @Throws(RecoverableSharedException::class)
        fun create(): RemoteBookTransferFacade = try {
            SharedBootstrap.startOrThrow()
            val koin = KoinPlatformTools.defaultContext().get()
            RemoteBookTransferFacade(koin.get(), koin.get(), koin.get(), koin.get())
        } catch (_: Throwable) {
            throw RecoverableSharedException("RemoteBookTransferFacade.create", "远程书库服务不可用，请重试")
        }
    }

    /** Capture only; no PROPFIND, MKCOL or other network side effects. */
    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun openSession(): RemoteBookSession = recoverRemoteBookTransfer("openSession") {
        mutex.withLock {
            val config = captureRemoteBookConfiguration(preferences, servers)
            var id: String
            do {
                id = List(4) { Random.nextLong().toULong().toString(16).padStart(16, '0') }.joinToString("")
            } while (id in sessions)
            val session = RemoteBookSession(id, config.scope.rootUrl, config.serverId, config.title)
            val state = RemoteBookSessionState(session, config)
            gate(state)
            if (sessions.size >= 16) sessions.remove(sessions.keys.first())?.invalidate()
            sessions[id] = state
            session
        }
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun list(sessionId: String, path: String? = null): List<RemoteBook> =
        operation("list", sessionId) { state ->
            val directory = state.config.scope.directory(path ?: state.session.rootUrl)
            val client = ScopedWebDavClient(state.config.scope, state.config.authorization)
            val listed = try {
                client.list(directory) { gate(state) }.filter { RemoteBook.isBookOrDir(it) }.map { RemoteBook.fromWebDavFile(it) }
            } finally {
                client.close()
            }
            gate(state)
            val shelfUrls = mutableSetOf<String>()
            for (book in books.getAllBooks()) {
                currentCoroutineContext().ensureActive()
                for (origin in book.remoteBookOrigins) {
                    if (origin.serverID != state.session.serverId) continue
                    val url = try { state.config.scope.requireUrl(origin.url).url } catch (_: Exception) { null }
                    if (url != null) shelfUrls.add(url)
                }
            }
            gate(state)
            val result = listed.map { it.copy(isOnBookShelf = !it.isDir && it.path in shelfUrls) }
            state.replaceChildren(directory, result)
            result.toList()
        }

    /** GET intent only: no JS, cookie lookup, HTTP, file write, or import here. */
    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun prepareDownload(sessionId: String, remoteBook: RemoteBook): WebBookFileRequest =
        operation("prepareDownload", sessionId) { state ->
            val book = state.requireIssued(remoteBook)
            requireRemoteBookSession(!book.isDir, RemoteBookSessionProblem.FILE)
            val request = WebBookFileRequest(
                url = book.path,
                method = "GET",
                headers = mapOf("Authorization" to state.config.authorization),
                bodyBase64 = null,
                fileName = remoteBookDownloadFileName(book),
                timeoutMillis = 120_000L,
                sourceUrl = state.session.rootUrl,
                headerOriginUrl = book.path,
                explicitCookie = null,
                enabledCookieJar = false,
            )
            if (state.issuedRequests.size >= 256) state.issuedRequests.remove(state.issuedRequests.keys.first())
            state.issuedRequests[request.headerOriginUrl] = request.copy(headers = request.headers.toMap())
            request
        }

    /** The loader retains headerOriginUrl unchanged, disables auto-redirects/cookies and limits hops. */
    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun prepareRedirect(sessionId: String, request: WebBookFileRequest, targetUrl: String): Map<String, String> =
        operation("prepareRedirect", sessionId) { state ->
            val issued = state.issuedRequests[request.headerOriginUrl]
            requireRemoteBookSession(issued != null && request.copy(url = issued.url) == issued,
                RemoteBookSessionProblem.REQUEST)
            val book = state.issuedBooks[request.headerOriginUrl]
            requireRemoteBookSession(book != null && !book.isDir, RemoteBookSessionProblem.ENTRY)
            state.requireIssued(book!!)
            state.config.scope.requireUrl(request.url)
            state.config.scope.requireUrl(request.headerOriginUrl)
            state.config.scope.requireUrl(targetUrl)
            mapOf("Authorization" to state.config.authorization)
        }

    /** Call before/after each native GET hop and before native import/provenance publication. */
    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun validateSession(sessionId: String) {
        operation("validateSession", sessionId) { Unit }
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun remoteOrigin(sessionId: String, remoteBook: RemoteBook): String =
        operation("remoteOrigin", sessionId) { state ->
            val book = state.requireIssued(remoteBook)
            requireRemoteBookSession(!book.isDir, RemoteBookSessionProblem.FILE)
            RemoteBookOrigin.create(book.path, state.session.serverId).encoded
        }

    /** The caller supplies an immutable, trusted local copy; uploads always target this session root. */
    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun uploadFile(sessionId: String, path: String): RemoteBook =
        uploadFileTracked(sessionId, path, RemoteBookMutation(upload = true))

    internal suspend fun uploadFileTracked(sessionId: String, path: String, mutation: RemoteBookMutation): RemoteBook =
        operation("uploadFile", sessionId, mutation) { state ->
            val bytes = readRemoteBookUploadFile(files, path)
            val name = path.substringAfterLast('/')
            val target = state.config.scope.rootFile(name)
            val provisional = RemoteBook(name, target, bytes.size.toLong(), 0L, name.substringAfterLast('.', "").lowercase())
            remoteBookDownloadFileName(provisional)
            gate(state)
            val client = ScopedWebDavClient(state.config.scope, state.config.authorization)
            try {
                client.upload(target, bytes, { gate(state) }, mutation::dispatched, mutation::confirmed)
            } finally {
                client.close()
            }
            gate(state)
            state.revokeTree(target)
            state.issue(provisional)
            provisional
        }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun delete(sessionId: String, remoteBook: RemoteBook) {
        deleteTracked(sessionId, remoteBook, RemoteBookMutation(upload = false))
    }

    internal suspend fun deleteTracked(sessionId: String, remoteBook: RemoteBook, mutation: RemoteBookMutation) {
        operation("delete", sessionId, mutation) { state ->
            val book = state.requireIssued(remoteBook)
            val client = ScopedWebDavClient(state.config.scope, state.config.authorization)
            try {
                client.delete(book.path, { gate(state) }, mutation::dispatched, mutation::confirmed)
            } finally {
                client.close()
            }
            gate(state)
            state.revokeTree(book.path)
        }
    }

    fun openSessionRequest(onResult: (RemoteBookTransferResult) -> Unit): FlowSubscription =
        remoteBookTransferRequest("openSessionRequest", onResult = onResult) {
            RemoteBookTransferResult(session = openSession())
        }

    fun listRequest(sessionId: String, path: String?, onResult: (RemoteBookTransferResult) -> Unit): FlowSubscription =
        remoteBookTransferRequest("listRequest", onResult = onResult) {
            RemoteBookTransferResult(books = list(sessionId, path))
        }

    fun prepareDownloadRequest(
        sessionId: String,
        remoteBook: RemoteBook,
        onResult: (RemoteBookTransferResult) -> Unit,
    ): FlowSubscription = remoteBookTransferRequest("prepareDownloadRequest", onResult = onResult) {
        RemoteBookTransferResult(request = prepareDownload(sessionId, remoteBook))
    }

    fun uploadFileRequest(sessionId: String, path: String, onResult: (RemoteBookTransferResult) -> Unit): FlowSubscription {
        val mutation = RemoteBookMutation(upload = true)
        return remoteBookTransferRequest("uploadFileRequest", mutation, onResult) {
            RemoteBookTransferResult(remoteBook = uploadFileTracked(sessionId, path, mutation))
        }
    }

    fun deleteRequest(sessionId: String, remoteBook: RemoteBook, onResult: (RemoteBookTransferResult) -> Unit): FlowSubscription {
        val mutation = RemoteBookMutation(upload = false)
        return remoteBookTransferRequest("deleteRequest", mutation, onResult) {
            deleteTracked(sessionId, remoteBook, mutation)
            RemoteBookTransferResult(remoteBook = remoteBook)
        }
    }

    private suspend fun <T> operation(
        name: String,
        sessionId: String,
        mutation: RemoteBookMutation? = null,
        block: suspend (RemoteBookSessionState) -> T,
    ): T = recoverRemoteBookTransfer(name, mutation) {
        mutex.withLock {
            val state = sessions[sessionId] ?: throw RemoteBookSessionFailure(RemoteBookSessionProblem.EXPIRED)
            gate(state)
            try {
                block(state)
            } finally {
                gate(state)
            }
        }
    }

    private suspend fun gate(state: RemoteBookSessionState) {
        currentCoroutineContext().ensureActive()
        state.invalidated?.let { throw RemoteBookSessionFailure(it) }
        val current = preferences.runtimeConfig.first()
        val matches = state.config.matches(current, servers)
        currentCoroutineContext().ensureActive()
        if (!matches) {
            state.invalidate(RemoteBookSessionProblem.CHANGED)
            throw RemoteBookSessionFailure(RemoteBookSessionProblem.CHANGED)
        }
    }

    override fun toString(): String = "RemoteBookTransferFacade(redacted)"
}
