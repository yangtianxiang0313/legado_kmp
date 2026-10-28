package io.legado.kmp.shared.facade

import io.legado.kmp.shared.domain.repository.RssSourceRepository
import io.legado.kmp.shared.domain.usecase.ClearRssReadRecordsUseCase
import io.legado.kmp.shared.domain.usecase.FetchRssArticlesUseCase
import io.legado.kmp.shared.domain.usecase.FetchRssContentUseCase
import io.legado.kmp.shared.domain.usecase.GetRssSortUrlsUseCase
import io.legado.kmp.shared.domain.usecase.ObserveEnabledRssSourcesUseCase
import io.legado.kmp.shared.domain.usecase.ObserveRssFavoriteGroupsUseCase
import io.legado.kmp.shared.domain.usecase.ObserveRssFavoritesByGroupUseCase
import io.legado.kmp.shared.domain.usecase.ObserveRssFavoritesUseCase
import io.legado.kmp.shared.domain.usecase.ToggleRssFavoriteUseCase
import io.legado.kmp.shared.domain.usecase.UpdateRssFavoriteUseCase
import io.legado.kmp.shared.model.RssArticle
import io.legado.kmp.shared.model.RssSource
import io.legado.kmp.shared.model.RssStar
import io.legado.kmp.shared.model.SourceGroups
import kotlinx.serialization.builtins.ListSerializer

data class RssArticlesPayload(
    val articles: List<RssArticle>,
    val nextPageUrl: String?,
)

class RssFacade(
    private val observeEnabledRssSourcesUseCase: ObserveEnabledRssSourcesUseCase,
    private val getRssSortUrlsUseCase: GetRssSortUrlsUseCase,
    private val fetchRssArticlesUseCase: FetchRssArticlesUseCase,
    private val fetchRssContentUseCase: FetchRssContentUseCase,
    private val toggleRssFavoriteUseCase: ToggleRssFavoriteUseCase,
    private val observeRssFavoritesUseCase: ObserveRssFavoritesUseCase,
    private val clearRssReadRecordsUseCase: ClearRssReadRecordsUseCase,
    private val observeRssFavoriteGroupsUseCase: ObserveRssFavoriteGroupsUseCase,
    private val observeRssFavoritesByGroupUseCase: ObserveRssFavoritesByGroupUseCase,
    private val updateRssFavoriteUseCase: UpdateRssFavoriteUseCase,
    private val rssSourceRepository: RssSourceRepository,
) {
    fun watchSources(onUpdate: (List<RssSource>) -> Unit): FlowSubscription {
        return watchFlow(observeEnabledRssSourcesUseCase(), onUpdate)
    }

    fun watchFavorites(onUpdate: (List<RssStar>) -> Unit): FlowSubscription {
        return watchFlow(observeRssFavoritesUseCase(), onUpdate)
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun loadSorts(source: RssSource, forceRefresh: Boolean = false): List<Pair<String, String>> {
        return runRecoverable("RssFacade.loadSorts") {
            if (forceRefresh) {
                getRssSortUrlsUseCase.clearCache(source)
            }
            getRssSortUrlsUseCase(source).getOrThrow()
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun loadArticles(
        sortName: String,
        sortUrl: String,
        source: RssSource,
        page: Int = 1,
    ): RssArticlesPayload {
        return runRecoverable("RssFacade.loadArticles") {
            val (articles, nextPageUrl) = fetchRssArticlesUseCase(sortName, sortUrl, source, page).getOrThrow()
            RssArticlesPayload(articles, nextPageUrl)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun loadContent(article: RssArticle, source: RssSource): String {
        return runRecoverable("RssFacade.loadContent") {
            fetchRssContentUseCase(article, source).getOrThrow()
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun toggleFavorite(article: RssArticle): Boolean {
        return runRecoverable("RssFacade.toggleFavorite") {
            toggleRssFavoriteUseCase(article) != null
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun clearReadRecords() {
        runRecoverable("RssFacade.clearReadRecords") {
            clearRssReadRecordsUseCase()
        }
    }

    fun watchFavoriteGroups(onUpdate: (List<String>) -> Unit): FlowSubscription {
        return watchFlow(observeRssFavoriteGroupsUseCase(), onUpdate)
    }

    fun watchFavoritesByGroup(group: String, onUpdate: (List<RssStar>) -> Unit): FlowSubscription {
        return watchFlow(observeRssFavoritesByGroupUseCase(group), onUpdate)
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun updateFavorite(star: RssStar) {
        runRecoverable("RssFacade.updateFavorite") {
            updateRssFavoriteUseCase(star.toRssArticle(), star.starTime)
        }
    }

    // MARK: - RSS Source CRUD

    fun watchAllSources(onUpdate: (List<RssSource>) -> Unit): FlowSubscription {
        return watchFlow(rssSourceRepository.observeAll(), onUpdate, label = "RssFacade.allSources")
    }

    fun watchGroups(onUpdate: (List<String>) -> Unit): FlowSubscription {
        return watchFlow(rssSourceRepository.observeGroups(), onUpdate, label = "RssFacade.groups")
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun getAllSources(): List<RssSource> {
        return runRecoverable("RssFacade.getAllSources") {
            rssSourceRepository.getAll()
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun getSource(sourceUrl: String): RssSource? {
        return runRecoverable("RssFacade.getSource") {
            rssSourceRepository.getByKey(sourceUrl.trim())
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun searchSources(keyword: String): List<RssSource> {
        return runRecoverable("RssFacade.searchSources") {
            val trimmed = keyword.trim()
            if (trimmed.isEmpty()) {
                rssSourceRepository.getAll()
            } else {
                rssSourceRepository.getAll().filter { source ->
                    source.sourceName.contains(trimmed, ignoreCase = true) ||
                        source.sourceUrl.contains(trimmed, ignoreCase = true) ||
                        (source.sourceGroup?.contains(trimmed, ignoreCase = true) == true)
                }
            }
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setRssSourceEnabled(sourceUrl: String, enabled: Boolean) {
        runRecoverable("RssFacade.setRssSourceEnabled") {
            rssSourceRepository.enable(sourceUrl, enabled)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun saveRssSource(source: RssSource): RssSource {
        return runRecoverable("RssFacade.saveRssSource") {
            val normalized = source.normalizedForSave()
            if (rssSourceRepository.has(normalized.sourceUrl)) {
                rssSourceRepository.update(normalized)
            } else {
                rssSourceRepository.insert(normalized)
            }
            rssSourceRepository.getByKey(normalized.sourceUrl) ?: normalized
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun deleteRssSource(sourceUrl: String) {
        runRecoverable("RssFacade.deleteRssSource") {
            rssSourceRepository.delete(sourceUrl)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun deleteRssSources(sourceUrls: List<String>) {
        runRecoverable("RssFacade.deleteRssSources") {
            sourceUrls
                .map(String::trim)
                .filter(String::isNotEmpty)
                .distinct()
                .forEach { rssSourceRepository.delete(it) }
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun addRssSourcesToGroup(sourceUrls: List<String>, group: String): Int {
        return runRecoverable("RssFacade.addRssSourcesToGroup") {
            val normalizedGroup = group.trim()
            require(normalizedGroup.isNotEmpty()) { "RSS source group cannot be empty" }
            val targets = sourceUrls
                .map(String::trim)
                .filter(String::isNotEmpty)
                .distinct()
                .mapNotNull { rssSourceRepository.getByKey(it) }
                .map { it.addGroup(normalizedGroup).normalizedForSave() }
            if (targets.isNotEmpty()) {
                rssSourceRepository.update(*targets.toTypedArray())
            }
            targets.size
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun renameRssSourceGroup(oldName: String, newName: String): Int {
        return runRecoverable("RssFacade.renameRssSourceGroup") {
            val oldGroup = oldName.trim()
            val newGroup = newName.trim()
            require(oldGroup.isNotEmpty()) { "RSS source group cannot be empty" }
            require(newGroup.isNotEmpty()) { "RSS source group cannot be empty" }
            val targets = rssSourceRepository.getAll()
                .mapNotNull { source ->
                    val replaced = source.replaceGroup(oldGroup, newGroup)
                    if (replaced.sourceGroup == source.sourceGroup) null else replaced.normalizedForSave()
                }
            if (targets.isNotEmpty()) {
                rssSourceRepository.update(*targets.toTypedArray())
            }
            targets.size
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun deleteRssSourceGroup(group: String): Int {
        return runRecoverable("RssFacade.deleteRssSourceGroup") {
            val normalizedGroup = group.trim()
            require(normalizedGroup.isNotEmpty()) { "RSS source group cannot be empty" }
            val targets = rssSourceRepository.getAll()
                .mapNotNull { source ->
                    if (!source.hasGroup(normalizedGroup)) null
                    else source.removeGroup(normalizedGroup).normalizedForSave()
                }
            if (targets.isNotEmpty()) {
                rssSourceRepository.update(*targets.toTypedArray())
            }
            targets.size
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun importRssSources(payload: String): Int {
        return runRecoverable("RssFacade.importRssSources") {
            val sources = importJson.decodeFromString(ListSerializer(RssSource.serializer()), payload)
            val valid = sources.filter { it.isValid }
            valid.forEach { source ->
                val normalized = source.normalizedForSave()
                if (rssSourceRepository.has(normalized.sourceUrl)) {
                    rssSourceRepository.update(normalized)
                } else {
                    rssSourceRepository.insert(normalized)
                }
            }
            valid.size
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun exportRssSources(sourceUrls: List<String>): String {
        return runRecoverable("RssFacade.exportRssSources") {
            val targets = sourceUrls
                .map(String::trim)
                .filter(String::isNotEmpty)
                .distinct()
                .mapNotNull { rssSourceRepository.getByKey(it) }
            importJson.encodeToString(ListSerializer(RssSource.serializer()), targets)
        }
    }

    private fun RssSource.normalizedForSave(): RssSource {
        return copy(
            sourceUrl = sourceUrl.trim(),
            sourceName = sourceName.trim(),
            sourceGroup = SourceGroups.normalize(sourceGroup),
            sourceComment = sourceComment?.trim()?.takeUnless(String::isEmpty),
            variableComment = variableComment?.trim()?.takeUnless(String::isEmpty),
            jsLib = jsLib?.trim()?.takeUnless(String::isEmpty),
            concurrentRate = concurrentRate?.trim()?.takeUnless(String::isEmpty),
            header = header?.trim()?.takeUnless(String::isEmpty),
            loginUrl = loginUrl?.trim()?.takeUnless(String::isEmpty),
            loginUi = loginUi?.trim()?.takeUnless(String::isEmpty),
            loginCheckJs = loginCheckJs?.trim()?.takeUnless(String::isEmpty),
            coverDecodeJs = coverDecodeJs?.trim()?.takeUnless(String::isEmpty),
        ).also {
            require(it.sourceUrl.isNotEmpty()) { "RSS source URL cannot be empty" }
            require(it.sourceName.isNotEmpty()) { "RSS source name cannot be empty" }
        }
    }

    private fun RssSource.replaceGroup(oldName: String, newName: String): RssSource {
        val groups = SourceGroups.split(sourceGroup)
        if (groups.none { it == oldName }) {
            return this
        }
        val merged = linkedSetOf<String>()
        groups.forEach { group ->
            merged.add(if (group == oldName) newName else group)
        }
        return copy(sourceGroup = merged.takeIf { it.isNotEmpty() }?.joinToString(","))
    }
}
