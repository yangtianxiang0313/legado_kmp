package io.legado.kmp.shared.facade

import io.legado.kmp.shared.bootstrap.SharedBootstrap
import kotlinx.serialization.json.Json
import org.koin.mp.KoinPlatformTools

data class ForegroundWebStreamEvent(
    val text: String? = null,
    val closeReason: String? = null,
    val failed: Boolean = false,
)

/** The transport owns authentication, frame handling and consent; each request owns its work. */
class ForegroundWebStreamFacade private constructor(
    private val search: ForegroundWebStreamSearchSupport,
    private val bookDebug: BookSourceDebugFacade,
    private val rssDebug: ForegroundWebStreamRssSupport,
) {
    companion object {
        @Throws(RecoverableSharedException::class)
        fun create(): ForegroundWebStreamFacade = try {
            SharedBootstrap.startOrThrow()
            val koin = KoinPlatformTools.defaultContext().get()
            ForegroundWebStreamFacade(
                search = ForegroundWebStreamSearchSupport(koin.get(), koin.get(), koin.get(), koin.get()),
                bookDebug = SharedBootstrap.bookSourceDebugFacade(),
                rssDebug = ForegroundWebStreamRssSupport(koin.get(), koin.get()),
            )
        } catch (error: Exception) {
            throw error.asRecoverableSharedException("ForegroundWebStreamFacade.create")
        }
    }

    /** Progress is serialized in the background; completion may run on the cancelling thread. */
    fun request(
        path: String,
        body: String,
        onEvent: (ForegroundWebStreamEvent) -> Unit,
    ): FlowSubscription {
        val closeReason = if (path == "/searchBook") "Search finish" else "调试结束"
        return ForegroundWebStreamSession.start(closeReason, onEvent) { output ->
            val request = ForegroundWebStreamInput(body)
            when (path) {
                "/searchBook" -> search.run(request, output)
                "/bookSourceDebug" -> {
                    val tag = request.requiredString("tag", 8 * 1024)
                    val key = request.requiredString("key", 8 * 1024)
                    val report = bookDebug.debugSourceWithLogs(tag, key) { line ->
                        if (line.state !in rawPageStates) {
                            output.send(line.message)
                            if (line.state == -1) output.markFailed()
                        }
                    }
                    if (!report.success) output.markFailed()
                }
                "/rssSourceDebug" -> rssDebug.run(request.requiredString("tag", 8 * 1024), output)
                else -> error("未支持的前台 WebSocket 接口")
            }
        }
    }
}

private val rawPageStates = setOf(10, 20, 30, 40)

internal val foregroundWebStreamJson = Json { ignoreUnknownKeys = true; encodeDefaults = true }
