package io.legado.kmp.shared.domain.usecase

import io.legado.kmp.shared.domain.rss.RssService
import io.legado.kmp.shared.domain.repository.RssSourceRepository
import io.legado.kmp.shared.model.RssArticle
import io.legado.kmp.shared.model.RssSource
import kotlinx.coroutines.flow.Flow

class ObserveEnabledRssSourcesUseCase(
    private val repository: RssSourceRepository
) {
    operator fun invoke(): Flow<List<RssSource>> = repository.observeEnabled()
}

class GetRssSortUrlsUseCase(
    private val service: RssService
) {
    suspend operator fun invoke(source: RssSource): Result<List<Pair<String, String>>> = service.getSortUrls(source)
    suspend fun clearCache(source: RssSource) = service.clearSortCache(source)
}

class FetchRssArticlesUseCase(
    private val service: RssService
) {
    suspend operator fun invoke(
        sortName: String,
        sortUrl: String,
        source: RssSource,
        page: Int = 1
    ): Result<Pair<List<RssArticle>, String?>> = service.getArticles(sortName, sortUrl, source, page)
}

class FetchRssContentUseCase(
    private val service: RssService
) {
    suspend operator fun invoke(article: RssArticle, source: RssSource): Result<String> = service.getContent(article, source)
}
