package io.legado.kmp.shared.data.repository

import app.cash.sqldelight.coroutines.asFlow
import app.cash.sqldelight.coroutines.mapToList
import io.legado.kmp.shared.data.database.LegadoDatabase
import io.legado.kmp.shared.domain.repository.RssStarRepository
import io.legado.kmp.shared.model.RssStar
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow

class RssStarRepositoryImpl(
    private val database: LegadoDatabase
) : RssStarRepository {

    override suspend fun getAll(): List<RssStar> {
        return database.rssStarQueries.selectAllRssStars(mapper = ::mapStar).executeAsList()
    }

    override fun observeGroups(): Flow<List<String>> {
        return database.rssStarQueries.selectRssStarGroups()
            .asFlow()
            .mapToList(Dispatchers.Default)
    }

    override fun observeByGroup(group: String): Flow<List<RssStar>> {
        return database.rssStarQueries.selectRssStarsByGroup(group, mapper = ::mapStar)
            .asFlow()
            .mapToList(Dispatchers.Default)
    }

    override suspend fun get(origin: String, link: String): RssStar? {
        return database.rssStarQueries.selectRssStarByOriginAndLink(origin, link, mapper = ::mapStar).executeAsOneOrNull()
    }

    override fun observeAll(): Flow<List<RssStar>> {
        return database.rssStarQueries.selectAllRssStars(mapper = ::mapStar)
            .asFlow()
            .mapToList(Dispatchers.Default)
    }

    override suspend fun insert(vararg rssStar: RssStar) {
        rssStar.forEach {
            database.rssStarQueries.insertRssStar(
                origin = it.origin,
                sort = it.sort,
                title = it.title,
                star_time = it.starTime,
                link = it.link,
                pub_date = it.pubDate,
                description = it.description,
                content = it.content,
                image = it.image,
                star_group = it.group,
                variable = it.variable
            )
        }
    }

    override suspend fun update(vararg rssStar: RssStar) {
        rssStar.forEach {
            database.rssStarQueries.updateRssStar(
                sort = it.sort,
                title = it.title,
                star_time = it.starTime,
                pub_date = it.pubDate,
                description = it.description,
                content = it.content,
                image = it.image,
                star_group = it.group,
                variable = it.variable,
                origin = it.origin,
                link = it.link
            )
        }
    }

    override suspend fun retainContent(origin: String, link: String, content: String) {
        database.rssStarQueries.retainRssStarContent(content = content, origin = origin, link = link)
    }

    override suspend fun updateOrigin(origin: String, oldOrigin: String) {
        database.rssStarQueries.updateRssStarOrigin(origin, oldOrigin)
    }

    override suspend fun delete(origin: String) {
        database.rssStarQueries.deleteRssStarsByOrigin(origin)
    }

    override suspend fun delete(origin: String, link: String) {
        database.rssStarQueries.deleteRssStarByOriginAndLink(origin, link)
    }

    override suspend fun deleteByGroup(group: String) {
        database.rssStarQueries.deleteRssStarsByGroup(group)
    }

    override suspend fun deleteAll() {
        database.rssStarQueries.deleteAllRssStars()
    }

    private fun mapStar(
        origin: String,
        sort: String,
        title: String,
        star_time: Long,
        link: String,
        pub_date: String?,
        description: String?,
        content: String?,
        image: String?,
        star_group: String,
        variable: String?
    ): RssStar {
        return RssStar(
            origin = origin,
            sort = sort,
            title = title,
            starTime = star_time,
            link = link,
            pubDate = pub_date,
            description = description,
            content = content,
            image = image,
            group = star_group,
            variable = variable
        )
    }
}
