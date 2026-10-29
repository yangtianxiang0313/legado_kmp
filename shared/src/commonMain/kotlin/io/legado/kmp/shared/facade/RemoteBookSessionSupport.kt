package io.legado.kmp.shared.facade

import io.legado.kmp.shared.domain.repository.ServerRepository
import io.legado.kmp.shared.model.RemoteBook
import io.legado.kmp.shared.model.Server
import io.legado.kmp.shared.model.ServerType
import io.legado.kmp.shared.network.ScopedWebDavFailure
import io.legado.kmp.shared.network.ScopedWebDavScope
import io.legado.kmp.shared.platform.FileAccess
import io.legado.kmp.shared.preferences.AppPreferencesStore
import io.legado.kmp.shared.preferences.AppRuntimeConfig
import kotlin.coroutines.cancellation.CancellationException
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json

internal enum class RemoteBookSessionProblem(val userMessage: String) {
    CONFIGURATION("远程书库配置无效，请检查服务器地址与凭据"),
    UNAVAILABLE("所选远程服务器不存在或不可用，请重新选择"),
    EXPIRED("远程书库会话已失效，请重新打开远程书库"),
    CHANGED("远程书库账号或原配置已变化，请重新打开，未切换到其他账号"),
    ENTRY("远程条目不是当前会话签发的内容，请刷新列表后重新选择"),
    FILE("请选择有效的远程书籍文件，不能下载文件夹"),
    REQUEST("下载请求已失效或被修改，请重新选择远程文件"),
    LOCAL_FILE("请选择可信的本地安全副本文件路径"),
    FILE_LIMIT("上传文件为空或超过 128 MiB 限制"),
    LOCAL_CHANGED("本地安全副本已变化或读取不完整，未开始上传"),
    LIMIT("当前会话签发的条目过多，请重新打开远程书库"),
}

internal class RemoteBookSessionFailure(val problem: RemoteBookSessionProblem) : Exception(problem.userMessage) {
    override fun toString(): String = "RemoteBookSessionFailure(${problem.name})"
}

internal fun requireRemoteBookSession(condition: Boolean, problem: RemoteBookSessionProblem) {
    if (!condition) throw RemoteBookSessionFailure(problem)
}

/** Deliberately not a data class: neither snapshots nor Basic Auth may enter logs. */
internal class RemoteBookSessionConfiguration(
    private val preferences: AppRuntimeConfig,
    private val server: Server?,
) {
    val serverId: Long = preferences.remoteServerId
    val scope: ScopedWebDavScope
    val authorization: String
    val title: String

    init {
        requireRemoteBookSession(serverId >= 0L, RemoteBookSessionProblem.CONFIGURATION)
        val username: String
        val password: String
        if (serverId > 0L) {
            requireRemoteBookSession(server != null && server.id == serverId && server.type == ServerType.WEBDAV &&
                server.config != null && server.config.length <= 64 * 1024, RemoteBookSessionProblem.UNAVAILABLE)
            val config = try {
                Json { ignoreUnknownKeys = true }.decodeFromString(Server.WebDavConfig.serializer(), server!!.config!!)
            } catch (_: Exception) {
                throw RemoteBookSessionFailure(RemoteBookSessionProblem.CONFIGURATION)
            }
            username = config.username
            password = config.password
            requireRemoteBookSession(config.url.isNotBlank(), RemoteBookSessionProblem.CONFIGURATION)
            scope = ScopedWebDavScope(config.url.trim())
            title = remoteBookSafeText(server!!.name, 160).ifBlank { "WebDAV" }
        } else {
            username = preferences.webDavAccount.orEmpty()
            password = preferences.webDavPassword.orEmpty()
            requireRemoteBookSession(username.isNotBlank() && password.isNotBlank(), RemoteBookSessionProblem.CONFIGURATION)
            val base = ScopedWebDavScope(preferences.webDavUrl?.trim().orEmpty().ifEmpty { DEFAULT_URL })
            val directory = preferences.webDavDir.trim().trim('/')
            val parts = if (directory.isEmpty()) emptyList() else directory.split('/')
            scope = ScopedWebDavScope(base.childRoot(parts + "books"))
            title = "WebDAV"
        }
        requireRemoteBookSession(username.length <= 4096 && password.length <= 4096 && ':' !in username &&
            username.none { it.isISOControl() } && password.none { it.isISOControl() }, RemoteBookSessionProblem.CONFIGURATION)
        authorization = remoteBookBasicAuth(username, password)
    }

    suspend fun matches(current: AppRuntimeConfig, servers: ServerRepository): Boolean {
        if (current.remoteServerId != serverId) return false
        return if (serverId > 0L) servers.get(serverId) == server
        else preferences.webDavUrl == current.webDavUrl && preferences.webDavDir == current.webDavDir &&
            preferences.webDavAccount == current.webDavAccount && preferences.webDavPassword == current.webDavPassword
    }

    override fun toString(): String = "RemoteBookSessionConfiguration(redacted)"

    private companion object {
        const val DEFAULT_URL = "https://dav.jianguoyun.com/dav/"
    }
}

@OptIn(ExperimentalEncodingApi::class)
private fun remoteBookBasicAuth(username: String, password: String): String =
    "Basic " + Base64.encode("$username:$password".encodeToByteArray())

internal suspend fun captureRemoteBookConfiguration(
    preferences: AppPreferencesStore,
    servers: ServerRepository,
): RemoteBookSessionConfiguration {
    val config = preferences.runtimeConfig.first()
    currentCoroutineContext().ensureActive()
    val server = if (config.remoteServerId > 0L) servers.get(config.remoteServerId) else null
    return RemoteBookSessionConfiguration(config, server)
}

internal class RemoteBookSessionState(val session: RemoteBookSession, val config: RemoteBookSessionConfiguration) {
    var invalidated: RemoteBookSessionProblem? = null
        private set
    val issuedBooks = linkedMapOf<String, RemoteBook>()
    val issuedRequests = linkedMapOf<String, WebBookFileRequest>()
    private val issuedSegments = linkedMapOf<String, List<String>>()

    fun invalidate(problem: RemoteBookSessionProblem = RemoteBookSessionProblem.EXPIRED) {
        invalidated = problem
        issuedBooks.clear()
        issuedRequests.clear()
        issuedSegments.clear()
    }

    fun requireIssued(book: RemoteBook): RemoteBook {
        requireRemoteBookSession(issuedBooks[book.path] == book, RemoteBookSessionProblem.ENTRY)
        val target = config.scope.requireUrl(book.path)
        requireRemoteBookSession(target.url == book.path && target.segments != config.scope.rootSegments,
            RemoteBookSessionProblem.ENTRY)
        return book
    }

    fun issue(book: RemoteBook) {
        requireRemoteBookSession(issuedBooks.size < 20_000 || book.path in issuedBooks, RemoteBookSessionProblem.LIMIT)
        val segments = config.scope.requireUrl(book.path).segments
        issuedBooks[book.path] = book.copy()
        issuedSegments[book.path] = segments
        issuedRequests.remove(book.path)
    }

    fun revokeTree(path: String) {
        val segments = config.scope.requireUrl(path).segments
        val stale = issuedSegments.filterValues { it.take(segments.size) == segments }.keys.toList()
        stale.forEach(::revoke)
    }

    fun replaceChildren(directory: String, books: List<RemoteBook>) {
        val parent = config.scope.requireUrl(directory).segments
        val next = books.associateBy { it.path }
        val nextNames = books.map { config.scope.requireUrl(it.path).segments.last() }.toSet()
        val changedNames = issuedSegments.filter { (path, segments) ->
            segments.dropLast(1) == parent && next[path] != issuedBooks[path]
        }.values.map { it.last() }.toSet()
        val stale = issuedSegments.filterValues { segments ->
            segments.size > parent.size && segments.take(parent.size) == parent &&
                (segments[parent.size] !in nextNames || segments[parent.size] in changedNames)
        }.keys.toSet()
        requireRemoteBookSession(issuedBooks.size - stale.size + books.count { it.path !in issuedBooks || it.path in stale } <= 20_000,
            RemoteBookSessionProblem.LIMIT)
        stale.forEach(::revoke)
        // Retain issued requests for byte-for-byte unchanged entries when merely refreshing a list.
        books.forEach { if (issuedBooks[it.path] != it) issue(it) }
    }

    private fun revoke(path: String) {
        issuedBooks.remove(path)
        issuedRequests.remove(path)
        issuedSegments.remove(path)
    }

    override fun toString(): String = "RemoteBookSessionState(redacted)"
}

internal enum class RemoteBookMutationPhase { NOT_SENT, DISPATCHED, CONFIRMED }

internal class RemoteBookMutation(private val upload: Boolean) {
    private val phase = MutableStateFlow(RemoteBookMutationPhase.NOT_SENT)

    fun dispatched() { phase.value = RemoteBookMutationPhase.DISPATCHED }
    fun confirmed() { phase.value = RemoteBookMutationPhase.CONFIRMED }

    fun outcomeMessage(): String? = when (phase.value) {
        RemoteBookMutationPhase.NOT_SENT -> null
        RemoteBookMutationPhase.DISPATCHED -> if (upload)
            "上传结果未知，远端可能已写入文件；取消不会撤销上传，请刷新远程目录确认，勿直接重试"
            else "删除结果未知，远端可能已删除条目；取消不会恢复文件，请刷新远程目录确认"
        RemoteBookMutationPhase.CONFIRMED -> if (upload)
            "服务器已确认上传，但操作未正常返回；取消不会撤销上传，请重新打开原服务器目录确认，勿重复上传"
            else "服务器已确认条目已删除或不存在，但操作未正常返回；取消不会恢复文件，请刷新确认"
    }

    override fun toString(): String = "RemoteBookMutation(redacted)"
}

/** No CrashCollector or raw cause: transport, URL, repository and file errors can contain secrets. */
internal suspend fun <T> recoverRemoteBookTransfer(
    operation: String,
    mutation: RemoteBookMutation? = null,
    block: suspend () -> T,
): T = try {
    currentCoroutineContext().ensureActive()
    block().also { currentCoroutineContext().ensureActive() }
} catch (error: Throwable) {
    if (findFacadeRequestCancellation(error) != null) {
        throw CancellationException(mutation?.outcomeMessage() ?: "远程书库操作已取消")
    }
    val failureMessage = when (error) {
        is RemoteBookSessionFailure -> error.problem.userMessage
        is ScopedWebDavFailure -> error.problem.userMessage
        else -> "远程书库操作失败，请检查配置或网络后重试"
    }
    val outcome = mutation?.outcomeMessage()
    val message = if (outcome == null) failureMessage
        else if (error is RemoteBookSessionFailure) "$failureMessage；$outcome" else outcome
    throw RecoverableSharedException("RemoteBookTransferFacade.$operation", message)
}

/** The platform must pass its own immutable security-scoped copy, never a URL/document-provider path. */
internal suspend fun readRemoteBookUploadFile(files: FileAccess, path: String): ByteArray = withContext(Dispatchers.Default) {
    requireRemoteBookSession(path.length <= 16_384 && path.startsWith('/') && !path.endsWith('/') &&
        !path.startsWith("//") && path.none { it.isISOControl() || it == '\\' } &&
        path.removePrefix("/").split('/').none { it.isEmpty() || it == "." || it == ".." }, RemoteBookSessionProblem.LOCAL_FILE)
    currentCoroutineContext().ensureActive()
    val modified = files.lastModified(path)
    val source = files.openRead(path)
    try {
        requireRemoteBookSession(source.size in 1L..(128L * 1024 * 1024), RemoteBookSessionProblem.FILE_LIMIT)
        val result = ByteArray(source.size.toInt())
        var offset = 0
        while (offset < result.size) {
            currentCoroutineContext().ensureActive()
            val count = minOf(64 * 1024, result.size - offset)
            val chunk = source.read(offset.toLong(), count)
            requireRemoteBookSession(chunk.isNotEmpty() && chunk.size <= count, RemoteBookSessionProblem.LOCAL_CHANGED)
            chunk.copyInto(result, offset)
            offset += chunk.size
        }
        currentCoroutineContext().ensureActive()
        requireRemoteBookSession(files.getSize(path) == source.size && files.lastModified(path) == modified,
            RemoteBookSessionProblem.LOCAL_CHANGED)
        result
    } finally {
        source.closeSource()
    }
}

internal fun remoteBookDownloadFileName(book: RemoteBook): String {
    val suffix = book.filename.substringAfterLast('.', "").lowercase()
    requireRemoteBookSession(suffix in setOf("txt", "epub", "umd", "pdf", "mobi", "azw3", "azw", "zip", "rar", "7z"),
        RemoteBookSessionProblem.FILE)
    return remoteBookSafeText(book.filename.substringBeforeLast('.'), 180).trim().trim('.').ifBlank { "download" } + ".$suffix"
}

internal fun remoteBookSafeText(raw: String, byteLimit: Int): String {
    val result = StringBuilder()
    var index = 0
    var bytes = 0
    while (index < raw.length) {
        val char = raw[index]
        val paired = char.isHighSurrogate() && raw.getOrNull(index + 1)?.isLowSurrogate() == true
        val piece = when {
            paired -> raw.substring(index, index + 2)
            char.isSurrogate() || char.isISOControl() || char in "/\\:*?\"<>|%#" ||
                char in '\u202A'..'\u202E' || char in '\u2066'..'\u2069' || char in "\u200E\u200F" -> "_"
            else -> char.toString()
        }
        val size = piece.encodeToByteArray().size
        if (bytes + size > byteLimit) break
        result.append(piece)
        bytes += size
        index += if (paired) 2 else 1
    }
    return result.toString().trim()
}
