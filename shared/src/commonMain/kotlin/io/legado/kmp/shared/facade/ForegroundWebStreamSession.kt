package io.legado.kmp.shared.facade

import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

internal object ForegroundWebStreamSession {
    fun start(
        closeReason: String,
        onEvent: (ForegroundWebStreamEvent) -> Unit,
        block: suspend (ForegroundWebStreamOutput) -> Unit,
    ): FlowSubscription {
        val owner = Job()
        val output = ForegroundWebStreamOutput(owner, onEvent)
        val worker = CoroutineScope(Dispatchers.Default + owner).launch(start = CoroutineStart.LAZY) {
            try {
                withTimeout(5 * 60_000L) { block(output) }
                currentCoroutineContext().ensureActive()
            } catch (error: TimeoutCancellationException) {
                currentCoroutineContext().ensureActive()
                output.fail("请求超时，请缩小搜索范围或检查源配置")
            } catch (error: Throwable) {
                currentCoroutineContext().ensureActive()
                findFacadeRequestCancellation(error)?.let { throw it }
                output.fail(error.message?.takeIf(String::isNotBlank) ?: "请求失败")
            }
        }
        worker.invokeOnCompletion { cause ->
            try {
                output.complete(closeReason, cause)
            } finally {
                owner.complete()
            }
        }
        worker.start()
        return FlowSubscription(owner)
    }
}

/** Only the request coroutine emits progress; completion runs after all its children have stopped. */
internal class ForegroundWebStreamOutput(
    private val owner: Job,
    private val onEvent: (ForegroundWebStreamEvent) -> Unit,
) {
    private var totalBytes = 0
    private var eventCount = 0
    private var failed = false
    private var failureMessage: String? = null
    private var consumerBroken = false
    private var completed = false

    fun send(text: String) {
        owner.ensureActive()
        if (text.length > MAX_FRAME_BYTES) stopForLimit()
        val bytes = text.encodeToByteArray().size
        if (bytes > MAX_FRAME_BYTES || bytes > MAX_TOTAL_BYTES - totalBytes || eventCount >= MAX_EVENTS) {
            stopForLimit()
        }
        totalBytes += bytes
        eventCount++
        if (!deliver(ForegroundWebStreamEvent(text = text))) {
            throw CancellationException("WebSocket event consumer is unavailable")
        }
        owner.ensureActive()
    }

    fun markFailed() {
        failed = true
    }

    fun fail(message: String) {
        failed = true
        if (failureMessage == null) failureMessage = message.take(1024)
    }

    private fun stopForLimit(): Nothing {
        fail("流式响应超过上限，请缩小搜索范围或调试内容")
        // Existing parsers preserve callback cancellation, unlike ordinary callback exceptions.
        throw CancellationException("WebSocket output limit exceeded")
    }

    fun complete(closeReason: String, cause: Throwable?) {
        if (completed) return
        completed = true
        if (cause != null && findFacadeRequestCancellation(cause) == null) {
            fail(cause.message ?: "请求失败")
        }
        // One small error and the close event are reserved outside the data budget.
        failureMessage?.let { deliver(ForegroundWebStreamEvent(text = it, failed = true)) }
        deliver(ForegroundWebStreamEvent(closeReason = closeReason, failed = failed))
    }

    private fun deliver(event: ForegroundWebStreamEvent): Boolean {
        if (consumerBroken) return false
        return try {
            onEvent(event)
            true
        } catch (error: Throwable) {
            consumerBroken = true
            if (findFacadeRequestCancellation(error) == null) {
                CrashCollector.record("ForegroundWebStreamFacade", "request.onEvent", error = error)
            }
            false
        }
    }

    companion object {
        const val MAX_FRAME_BYTES = 512 * 1024
        private const val MAX_TOTAL_BYTES = 16 * 1024 * 1024
        private const val MAX_EVENTS = 4096
    }
}

internal class ForegroundWebStreamInput(body: String) {
    private val values: JsonObject

    init {
        require(body.length <= 64 * 1024 && body.encodeToByteArray().size <= 64 * 1024) { "请求正文过大" }
        checkDepth(body)
        values = try {
            foregroundWebStreamJson.parseToJsonElement(body) as? JsonObject
                ?: error("数据必须为Json对象格式")
        } catch (error: Exception) {
            throw IllegalArgumentException("数据必须为Json对象格式", error)
        }
    }

    fun requiredString(name: String, maxLength: Int): String {
        return optionalString(name, maxLength)?.trim()?.takeIf(String::isNotEmpty)
            ?: error("$name 不能为空")
    }

    fun optionalString(name: String, maxLength: Int): String? {
        val value = values[name]?.takeUnless { it == JsonNull } ?: return null
        require(value is JsonPrimitive && value.isString) { "$name 必须为字符串" }
        require(value.content.length <= maxLength) { "$name 过长" }
        return value.content
    }

    // Reject excessive nesting before the JSON parser allocates a recursive tree.
    private fun checkDepth(body: String) {
        var quoted = false
        var escaped = false
        var depth = 0
        body.forEach { char ->
            if (quoted) {
                when {
                    escaped -> escaped = false
                    char == '\\' -> escaped = true
                    char == '"' -> quoted = false
                }
            } else {
                when (char) {
                    '"' -> quoted = true
                    '{', '[' -> {
                        depth++
                        require(depth <= 16) { "请求Json嵌套过深" }
                    }
                    '}', ']' -> depth--
                }
            }
        }
    }
}
