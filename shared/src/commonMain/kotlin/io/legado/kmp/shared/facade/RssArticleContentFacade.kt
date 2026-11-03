package io.legado.kmp.shared.facade

import io.legado.kmp.shared.bootstrap.SharedBootstrap
import io.legado.kmp.shared.domain.repository.RssArticleRepository
import io.legado.kmp.shared.domain.repository.RssStarRepository
import io.legado.kmp.shared.model.RssArticle
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import org.koin.mp.KoinPlatformTools
import kotlin.coroutines.cancellation.CancellationException

class RssArticleContentFacade(
    private val articleRepository: RssArticleRepository,
    private val starRepository: RssStarRepository,
) {
    companion object {
        @Throws(RecoverableSharedException::class)
        fun create(): RssArticleContentFacade = try {
            SharedBootstrap.startOrThrow()
            val koin = KoinPlatformTools.defaultContext().get()
            RssArticleContentFacade(koin.get(), koin.get())
        } catch (error: Exception) {
            throw error.asRecoverableSharedException("RssArticleContentFacade.create")
        }
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun loadArticle(article: RssArticle): RssArticle =
        runRecoverable("RssArticleContentFacade.loadArticle") {
            withContext(Dispatchers.Default) {
                currentCoroutineContext().ensureActive()
                val favorite = starRepository.get(article.origin, article.link)
                if (favorite != null) {
                    return@withContext favorite.toRssArticle(read = article.read)
                }
                if (article.hasBody()) return@withContext article
                val cached = articleRepository.get(article.origin, article.link)
                // A fresh feed owns metadata and request variables; only borrow its missing body from cache.
                cached?.takeIf { it.hasBody() }?.let {
                    article.copy(content = it.content?.takeIf(String::isNotBlank) ?: it.description)
                } ?: article
            }
        }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun retainContent(article: RssArticle, content: String): Unit =
        runRecoverable("RssArticleContentFacade.retainContent") {
            currentCoroutineContext().ensureActive()
            require(content.isNotBlank()) { "RSS article content must not be blank" }
            withContext(Dispatchers.Default) {
                currentCoroutineContext().ensureActive()
                articleRepository.retainContent(article, content)
                currentCoroutineContext().ensureActive()
                starRepository.retainContent(article.origin, article.link, content)
                currentCoroutineContext().ensureActive()
            }
        }

    private fun RssArticle.hasBody(): Boolean = !content.isNullOrBlank() || !description.isNullOrBlank()
}
