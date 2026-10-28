package io.legado.kmp.shared.facade

import io.legado.kmp.shared.bootstrap.SharedBootstrap
import io.legado.kmp.shared.domain.repository.RssStarRepository
import io.legado.kmp.shared.model.RssArticle
import io.legado.kmp.shared.model.RssStar
import io.legado.kmp.shared.util.currentTimeMillis
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import org.koin.mp.KoinPlatformTools

/** Explicit favorite commands; saving never toggles an existing favorite off. */
class RssArticleFavoritesFacade(
    private val repository: RssStarRepository,
) {
    companion object {
        @Throws(RecoverableSharedException::class)
        fun create(): RssArticleFavoritesFacade = try {
            SharedBootstrap.startOrThrow()
            val koin = KoinPlatformTools.defaultContext().get()
            RssArticleFavoritesFacade(koin.get())
        } catch (error: Exception) {
            throw error.asRecoverableSharedException("RssArticleFavoritesFacade.create")
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun getFavorite(origin: String, link: String): RssStar? =
        runRecoverable("RssArticleFavoritesFacade.getFavorite") {
            withContext(Dispatchers.Default) {
                repository.get(origin, link)
            }
        }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun saveFavorite(article: RssArticle, title: String, group: String): RssStar =
        runRecoverable("RssArticleFavoritesFacade.saveFavorite") {
            withContext(Dispatchers.Default) {
                // Read at submission time: the editor's article may predate retained content or variables.
                val existing = repository.get(article.origin, article.link)
                val saved = (existing ?: article.toStar(currentTimeMillis())).copy(title = title, group = group)
                if (existing == null) {
                    repository.insert(saved)
                } else {
                    repository.update(saved)
                }
                saved
            }
        }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun retainContent(origin: String, link: String, content: String): Unit =
        runRecoverable("RssArticleFavoritesFacade.retainContent") {
            require(content.isNotBlank()) { "订阅正文不能为空" }
            withContext(Dispatchers.Default) {
                // A targeted update cannot recreate a deleted favorite or overwrite its edited metadata.
                repository.retainContent(origin, link, content)
            }
        }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun deleteFavorite(origin: String, link: String): Unit =
        runRecoverable("RssArticleFavoritesFacade.deleteFavorite") {
            withContext(Dispatchers.Default) {
                repository.delete(origin, link)
            }
        }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun favoriteGroups(): List<String> = runRecoverable("RssArticleFavoritesFacade.favoriteGroups") {
        withContext(Dispatchers.Default) {
            repository.observeGroups().first()
        }
    }
}
