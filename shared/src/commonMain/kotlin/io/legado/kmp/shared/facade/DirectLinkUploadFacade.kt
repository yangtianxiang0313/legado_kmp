package io.legado.kmp.shared.facade

import io.legado.kmp.shared.analyze.AnalyzeRule
import io.legado.kmp.shared.network.AnalyzeUrl
import io.legado.kmp.shared.network.CacheStrategy
import io.legado.kmp.shared.network.HttpMethod
import io.legado.kmp.shared.network.HttpRequestConfig
import io.legado.kmp.shared.network.HttpUseCase
import io.legado.kmp.shared.preferences.AppPreferencesStore
import io.legado.kmp.shared.util.currentTimeMillis
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*
import okio.Buffer

@Serializable
data class DirectLinkUploadRule(
    val uploadUrl: String,
    val downloadUrlRule: String,
    val summary: String = "直链上传",
    val compress: Boolean = false,
)

/** Executes Android DirectLinkUpload rules against an explicitly selected file. */
class DirectLinkUploadFacade(
    private val preferences: AppPreferencesStore,
    private val http: HttpUseCase,
) {
    private val json = Json { ignoreUnknownKeys = true; coerceInputValues = true; encodeDefaults = true }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun loadRule(): DirectLinkUploadRule? = withSafeRuleErrors("loadRule") {
        val data = preferences.exportBackupPreferences().appConfig[RULE_KEY]
            ?: return@withSafeRuleErrors null
        json.decodeFromJsonElement(DirectLinkUploadRule.serializer(), data)
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun saveRule(rule: DirectLinkUploadRule) = withSafeRuleErrors("saveRule") {
        if (rule.uploadUrl.isBlank()) invalidRule("上传规则不能为空")
        if (rule.downloadUrlRule.isBlank()) invalidRule("下载链接规则不能为空")
        if (rule.summary.isBlank()) invalidRule("注释不能为空")
        ruleMutex.withLock {
            // Only replace the four editable fields; retain any extra Android configuration fields.
            val original = preferences.getBackupConfigJson(RULE_KEY)?.let {
                runCatching { json.parseToJsonElement(it) as? JsonObject }.getOrNull()
            }
            val edited = json.encodeToJsonElement(DirectLinkUploadRule.serializer(), rule).jsonObject
            preferences.setBackupConfigJson(RULE_KEY, JsonObject(original.orEmpty() + edited).toString())
        }
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun deleteRule() = withSafeRuleErrors("deleteRule") {
        ruleMutex.withLock { preferences.setBackupConfigJson(RULE_KEY, null) }
    }

    @OptIn(ExperimentalEncodingApi::class)
    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun upload(fileName: String, base64Data: String, contentType: String): String =
        runRecoverable("DirectLinkUpload.upload") {
            val rule = requireNotNull(loadRule()) { "尚未配置直链上传规则，请先新建规则" }
            require(rule.uploadUrl.isNotBlank() && rule.downloadUrlRule.isNotBlank()) { "上传地址或下载链接规则为空" }
            require(base64Data.length <= 45 * 1024 * 1024) { "上传文件超过 32 MB" }
            var bytes = Base64.decode(base64Data)
            require(bytes.size <= 32 * 1024 * 1024) { "上传文件超过 32 MB" }
            var name = fileName.replace('\\', '/').substringAfterLast('/').ifBlank { "upload.json" }
            var mime = contentType.ifBlank { "application/octet-stream" }
            if (rule.compress && mime != "application/zip") {
                bytes = buildDirectLinkZip(name, bytes)
                name += ".zip"
                mime = "application/zip"
            }
            try {
                val request = AnalyzeUrl().build(rule.uploadUrl)
                require(request.url.startsWith("https://") || request.url.startsWith("http://")) { "上传地址无效" }
                require(request.proxy.isNullOrBlank()) { "此上传规则指定了代理，请先移除代理选项" }
                val fields = request.body?.let { json.parseToJsonElement(it) as? JsonObject }
                    ?: error("上传规则缺少 multipart body 配置")
                require(fields.values.any { (it as? JsonPrimitive)?.contentOrNull == "fileRequest" }) {
                    "上传规则缺少 fileRequest 文件字段"
                }
                val boundary = "LegadoUpload${currentTimeMillis()}"
                val body = Buffer()
                fields.forEach { (key, value) ->
                    body.writeUtf8("--$boundary\r\n")
                    if ((value as? JsonPrimitive)?.contentOrNull == "fileRequest") {
                        body.writeUtf8("Content-Disposition: form-data; name=\"${headerValue(key)}\"; filename=\"${headerValue(name)}\"\r\n")
                        body.writeUtf8("Content-Type: ${headerValue(mime)}\r\n\r\n")
                        body.write(bytes)
                    } else {
                        body.writeUtf8("Content-Disposition: form-data; name=\"${headerValue(key)}\"\r\n\r\n")
                        body.writeUtf8((value as? JsonPrimitive)?.content ?: value.toString())
                    }
                    body.writeUtf8("\r\n")
                }
                body.writeUtf8("--$boundary--\r\n")
                val headers = request.headers.filterKeys { !it.equals("Content-Type", true) } +
                    ("Content-Type" to "multipart/form-data; boundary=$boundary")
                val response = http.execute(HttpRequestConfig(
                    url = request.url, method = HttpMethod.POST, headers = headers,
                    bodyBytes = body.readByteArray(), cacheStrategy = CacheStrategy.NoCache,
                )).getOrThrow()
                require(response.isSuccessful) { "上传失败：HTTP ${response.statusCode}" }
                val link = AnalyzeRule(httpUseCase = http).setContent(response.bodyText, response.url.ifBlank { request.url })
                    .getString(rule.downloadUrlRule).trim()
                require(link.startsWith("https://") || link.startsWith("http://")) { "上传服务未返回有效下载链接" }
                link
            } catch (error: CancellationException) {
                throw error
            } catch (error: IllegalArgumentException) {
                throw IllegalStateException("上传规则或返回链接无效，请检查直链上传配置")
            } catch (_: Exception) {
                // Network errors and response bodies may contain credentials or uploaded content.
                throw IllegalStateException("直链上传失败，请检查网络、上传规则及服务状态")
            }
        }

    private fun headerValue(value: String): String = value.replace("\r", "").replace("\n", "").replace("\"", "_")

    private fun invalidRule(message: String): Nothing =
        throw RecoverableSharedException("DirectLinkUpload.invalidRule", message)

    private suspend fun <T> withSafeRuleErrors(operation: String, block: suspend () -> T): T =
        runRecoverable("DirectLinkUpload.$operation") {
            try {
                block()
            } catch (error: CancellationException) {
                throw error
            } catch (error: RecoverableSharedException) {
                throw error
            } catch (_: Exception) {
                throw RecoverableSharedException(
                    "DirectLinkUpload.$operation", "直链上传配置读写失败，请检查规则后重试",
                )
            }
        }

    private companion object {
        const val RULE_KEY = "android.directLinkUploadRule.json"
        val ruleMutex = Mutex()
    }
}
