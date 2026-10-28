package io.legado.kmp.shared.domain.usecase

import io.legado.kmp.shared.domain.repository.RssReadRecordRepository
import io.legado.kmp.shared.domain.repository.RssStarRepository
import io.legado.kmp.shared.model.RssArticle
import io.legado.kmp.shared.model.RssReadRecord
import io.legado.kmp.shared.model.RssStar
import kotlinx.coroutines.flow.Flow

class MarkRssArticleReadUseCase(
    private val repository: RssReadRecordRepository
) {
    suspend operator fun invoke(
        article: RssArticle,
        readTime: Long = io.legado.kmp.shared.util.currentTimeMillis()
    ) {
        repository.insertRecord(
            RssReadRecord(
                record = article.link,
                title = article.title,
                readTime = readTime,
                read = true
            )
        )
    }
}

class GetRssReadRecordsUseCase(
    private val repository: RssReadRecordRepository
) {
    suspend operator fun invoke(): List<RssReadRecord> = repository.getRecords()
}

class CountRssReadRecordsUseCase(
    private val repository: RssReadRecordRepository
) {
    suspend operator fun invoke(): Int = repository.countRecords()
}

class ClearRssReadRecordsUseCase(
    private val repository: RssReadRecordRepository
) {
    suspend operator fun invoke() = repository.deleteAllRecord()
}

class ObserveRssFavoritesUseCase(
    private val repository: RssStarRepository
) {
    operator fun invoke(): Flow<List<RssStar>> = repository.observeAll()
}

class ObserveRssFavoriteGroupsUseCase(
    private val repository: RssStarRepository
) {
    operator fun invoke(): Flow<List<String>> = repository.observeGroups()
}

class ObserveRssFavoritesByGroupUseCase(
    private val repository: RssStarRepository
) {
    operator fun invoke(group: String): Flow<List<RssStar>> = repository.observeByGroup(group)
}

class ToggleRssFavoriteUseCase(
    private val repository: RssStarRepository
) {
    suspend operator fun invoke(article: RssArticle, starTime: Long = io.legado.kmp.shared.util.currentTimeMillis()): RssStar? {
        val existing = repository.get(article.origin, article.link)
        return if (existing != null) {
            repository.delete(existing.origin, existing.link)
            null
        } else {
            article.toStar(starTime).also { repository.insert(it) }
        }
    }
}

class AddRssFavoriteUseCase(
    private val repository: RssStarRepository
) {
    suspend operator fun invoke(article: RssArticle, starTime: Long = io.legado.kmp.shared.util.currentTimeMillis()): RssStar {
        val existing = repository.get(article.origin, article.link)
        return existing ?: article.toStar(starTime).also { repository.insert(it) }
    }
}

class UpdateRssFavoriteUseCase(
    private val repository: RssStarRepository
) {
    suspend operator fun invoke(article: RssArticle, starTime: Long = io.legado.kmp.shared.util.currentTimeMillis()): RssStar {
        return article.toStar(starTime).also { repository.update(it) }
    }
}

class DeleteRssFavoriteUseCase(
    private val repository: RssStarRepository
) {
    suspend operator fun invoke(origin: String, link: String) {
        repository.delete(origin, link)
    }
}
