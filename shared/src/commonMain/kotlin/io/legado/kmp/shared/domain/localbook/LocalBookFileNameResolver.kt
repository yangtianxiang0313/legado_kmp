package io.legado.kmp.shared.domain.localbook

import io.legado.kmp.shared.content.BookHelp
import io.legado.kmp.shared.network.JsExecutor
import io.legado.kmp.shared.preferences.AppPreferencesStore
import io.legado.kmp.shared.scripting.JsResult
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.coroutines.cancellation.CancellationException

data class LocalBookFileNameResult(
    val name: String,
    val author: String,
)

class LocalBookFileNameResolver(
    private val preferencesStore: AppPreferencesStore? = null,
    private val jsExecutor: JsExecutor = JsExecutor.Default,
) {
    suspend fun resolve(fileName: String): LocalBookFileNameResult {
        currentCoroutineContext().ensureActive()
        val src = fileName.substringBeforeLast('.')
        val rule = preferencesStore?.runtimeConfig?.value?.bookImportFileName
        val custom = if (!rule.isNullOrBlank() && rule.length <= MAX_RULE_LENGTH) {
            resolveCustom(rule, src)
        } else {
            null
        }
        currentCoroutineContext().ensureActive()
        return custom ?: resolveDefault(src)
    }

    private suspend fun resolveCustom(rule: String, src: String): LocalBookFileNameResult? {
        return try {
            // One isolated realm, with no book/source/native bindings and no script replay.
            val result = jsExecutor.withMutableContext(mapOf("src" to src)) { context ->
                context.execute(rule + "\nJSON.stringify({author:author,name:name})")
            }
            currentCoroutineContext().ensureActive()
            if (result is JsResult.JsError) {
                (result.exception as? CancellationException)?.let { throw it }
                return null
            }
            val payload = (result as? JsResult.JsString)?.value ?: return null
            val fields = Json.parseToJsonElement(payload).jsonObject
            val name = fields["name"]?.jsonPrimitive?.contentOrNull.orEmpty()
            if (name.isBlank()) return null
            val author = fields["author"]?.jsonPrimitive?.contentOrNull
                ?.takeIf { it.length != src.length }.orEmpty()
            LocalBookFileNameResult(name, author)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Throwable) {
            currentCoroutineContext().ensureActive()
            // Script/JSON errors can contain the rule or filename; never forward them to diagnostics.
            null
        }
    }

    private fun resolveDefault(src: String): LocalBookFileNameResult {
        for (pattern in nameAuthorPatterns) {
            val match = pattern.find(src) ?: continue
            return LocalBookFileNameResult(
                name = match.groupValues[2],
                author = BookHelp.formatBookAuthor(match.groupValues[1] + match.groupValues[3]),
            )
        }
        val name = BookHelp.formatBookName(src)
        val author = BookHelp.formatBookAuthor(src.replace(name, ""))
            .takeIf { it.length != src.length }.orEmpty()
        return LocalBookFileNameResult(name, author)
    }

    companion object {
        internal const val MAX_RULE_LENGTH = 64 * 1024

        // LocalBook.analyzeNameAuthor at Android revision 5f5d31404; order is significant.
        private val nameAuthorPatterns by lazy {
            listOf(
                Regex("(.*?)\u300a([^\u300a\u300b]+)\u300b.*?\u4f5c\u8005\uff1a(.*)"),
                Regex("(.*?)\u300a([^\u300a\u300b]+)\u300b(.*)"),
                Regex("(^)(.+) \u4f5c\u8005\uff1a(.+)$"),
                Regex("(^)(.+) by (.+)$"),
            )
        }
    }
}
