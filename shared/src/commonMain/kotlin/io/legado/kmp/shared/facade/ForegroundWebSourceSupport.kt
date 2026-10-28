package io.legado.kmp.shared.facade

import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.model.RssSource
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.put

internal class ForegroundWebSourceSupport(
    private val sources: SourceManagementFacade,
    private val rss: RssFacade,
    private val json: Json,
) {
    suspend fun getBookSources(): JsonElement = json.parseToJsonElement(
        sources.exportSources(sources.getAllSources().map { it.bookSourceUrl }),
    )

    suspend fun getBookSource(url: String): JsonElement = json.parseToJsonElement(sources.exportSource(url))

    suspend fun saveBookSource(body: String): JsonElement =
        json.encodeToJsonElement(sources.saveSource(json.decodeFromString<BookSource>(body)))

    suspend fun saveBookSources(body: String): JsonElement {
        // Keep the existing import preview and response fields used by the bundled client.
        val preview = sources.previewSourceImport(body)
        require(preview.candidates.isNotEmpty()) { "没有可导入的书源" }
        val result = sources.importSources(body)
        return buildJsonObject {
            put("importedCount", result.importedCount)
            put("addedCount", result.addedCount)
            put("updatedCount", result.updatedCount)
            put("invalidCount", result.invalidCount)
        }
    }

    suspend fun deleteBookSources(request: ForegroundWebRequestSupport): JsonElement {
        sources.deleteSources(sourceUrls(request, "bookSourceUrl"))
        return JsonPrimitive("已执行")
    }

    suspend fun getRssSources(): JsonElement {
        val sources = rss.getAllSources()
        require(sources.isNotEmpty()) { "源列表为空" }
        return json.encodeToJsonElement(sources)
    }

    suspend fun getRssSource(url: String): JsonElement = json.encodeToJsonElement(
        requireNotNull(rss.getSource(url)) { "未找到源，请检查源地址" },
    )

    suspend fun saveRssSource(body: String): JsonElement {
        rss.saveRssSource(json.decodeFromString<RssSource>(body))
        return JsonPrimitive("")
    }

    suspend fun saveRssSources(body: String): JsonElement {
        // Decode every item before writing; Android skips entries without a name or URL.
        val candidates = json.decodeFromString<List<RssSource>>(body)
        require(candidates.isNotEmpty()) { "转换源失败" }
        val valid = candidates.filter { it.isValid }
        require(valid.isNotEmpty()) { "没有可保存的 RSS 源" }
        val saved = valid.map { source ->
            currentCoroutineContext().ensureActive()
            rss.saveRssSource(source)
        }
        return json.encodeToJsonElement(saved)
    }

    suspend fun deleteRssSources(request: ForegroundWebRequestSupport): JsonElement {
        rss.deleteRssSources(sourceUrls(request, "sourceUrl"))
        return JsonPrimitive("已执行")
    }

    private fun sourceUrls(request: ForegroundWebRequestSupport, key: String): List<String> {
        val urls = request.bodyArray().map { element ->
            val source = element as? JsonObject ?: error("源必须为 JSON 对象")
            source.foregroundWebString(key)?.trim()?.takeIf(String::isNotEmpty)
                ?: error("源地址不能为空：$key")
        }.distinct()
        require(urls.isNotEmpty()) { "没有可删除的源" }
        return urls
    }
}
