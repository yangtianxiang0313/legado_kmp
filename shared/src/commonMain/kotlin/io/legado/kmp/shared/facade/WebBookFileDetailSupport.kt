package io.legado.kmp.shared.facade

import io.legado.kmp.shared.domain.webBook.BookInfo
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.model.serializeVariableMap
import io.legado.kmp.shared.network.JsExecutor
import io.legado.kmp.shared.network.SourceHeaderResolver
import io.legado.kmp.shared.network.SourceRequestExecutor
import io.legado.kmp.shared.scripting.SourceJsRuntime
import io.legado.kmp.shared.source.SourceStateStore
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/** Same detail parser and transport, without the repository's raw redirect println or any book save. */
internal class WebBookFileDetailLoader(
    private val executor: SourceRequestExecutor,
    private val state: SourceStateStore,
    private val jsExecutor: JsExecutor,
    private val headerResolver: SourceHeaderResolver,
    private val runtime: SourceJsRuntime,
) {
    suspend fun refreshInfo(source: BookSource, book: Book): Book {
        val variables = webBookFileRuleData(book).toMutableMap()
        var written: Map<String, String> = emptyMap()
        val context = executor.prepareFileRequest(book.bookUrl, source, source.bookSourceUrl, variables) {
            written = it
        }
        requireWebBookFile(context.request.serverId == null, "unsupported", "文件详情暂不支持远程服务器请求")
        webBookFileUrl(context.requestConfig.url)
        requireWebBookFileHeaders(context.defaultHeaders)
        requireWebBookFileHeaders(context.request.headers)
        requireWebBookFileHeaders(context.requestConfig.headers)
        requireWebBookFile(webBookFileBounded(context.requestConfig.body.orEmpty(), WebBookFileLimits.BODY_BYTES),
            "bodyTooLarge", "文件详情请求正文超过 1 MiB 限制")
        variables.putAll(written)
        currentCoroutineContext().ensureActive()
        val response = executor.executeText(
            request = context.request,
            source = source,
            defaultHeaders = context.defaultHeaders,
            ruleData = variables,
        ).getOrThrow()
        currentCoroutineContext().ensureActive()
        requireWebBookFile(webBookFileBounded(response.bodyText, WebBookFileLimits.DETAIL_BYTES),
            "detailTooLarge", "文件详情响应超过大小限制")
        val bookWithVariables = if (written.isEmpty()) book.copy() else {
            book.copy(variable = serializeVariableMap(book.variableMap + written))
        }
        return BookInfo.getBookInfo(
            bookSource = source,
            book = bookWithVariables,
            baseUrl = book.bookUrl,
            body = response.bodyText,
            redirectUrl = response.finalUrl.ifBlank { context.request.url },
            sourceStateStore = state,
            jsExecutor = jsExecutor,
            connectGateway = executor,
            headerResolver = headerResolver,
            sourceJsRuntime = runtime,
        )
    }
}
