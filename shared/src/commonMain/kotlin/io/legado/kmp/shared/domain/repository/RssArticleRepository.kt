package io.legado.kmp.shared.domain.repository

import io.legado.kmp.shared.model.RssArticle
import kotlinx.coroutines.flow.Flow

interface RssArticleRepository {
    suspend fun get(origin: String, link: String): RssArticle?
    fun observeByOriginSort(origin: String, sort: String): Flow<List<RssArticle>>

    suspend fun insert(vararg rssArticle: RssArticle)
    suspend fun append(vararg rssArticle: RssArticle)
    suspend fun clearOld(origin: String, sort: String, order: Long)
    suspend fun update(vararg rssArticle: RssArticle)
    suspend fun updateOrigin(origin: String, oldOrigin: String)
    suspend fun delete(origin: String)
}
