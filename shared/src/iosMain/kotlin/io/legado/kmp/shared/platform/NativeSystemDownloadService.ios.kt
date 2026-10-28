@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.legado.kmp.shared.platform

import io.legado.kmp.shared.domain.runtime.DownloadService
import io.legado.kmp.shared.domain.runtime.FileDownloadStatus
import io.legado.kmp.shared.domain.runtime.FileDownloadTask
import io.legado.kmp.shared.domain.runtime.ServiceState
import io.legado.kmp.shared.domain.runtime.validateDownloadFileName
import io.legado.kmp.shared.util.currentTimeMillis
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import platform.Foundation.NSBundle
import platform.Foundation.NSData
import platform.Foundation.NSError
import platform.Foundation.NSFileManager
import platform.Foundation.NSFileSize
import platform.Foundation.NSHTTPURLResponse
import platform.Foundation.NSMutableURLRequest
import platform.Foundation.NSNumber
import platform.Foundation.NSOperationQueue
import platform.Foundation.NSRecursiveLock
import platform.Foundation.NSURL
import platform.Foundation.NSURLRequestReloadIgnoringLocalCacheData
import platform.Foundation.NSURLSession
import platform.Foundation.NSURLSessionConfiguration
import platform.Foundation.NSURLSessionDownloadTask
import platform.Foundation.NSURLSessionTask
import platform.Foundation.NSUUID
import platform.Foundation.setHTTPShouldHandleCookies
import platform.Foundation.setValue
import platform.darwin.dispatch_async
import platform.darwin.dispatch_get_main_queue

private object SystemDownloadRuntime {
    val service by lazy { NativeSystemDownloadService() }
}

internal actual fun createSystemDownloadService(): DownloadService = SystemDownloadRuntime.service

actual fun handleSystemDownloadEvents(identifier: String, completion: () -> Unit): Boolean {
    val service = SystemDownloadRuntime.service
    if (identifier != service.identifier) return false
    service.receiveEvents(completion)
    return true
}

/** The session is process-scoped, but transfers and resumption belong to nsurlsessiond. */
internal class NativeSystemDownloadService : DownloadService {
    private class PendingPause {
        val complete = CompletableDeferred<Unit>()
        var terminal = false
        var dataSaved = false
    }

    val identifier = (NSBundle.mainBundle.bundleIdentifier ?: "io.legado.kmp") + ".managed-downloads.v1"
    private val lock = NSRecursiveLock()
    private val commands = Mutex()
    private val store = SystemDownloadStore()
    private val records = linkedMapOf<String, FileDownloadTask>()
    private val nativeTasks = mutableMapOf<String, NSURLSessionDownloadTask>()
    private val pauses = mutableMapOf<String, PendingPause>()
    private val cancellations = mutableMapOf<String, CompletableDeferred<Unit>>()
    private val progressTimes = mutableMapOf<String, Long>()
    private val ready = CompletableDeferred<Unit>()
    private val mutableState = MutableStateFlow(ServiceState(isSupported = true, message = "正在恢复下载任务"))
    override val state: StateFlow<ServiceState> = mutableState.asStateFlow()
    private val mutableDownloads = MutableStateFlow<List<FileDownloadTask>>(emptyList())
    override val downloads: StateFlow<List<FileDownloadTask>> = mutableDownloads.asStateFlow()
    private var eventCompletion: (() -> Unit)? = null
    private var eventsFinished = false
    private var storageFailure = false
    private val delegate = SystemDownloadDelegate(this)
    private val session: NSURLSession

    init {
        try {
            store.loadTasks().forEach { records[it.id] = it }
        } catch (_: Exception) {
            storageFailure = true
        }
        val config = NSURLSessionConfiguration.backgroundSessionConfigurationWithIdentifier(identifier).apply {
            discretionary = false
            sessionSendsLaunchEvents = true
            HTTPMaximumConnectionsPerHost = 3
            HTTPShouldSetCookies = false
            HTTPCookieStorage = null
            URLCredentialStorage = null
            URLCache = null
            requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData
            timeoutIntervalForRequest = 60.0
            timeoutIntervalForResource = 24.0 * 60 * 60
        }
        val queue = NSOperationQueue().apply { maxConcurrentOperationCount = 1 }
        session = NSURLSession.sessionWithConfiguration(config, delegate, queue)
        session.getAllTasksWithCompletionHandler { tasks ->
            guarded {
                val restored = mutableSetOf<String>()
                tasks?.filterIsInstance<NSURLSessionDownloadTask>()?.forEach { native ->
                    val id = native.taskDescription
                    val record = records[id]
                    if (id == null || record == null || !record.isActive) {
                        native.cancel()
                    } else {
                        nativeTasks[id] = native
                        restored += id
                        if (native.countOfBytesReceived > 0) {
                            records[id] = record.copy(
                                status = FileDownloadStatus.DOWNLOADING,
                                bytesDownloaded = native.countOfBytesReceived,
                                totalBytes = native.countOfBytesExpectedToReceive.takeIf { it > 0 },
                            )
                        }
                    }
                }
                for ((id, record) in records.toMap()) {
                    if (record.isActive && id !in restored) records[id] = record.copy(
                        status = FileDownloadStatus.FAILED, errorMessage = "系统下载任务已中断，可重试",
                    )
                }
                try { refreshFilesLocked() } catch (_: Exception) { storageFailure = true }
                saveLocked()
                publishLocked()
                ready.complete(Unit)
            }
        }
    }

    override suspend fun start(url: String, fileName: String) = command {
        val normalized = systemDownloadUrl(url)
        val name = validateDownloadFileName(fileName)
        guarded {
            require(records.size < 2048) { "下载任务过多，请先清空已完成的任务记录" }
            require(records.values.none { it.url == normalized && (it.isActive || it.canResume) }) {
                "该地址已在下载列表中"
            }
            val record = FileDownloadTask(
                id = NSUUID().UUIDString, url = normalized, fileName = name,
                status = FileDownloadStatus.QUEUED, updatedAt = currentTimeMillis(),
            )
            enqueueLocked(record, useResume = false)
        }
    }

    override suspend fun pauseTask(taskId: String) = command {
        val pending = guarded {
            val record = requireNotNull(records[taskId]) { "任务已不存在" }
            if (record.canResume) return@guarded null
            require(record.isActive) { "此任务无法暂停" }
            val native = requireNotNull(nativeTasks[taskId]) { "系统下载任务暂不可用" }
            val pending = PendingPause()
            pauses[taskId] = pending
            records[taskId] = record.copy(status = FileDownloadStatus.PAUSED, updatedAt = currentTimeMillis())
            saveLocked()
            publishLocked()
            native.cancelByProducingResumeData { data ->
                guarded {
                    if (pauses[taskId] !== pending) return@guarded
                    try {
                        store.writeResume(taskId, data)
                        if (data == null) records[taskId]?.let {
                            records[taskId] = it.copy(errorMessage = "服务器未提供断点，继续时将从头下载")
                        }
                    } catch (_: Exception) {
                        records[taskId]?.let {
                            records[taskId] = it.copy(errorMessage = "断点保存失败，继续时将从头下载")
                        }
                    }
                    pending.dataSaved = true
                    saveLocked()
                    finishPauseLocked(taskId, pending)
                    publishLocked()
                }
            }
            pending
        }
        if (pending != null) withTimeout(30_000) { pending.complete.await() }
    }

    override suspend fun resumeTask(taskId: String) = command {
        guarded {
            val record = requireNotNull(records[taskId]) { "任务已不存在" }
            require(record.canResume && pauses[taskId] == null) { "此任务尚未暂停完成" }
            enqueueLocked(record, useResume = true)
        }
    }

    override suspend fun retry(taskId: String) = command {
        guarded {
            val record = requireNotNull(records[taskId]) { "任务已不存在" }
            require(record.canRetry && nativeTasks[taskId] == null) { "此任务无法重试" }
            enqueueLocked(record, useResume = true)
        }
    }

    override suspend fun cancel(url: String) = command {
        val ids = guarded { records.values.filter { it.url == url.trim() && (it.isActive || it.canResume) }.map { it.id } }
        ids.forEach { cancelInternal(it) }
    }

    override suspend fun cancelTask(taskId: String) = command { cancelInternal(taskId) }

    override suspend fun refresh() = command {
        guarded { refreshFilesLocked(); saveLocked(); publishLocked() }
    }

    override suspend fun clear() = command {
        val ids = guarded { records.values.filter { it.isActive || it.canResume }.map { it.id } }
        ids.forEach { cancelInternal(it) }
        guarded {
            records.keys.filter { !it.startsWith("file:") }.forEach { runCatching { store.writeResume(it, null) } }
            records.clear()
            saveLocked()
            publishLocked("任务记录已清空，已下载文件保留")
        }
    }

    private suspend fun command(action: suspend () -> Unit) = withContext(Dispatchers.Default) {
        ready.await()
        commands.withLock { currentCoroutineContext().ensureActive(); action() }
    }

    private suspend fun cancelInternal(id: String) {
        val completion = guarded {
            val record = records[id] ?: return@guarded null
            if (!record.isActive && !record.canResume) return@guarded null
            records[id] = record.copy(status = FileDownloadStatus.CANCELLED, updatedAt = currentTimeMillis(), errorMessage = null)
            runCatching { store.writeResume(id, null) }
            saveLocked()
            publishLocked()
            nativeTasks[id]?.let { native ->
                CompletableDeferred<Unit>().also { cancellations[id] = it; native.cancel() }
            }
        }
        if (completion != null) withContext(NonCancellable) { withTimeout(30_000) { completion.await() } }
    }

    private fun enqueueLocked(record: FileDownloadTask, useResume: Boolean) {
        val url = requireNotNull(record.url) { "任务地址已不存在" }
        systemDownloadUrl(url)
        require(records.values.none { it.id != record.id && it.url == url && (it.isActive || it.canResume) }) {
            "该地址已在下载列表中"
        }
        val data = if (useResume) store.readResume(record.id) else null
        val native = if (data != null) session.downloadTaskWithResumeData(data) else {
            val request = NSMutableURLRequest.requestWithURL(requireNotNull(NSURL.URLWithString(url))).apply {
                setValue("identity", forHTTPHeaderField = "Accept-Encoding")
                setHTTPShouldHandleCookies(false)
            }
            session.downloadTaskWithRequest(request)
        }
        native.taskDescription = record.id
        val next = record.copy(
            status = FileDownloadStatus.QUEUED,
            bytesDownloaded = if (data != null) record.bytesDownloaded else 0,
            totalBytes = if (data != null) record.totalBytes else null,
            localPath = null, errorMessage = null, updatedAt = currentTimeMillis(),
        )
        val previous = records[record.id]
        records[record.id] = next
        try { store.saveTasks(records.values.toList()) } catch (error: Exception) {
            if (previous == null) records.remove(record.id) else records[record.id] = previous
            native.cancel()
            throw error
        }
        nativeTasks[record.id] = native
        publishLocked()
        native.resume()
    }

    internal fun progress(native: NSURLSessionDownloadTask, received: Long, expected: Long) = guarded {
        val id = native.taskDescription ?: return@guarded
        val record = records[id] ?: return@guarded
        if (!record.isActive) return@guarded
        nativeTasks[id] = native
        val now = currentTimeMillis()
        records[id] = record.copy(
            status = FileDownloadStatus.DOWNLOADING, bytesDownloaded = received.coerceAtLeast(0),
            totalBytes = expected.takeIf { it > 0 }, updatedAt = now,
        )
        if (now - (progressTimes[id] ?: 0) >= 500) {
            progressTimes[id] = now
            saveLocked()
            publishLocked()
        }
    }

    internal fun delivered(native: NSURLSessionDownloadTask, location: NSURL) = guarded {
        val id = native.taskDescription ?: return@guarded
        val record = records[id] ?: return@guarded
        if (!record.isActive) return@guarded
        try {
            val response = native.response as? NSHTTPURLResponse ?: error("文件响应无效")
            val path = requireNotNull(location.path) { "下载文件不存在" }
            val size = (NSFileManager.defaultManager.attributesOfItemAtPath(path, null)?.get(NSFileSize) as? NSNumber)
                ?.longLongValue ?: error("无法读取下载文件长度")
            requireSystemDownloadResponse(response, size)
            val file = store.commit(location, record.fileName)
            records[id] = record.copy(
                status = FileDownloadStatus.COMPLETED, fileName = file.fileName,
                bytesDownloaded = file.size, totalBytes = file.size, localPath = file.path,
                errorMessage = null, updatedAt = currentTimeMillis(),
            )
            runCatching { store.writeResume(id, null) }
        } catch (error: Exception) {
            records[id] = record.copy(
                status = FileDownloadStatus.FAILED, errorMessage = safeDeliveryMessage(error), updatedAt = currentTimeMillis(),
            )
        }
        saveLocked()
        publishLocked()
    }

    internal fun completed(native: NSURLSessionTask, error: NSError?) = guarded {
        val id = native.taskDescription ?: return@guarded
        if (nativeTasks[id]?.taskIdentifier == native.taskIdentifier) nativeTasks.remove(id)
        progressTimes.remove(id)
        pauses[id]?.let { pending ->
            pending.terminal = true
            finishPauseLocked(id, pending)
            return@guarded
        }
        val record = records[id]
        if (record?.isActive == true) {
            val resume = error?.userInfo?.get("NSURLSessionDownloadTaskResumeData") as? NSData
            runCatching { store.writeResume(id, resume) }
            records[id] = record.copy(
                status = FileDownloadStatus.FAILED,
                errorMessage = if (error?.code == -1009L) "当前离线，可联网后继续重试" else "下载未完成，请检查网络或存储后重试",
                updatedAt = currentTimeMillis(),
            )
        }
        cancellations.remove(id)?.complete(Unit)
        saveLocked()
        publishLocked()
    }

    private fun finishPauseLocked(id: String, pending: PendingPause) {
        if (pending.terminal && pending.dataSaved) {
            pauses.remove(id)
            pending.complete.complete(Unit)
        }
    }

    private fun refreshFilesLocked() {
        val files = store.listCompleted()
        val byName = files.associateBy { it.fileName }
        records.entries.removeAll { it.value.status == FileDownloadStatus.COMPLETED && it.value.fileName !in byName }
        for (file in files) {
            val prior = records.values.firstOrNull { it.status == FileDownloadStatus.COMPLETED && it.fileName == file.fileName }
            val record = prior?.copy(localPath = file.path, bytesDownloaded = file.size, totalBytes = file.size)
                ?: FileDownloadTask(
                    id = "file:${file.fileName}", url = null, fileName = file.fileName,
                    status = FileDownloadStatus.COMPLETED, bytesDownloaded = file.size, totalBytes = file.size,
                    localPath = file.path, updatedAt = file.modifiedAt,
                )
            records[record.id] = record
        }
    }

    private fun saveLocked() {
        try { store.saveTasks(records.values.toList()); storageFailure = false } catch (_: Exception) { storageFailure = true }
    }

    private fun publishLocked(message: String? = null) {
        mutableDownloads.value = records.values.sortedWith(
            compareByDescending<FileDownloadTask> { it.isActive }.thenByDescending { it.updatedAt },
        )
        val active = records.values.count { it.isActive }
        mutableState.value = ServiceState(
            isSupported = true, isRunning = active > 0,
            isPaused = active == 0 && records.values.any { it.canResume },
            message = if (storageFailure) "下载记录保存失败，已完成文件保留，请刷新重试"
                else message ?: if (active > 0) "正在下载 $active 个文件" else "下载已就绪",
        )
    }

    internal fun receiveEvents(completion: () -> Unit) = guarded {
        eventCompletion?.let { previous -> dispatch_async(dispatch_get_main_queue()) { previous() } }
        eventCompletion = completion
        if (eventsFinished) finishEventCompletionLocked()
    }

    internal fun finishedEvents() = guarded {
        eventsFinished = true
        finishEventCompletionLocked()
    }

    private fun finishEventCompletionLocked() {
        val completion = eventCompletion ?: return
        eventCompletion = null
        eventsFinished = false
        saveLocked()
        dispatch_async(dispatch_get_main_queue()) { completion() }
    }

    private fun safeDeliveryMessage(error: Exception): String =
        error.message?.takeIf { it.length <= 160 && !it.contains("://") && !it.contains('/') }
            ?: "下载完成，但文件校验或保存失败，请重试"

    private inline fun <T> guarded(action: () -> T): T {
        lock.lock()
        try { return action() } finally { lock.unlock() }
    }
}
