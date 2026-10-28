package io.legado.kmp.shared.facade

import io.legado.kmp.shared.bootstrap.SharedBootstrap
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import org.koin.mp.KoinPlatformTools

data class ForegroundWebResponse(val json: String?, val error: String?, val cancelled: Boolean)

/** The foreground HTTP adapter owns authentication and write consent; domain operations stay shared. */
class ForegroundWebFacade private constructor(
    private val shelf: BookshelfFacade,
    private val sources: ForegroundWebSourceSupport,
    private val rules: ForegroundWebRuleSupport,
    private val books: ForegroundWebBookSupport,
    private val reading: ForegroundWebReadingSupport,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    companion object {
        @Throws(RecoverableSharedException::class)
        fun create(): ForegroundWebFacade = try {
            SharedBootstrap.startOrThrow()
            val koin = KoinPlatformTools.defaultContext().get()
            val shelf = SharedBootstrap.bookshelfFacade()
            val reader = SharedBootstrap.readerFacade()
            val details = SharedBootstrap.bookDetailFacade()
            val images = SharedBootstrap.bookImageFacade()
            val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
            val reading = ForegroundWebReadingSupport(
                cache = koin.get(), details = details, shelf = shelf, reader = reader,
                sources = koin.get(), refreshInfo = koin.get(), images = images, json = json,
            )
            ForegroundWebFacade(
                shelf = shelf,
                sources = ForegroundWebSourceSupport(
                    SharedBootstrap.sourceManagementFacade(), SharedBootstrap.rssFacade(), json,
                ),
                rules = ForegroundWebRuleSupport(SharedBootstrap.replaceRuleFacade(), json),
                books = ForegroundWebBookSupport(
                    shelf, details, reader, koin.get(),
                    ReaderProgressUploadQueue(koin.get(), SharedBootstrap.settingsFacade()), json, reading,
                ),
                reading = reading,
            )
        } catch (error: Exception) {
            throw error.asRecoverableSharedException("ForegroundWebFacade.create")
        }
    }

    fun request(method: String, path: String, parameters: String, body: String, onResult: (ForegroundWebResponse) -> Unit): FlowSubscription =
        CancellableFacadeRequest.start(
            prepare = { ForegroundWebResponse(handle(method, path, parameters, body), null, false) },
            cancelledResult = ForegroundWebResponse(null, null, true),
            failureResult = { ForegroundWebResponse(null, it.message ?: "请求失败", false) },
            onResult = onResult, facade = "ForegroundWebFacade", callbackMethod = "request.onResult",
            missingResultMessage = "Web request returned no result",
        )

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun handle(method: String, path: String, parameters: String, body: String): String =
        runRecoverable("ForegroundWeb.handle") {
            currentCoroutineContext().ensureActive()
            require(body.encodeToByteArray().size <= 8 * 1024 * 1024) { "请求正文过大" }
            val request = ForegroundWebRequestSupport(json, parameters, body)
            val data: JsonElement = when (method to path) {
                "GET" to "/getBookshelf" -> json.encodeToJsonElement(shelf.loadBooks(-1))
                "GET" to "/getBookSources" -> sources.getBookSources()
                "GET" to "/getBookSource" -> sources.getBookSource(request.parameter("url"))
                "GET" to "/getRssSources" -> sources.getRssSources()
                "GET" to "/getRssSource" -> sources.getRssSource(request.parameter("url"))
                "GET" to "/getReplaceRules" -> rules.getRules()
                "GET" to "/getReadConfig" -> reading.getReadConfig()
                "GET" to "/getBookInfo" -> reading.getBookInfo(request.parameter("url", "bookUrl"), request.optionalParameter("origin"))
                "GET" to "/cover" -> reading.getCover(request.parameter("url", "bookUrl"), request.optionalParameter("origin"))
                "GET" to "/bookImage" -> reading.getBookImage(
                    request.parameter("url", "bookUrl"), request.parameter("src", "path"), request.optionalParameter("origin"),
                )
                "GET" to "/getChapterList" -> books.getChapterList(request.parameter("url", "bookUrl"), request.optionalParameter("origin"))
                "GET" to "/refreshToc" -> books.refreshToc(request.parameter("url", "bookUrl"))
                "GET" to "/getBookContent" -> books.getBookContent(request)
                "POST" to "/saveBookSource" -> sources.saveBookSource(request.body)
                "POST" to "/saveBookSources" -> sources.saveBookSources(request.body)
                "POST" to "/deleteBookSources" -> sources.deleteBookSources(request)
                "POST" to "/saveRssSource" -> sources.saveRssSource(request.body)
                "POST" to "/saveRssSources" -> sources.saveRssSources(request.body)
                "POST" to "/deleteRssSources" -> sources.deleteRssSources(request)
                "POST" to "/saveReplaceRule" -> rules.saveRule(request.bodyObject())
                "POST" to "/deleteReplaceRule" -> rules.deleteRule(request.bodyObject())
                "POST" to "/testReplaceRule" -> rules.testRule(request.bodyObject())
                "POST" to "/saveReadConfig" -> reading.saveReadConfig(request.body)
                "POST" to "/saveBook" -> reading.saveBook(request)
                "POST" to "/saveBookProgress" -> books.saveProgress(request)
                "POST" to "/deleteBook" -> books.deleteBook(request)
                else -> error("未支持的前台服务接口")
            }
            currentCoroutineContext().ensureActive()
            json.encodeToString(buildJsonObject { put("isSuccess", true); put("errorMsg", ""); put("data", data) })
                .also { require(it.encodeToByteArray().size <= 16 * 1024 * 1024) { "响应过大，请缩小查询范围" } }
        }
}
