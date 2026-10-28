package io.legado.kmp.shared.facade

import io.legado.kmp.shared.domain.repository.HttpTTSRepository
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.network.LegacyJsConnectGateway
import io.legado.kmp.shared.network.PreparedMediaRequest
import io.legado.kmp.shared.preferences.AppPreferencesStore
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.CancellationException
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi

/** Runs restored speech URL rules through the normal AnalyzeUrl / HTTP source pipeline. */
class HttpSpeechFacade(
    private val engines: HttpTTSRepository,
    private val preferences: AppPreferencesStore,
    private val gateway: LegacyJsConnectGateway,
) {
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun prepare(text: String, speechRate: Float): PreparedMediaRequest = runRecoverable("HttpSpeech.prepare") {
        val (url, source) = speechSource(text)
        try {
            if (!source.loginCheckJs.isNullOrBlank()) {
                throw io.legado.kmp.shared.network.UnsupportedMediaRequestException(
                    "HTTP 流式朗读不支持响应登录校验或响应改写脚本，请关闭流式播放",
                )
            }
            gateway.prepareMediaForLegacyJs(
                urlRule = url, source = source,
                baseUrl = url.substringBefore(","),
                ruleData = speechVariables(text, speechRate),
            )
        } catch (error: CancellationException) {
            throw error
        } catch (error: io.legado.kmp.shared.network.UnsupportedMediaRequestException) {
            throw IllegalStateException(error.message ?: "HTTP 朗读引擎含不支持的媒体选项")
        } catch (_: Exception) {
            throw IllegalStateException("HTTP 朗读请求准备失败，请检查网络和引擎配置")
        }
    }

    private suspend fun speechSource(text: String): Pair<String, BookSource> {
        require(text.isNotBlank()) { "朗读文本为空" }
        val selected = preferences.runtimeConfig.first().ttsEngine?.removePrefix("httpTts:")?.toLongOrNull()
        val engine = requireNotNull(selected?.let { engines.get(it) }) { "HTTP 朗读引擎不存在，请重新选择" }
        return engine.url to BookSource(
            bookSourceUrl = engine.key, bookSourceName = engine.name,
            jsLib = engine.jsLib, header = engine.header,
            enabledCookieJar = engine.enabledCookieJar,
            loginUrl = engine.loginUrl, loginCheckJs = engine.loginCheckJs,
            concurrentRate = engine.concurrentRate,
        )
    }

    private fun speechVariables(text: String, speechRate: Float): Map<String, Any?> = mapOf(
        "speakText" to text, "speakSpeed" to (speechRate.coerceIn(0.5f, 5f) * 10).toInt(), "text" to text,
    )

    /** Compatibility mode: the 16 MiB cap is checked AFTER the legacy transport materializes the response. */
    @OptIn(ExperimentalEncodingApi::class)
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun synthesize(text: String, speechRate: Float): String = runRecoverable("HttpSpeech.synthesize") {
        val (url, source) = speechSource(text)
        val response = try { gateway.executeForLegacyJsRaw(
            urlRule = url, source = source,
            baseUrl = url.substringBefore(","),
            ruleData = speechVariables(text, speechRate),
        ) } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            // Transport exceptions can contain URLs, request headers, or tokens.
            throw IllegalStateException("HTTP 朗读请求失败，请检查网络和引擎配置")
        }
        require(response.statusCode in 200..299) { "朗读请求失败：HTTP ${response.statusCode}" }
        require(response.body.isNotEmpty()) { "朗读服务返回了空音频" }
        require(response.body.size <= 16 * 1024 * 1024) { "朗读音频超过 16 MiB 上限" }
        Base64.encode(response.body)
    }
}
