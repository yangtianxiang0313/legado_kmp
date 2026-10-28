package io.legado.kmp.shared.facade

import io.legado.kmp.shared.domain.repository.RssSourceRepository
import io.legado.kmp.shared.domain.rss.RssService
import io.legado.kmp.shared.model.RssArticle
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

internal class ForegroundWebStreamRssSupport(
    private val sources: RssSourceRepository,
    private val service: RssService,
) {
    suspend fun run(sourceUrl: String, output: ForegroundWebStreamOutput) {
        val source = sources.getByKey(sourceUrl) ?: error("订阅源不存在：$sourceUrl")
        currentCoroutineContext().ensureActive()
        output.send("︾开始解析")
        val sort = service.getSortUrls(source).getOrThrow().firstOrNull() ?: error("订阅源没有可用分类")
        currentCoroutineContext().ensureActive()
        // Use the parser service directly: no article inserts, read records, favorites or source updates.
        val (articles, nextPage) = service.getArticles(sort.first, sort.second, source, 1).getOrThrow()
        currentCoroutineContext().ensureActive()
        output.send("列表页解析返回 ${articles.size} 条")
        nextPage?.takeIf(String::isNotBlank)?.let { output.send("下一页链接：$it") }
        val article = articles.firstOrNull()
        if (article == null) {
            output.send("⇒列表页解析成功，为空")
            output.send("︽解析完成")
            return
        }
        sendArticle(article, output)
        if (source.ruleArticles.isNullOrBlank() || !source.ruleDescription.isNullOrBlank()) {
            output.send("⇒存在描述规则，不解析内容页")
            output.send("︽解析完成")
            return
        }
        output.send("︽列表页解析完成")
        if (source.ruleContent.isNullOrEmpty()) {
            output.send("⇒内容规则为空，默认获取整个网页")
            return
        }
        output.send("︾开始解析内容页")
        val content = service.getContent(article, source).getOrThrow()
        currentCoroutineContext().ensureActive()
        output.send(content)
        output.send("︽内容页解析完成")
    }

    private fun sendArticle(article: RssArticle, output: ForegroundWebStreamOutput) {
        // Values come from the completed production parse, not a second rule evaluator or canned log.
        output.send("标题：${article.title}")
        article.pubDate?.let { output.send("时间：$it") }
        article.description?.let { output.send("描述：$it") }
        article.image?.let { output.send("图片链接：$it") }
        output.send("文章链接：${article.link}")
        article.content?.let { output.send(it) }
    }
}
