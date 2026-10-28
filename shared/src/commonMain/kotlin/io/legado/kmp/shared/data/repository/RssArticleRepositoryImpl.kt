package io.legado.kmp.shared.data.repository

import app.cash.sqldelight.coroutines.asFlow
import app.cash.sqldelight.coroutines.mapToList
import io.legado.kmp.shared.data.database.LegadoDatabase
import io.legado.kmp.shared.domain.repository.RssArticleRepository
import io.legado.kmp.shared.model.RssArticle
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow

class RssArticleRepositoryImpl(
    private val database: LegadoDatabase
) : RssArticleRepository {

    override suspend fun get(origin: String, link: String): RssArticle? {
        return database.rssArticleQueries.selectRssArticleByLink(origin, link, mapper = ::mapArticle).executeAsOneOrNull()
    }

    override fun observeByOriginSort(origin: String, sort: String): Flow<List<RssArticle>> {
        return database.rssArticleQueries.selectRssArticlesByOriginSort(origin, sort, mapper = ::mapArticle)
            .asFlow()
            .mapToList(Dispatchers.Default)
    }

    override suspend fun insert(vararg rssArticle: RssArticle) {
        rssArticle.forEach {
            database.rssArticleQueries.insertRssArticle(
                origin = it.origin,
                sort = it.sort,
                title = it.title,
                sort_order = it.order,
                link = it.link,
                pub_date = it.pubDate,
                description = it.description,
                content = it.content,
                image = it.image,
                article_group = it.group,
                read = if (it.read) 1L else 0L,
                variable = it.variable
            )
        }
    }

    override suspend fun append(vararg rssArticle: RssArticle) {
        rssArticle.forEach {
            database.rssArticleQueries.appendRssArticle(
                origin = it.origin,
                sort = it.sort,
                title = it.title,
                sort_order = it.order,
                link = it.link,
                pub_date = it.pubDate,
                description = it.description,
                content = it.content,
                image = it.image,
                article_group = it.group,
                read = if (it.read) 1L else 0L,
                variable = it.variable
            )
        }
    }

    override suspend fun clearOld(origin: String, sort: String, order: Long) {
        database.rssArticleQueries.clearOldRssArticles(origin, sort, order)
    }

    override suspend fun update(vararg rssArticle: RssArticle) {
        rssArticle.forEach {
            database.rssArticleQueries.updateRssArticle(
                sort = it.sort,
                title = it.title,
                sort_order = it.order,
                pub_date = it.pubDate,
                description = it.description,
                content = it.content,
                image = it.image,
                article_group = it.group,
                read = if (it.read) 1L else 0L,
                variable = it.variable,
                origin = it.origin,
                link = it.link
            )
        }
    }

    override suspend fun updateOrigin(origin: String, oldOrigin: String) {
        database.rssArticleQueries.updateRssArticleOrigin(origin, oldOrigin)
    }

    override suspend fun delete(origin: String) {
        database.rssArticleQueries.deleteRssArticlesByOrigin(origin)
    }

    private fun mapArticle(
        origin: String,
        sort: String,
        title: String,
        sort_order: Long,
        link: String,
        pub_date: String?,
        description: String?,
        content: String?,
        image: String?,
        article_group: String,
        read: Long,
        variable: String?
    ): RssArticle {
        return RssArticle(
            origin = origin,
            sort = sort,
            title = title,
            order = sort_order,
            link = link,
            pubDate = pub_date,
            description = description,
            content = content,
            image = image,
            group = article_group,
            read = read == 1L,
            variable = variable
        )
    }
}
