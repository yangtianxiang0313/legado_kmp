package io.legado.kmp.shared.data.repository

import app.cash.sqldelight.coroutines.asFlow
import app.cash.sqldelight.coroutines.mapToList
import io.legado.kmp.shared.data.database.LegadoDatabase
import io.legado.kmp.shared.domain.repository.RssSourceRepository
import io.legado.kmp.shared.model.RssSource
import io.legado.kmp.shared.model.SourceGroups
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

class RssSourceRepositoryImpl(
    private val database: LegadoDatabase
) : RssSourceRepository {

    override suspend fun getByKey(key: String): RssSource? {
        return database.rssSourceQueries.selectRssSourceByKey(key, mapper = ::mapSource).executeAsOneOrNull()
    }

    override suspend fun getRssSources(vararg sourceUrls: String): List<RssSource> {
        return database.rssSourceQueries.selectRssSourcesByUrls(sourceUrls.toList(), mapper = ::mapSource).executeAsList()
    }

    override suspend fun getAll(): List<RssSource> {
        return database.rssSourceQueries.selectAllRssSources(mapper = ::mapSource).executeAsList()
    }

    override suspend fun size(): Int = database.rssSourceQueries.countAllRssSources().executeAsOne().toInt()

    override fun observeAll(): Flow<List<RssSource>> {
        return database.rssSourceQueries.selectAllRssSources(mapper = ::mapSource)
            .asFlow()
            .mapToList(Dispatchers.Default)
    }

    override fun observeSearch(key: String): Flow<List<RssSource>> {
        return database.rssSourceQueries.selectSearchRssSources(key, key, key, key, mapper = ::mapSource)
            .asFlow()
            .mapToList(Dispatchers.Default)
    }

    override fun observeGroupSearch(key: String): Flow<List<RssSource>> {
        return observeAll().map { sources ->
            sources.filter { it.hasGroup(key) }
        }
    }

    override fun observeEnabled(): Flow<List<RssSource>> {
        return database.rssSourceQueries.selectEnabledRssSources(mapper = ::mapSource)
            .asFlow()
            .mapToList(Dispatchers.Default)
    }

    override fun observeDisabled(): Flow<List<RssSource>> {
        return database.rssSourceQueries.selectDisabledRssSources(mapper = ::mapSource)
            .asFlow()
            .mapToList(Dispatchers.Default)
    }

    override fun observeLogin(): Flow<List<RssSource>> {
        return database.rssSourceQueries.selectLoginRssSources(mapper = ::mapSource)
            .asFlow()
            .mapToList(Dispatchers.Default)
    }

    override fun observeNoGroup(): Flow<List<RssSource>> {
        return database.rssSourceQueries.selectNoGroupRssSources(mapper = ::mapSource)
            .asFlow()
            .mapToList(Dispatchers.Default)
    }

    override fun observeEnabled(searchKey: String): Flow<List<RssSource>> {
        return database.rssSourceQueries.selectEnabledSearchRssSources(
            searchKey,
            searchKey,
            searchKey,
            searchKey,
            mapper = ::mapSource
        ).asFlow().mapToList(Dispatchers.Default)
    }

    override fun observeEnabledByGroup(searchKey: String): Flow<List<RssSource>> {
        return observeEnabled().map { sources ->
            sources.filter { it.hasGroup(searchKey) }
        }
    }

    override fun observeGroups(): Flow<List<String>> {
        return database.rssSourceQueries.selectRssGroupsRaw()
            .asFlow()
            .mapToList(Dispatchers.Default)
            .map { rows -> normalizeGroups(rows.map { it.source_group }) }
    }

    override fun observeEnabledGroups(): Flow<List<String>> {
        return database.rssSourceQueries.selectEnabledRssGroupsRaw()
            .asFlow()
            .mapToList(Dispatchers.Default)
            .map { rows -> normalizeGroups(rows.map { it.source_group }) }
    }

    override suspend fun getAllGroups(): List<String> {
        return normalizeGroups(database.rssSourceQueries.selectRssGroupsRaw().executeAsList().map { it.source_group })
    }

    override suspend fun getMinOrder(): Int? {
        return database.rssSourceQueries.selectMinRssOrder().executeAsOneOrNull()?.MIN?.toInt()
    }

    override suspend fun getMaxOrder(): Int? {
        return database.rssSourceQueries.selectMaxRssOrder().executeAsOneOrNull()?.MAX?.toInt()
    }

    override suspend fun getNoGroup(): List<RssSource> {
        return database.rssSourceQueries.selectNoGroupRssSources(mapper = ::mapSource).executeAsList()
    }

    override suspend fun getByGroup(group: String): List<RssSource> {
        return getAll().filter { it.hasGroup(group) }
    }

    override suspend fun has(key: String): Boolean = database.rssSourceQueries.hasRssSourceByKey(key).executeAsOne()

    override suspend fun insert(vararg rssSource: RssSource) {
        rssSource.forEach {
            database.rssSourceQueries.insertRssSource(
                source_url = it.sourceUrl,
                source_name = it.sourceName,
                source_icon = it.sourceIcon,
                source_group = it.sourceGroup,
                source_comment = it.sourceComment,
                enabled = if (it.enabled) 1L else 0L,
                variable_comment = it.variableComment,
                js_lib = it.jsLib,
                enabled_cookie_jar = if (it.enabledCookieJar) 1L else 0L,
                concurrent_rate = it.concurrentRate,
                header_ = it.header,
                login_url = it.loginUrl,
                login_ui = it.loginUi,
                login_check_js = it.loginCheckJs,
                cover_decode_js = it.coverDecodeJs,
                sort_url = it.sortUrl,
                single_url = if (it.singleUrl) 1L else 0L,
                article_style = it.articleStyle.toLong(),
                rule_articles = it.ruleArticles,
                rule_next_page = it.ruleNextPage,
                rule_title = it.ruleTitle,
                rule_pub_date = it.rulePubDate,
                rule_description = it.ruleDescription,
                rule_image = it.ruleImage,
                rule_link = it.ruleLink,
                rule_content = it.ruleContent,
                content_whitelist = it.contentWhitelist,
                content_blacklist = it.contentBlacklist,
                should_override_url_loading = it.shouldOverrideUrlLoading,
                style = it.style,
                enable_js = if (it.enableJs) 1L else 0L,
                load_with_base_url = if (it.loadWithBaseUrl) 1L else 0L,
                inject_js = it.injectJs,
                last_update_time = it.lastUpdateTime,
                custom_order = it.customOrder.toLong()
            )
        }
    }

    override suspend fun update(vararg rssSource: RssSource) {
        rssSource.forEach {
            database.rssSourceQueries.updateRssSource(
                source_name = it.sourceName,
                source_icon = it.sourceIcon,
                source_group = it.sourceGroup,
                source_comment = it.sourceComment,
                enabled = if (it.enabled) 1L else 0L,
                variable_comment = it.variableComment,
                js_lib = it.jsLib,
                enabled_cookie_jar = if (it.enabledCookieJar) 1L else 0L,
                concurrent_rate = it.concurrentRate,
                header_ = it.header,
                login_url = it.loginUrl,
                login_ui = it.loginUi,
                login_check_js = it.loginCheckJs,
                cover_decode_js = it.coverDecodeJs,
                sort_url = it.sortUrl,
                single_url = if (it.singleUrl) 1L else 0L,
                article_style = it.articleStyle.toLong(),
                rule_articles = it.ruleArticles,
                rule_next_page = it.ruleNextPage,
                rule_title = it.ruleTitle,
                rule_pub_date = it.rulePubDate,
                rule_description = it.ruleDescription,
                rule_image = it.ruleImage,
                rule_link = it.ruleLink,
                rule_content = it.ruleContent,
                content_whitelist = it.contentWhitelist,
                content_blacklist = it.contentBlacklist,
                should_override_url_loading = it.shouldOverrideUrlLoading,
                style = it.style,
                enable_js = if (it.enableJs) 1L else 0L,
                load_with_base_url = if (it.loadWithBaseUrl) 1L else 0L,
                inject_js = it.injectJs,
                last_update_time = it.lastUpdateTime,
                custom_order = it.customOrder.toLong(),
                source_url = it.sourceUrl
            )
        }
    }

    override suspend fun delete(vararg rssSource: RssSource) {
        rssSource.forEach { delete(it.sourceUrl) }
    }

    override suspend fun delete(sourceUrl: String) {
        database.rssSourceQueries.deleteRssSourceByUrl(sourceUrl)
    }

    override suspend fun deleteDefault() {
        database.rssSourceQueries.deleteDefaultRssSources()
    }

    override suspend fun enable(sourceUrl: String, enable: Boolean) {
        database.rssSourceQueries.enableRssSource(if (enable) 1L else 0L, sourceUrl)
    }

    private fun normalizeGroups(groups: List<String?>): List<String> {
        val merged = linkedSetOf<String>()
        groups.forEach { raw ->
            SourceGroups.split(raw).forEach(merged::add)
        }
        return merged.sorted()
    }

    private fun mapSource(
        source_url: String,
        source_name: String,
        source_icon: String,
        source_group: String?,
        source_comment: String?,
        enabled: Long,
        variable_comment: String?,
        js_lib: String?,
        enabled_cookie_jar: Long,
        concurrent_rate: String?,
        header_: String?,
        login_url: String?,
        login_ui: String?,
        login_check_js: String?,
        cover_decode_js: String?,
        sort_url: String?,
        single_url: Long,
        article_style: Long,
        rule_articles: String?,
        rule_next_page: String?,
        rule_title: String?,
        rule_pub_date: String?,
        rule_description: String?,
        rule_image: String?,
        rule_link: String?,
        rule_content: String?,
        content_whitelist: String?,
        content_blacklist: String?,
        should_override_url_loading: String?,
        style: String?,
        enable_js: Long,
        load_with_base_url: Long,
        inject_js: String?,
        last_update_time: Long,
        custom_order: Long
    ): RssSource {
        return RssSource(
            sourceUrl = source_url,
            sourceName = source_name,
            sourceIcon = source_icon,
            sourceGroup = source_group,
            sourceComment = source_comment,
            enabled = enabled == 1L,
            variableComment = variable_comment,
            jsLib = js_lib,
            enabledCookieJar = enabled_cookie_jar == 1L,
            concurrentRate = concurrent_rate,
            header = header_,
            loginUrl = login_url,
            loginUi = login_ui,
            loginCheckJs = login_check_js,
            coverDecodeJs = cover_decode_js,
            sortUrl = sort_url,
            singleUrl = single_url == 1L,
            articleStyle = article_style.toInt(),
            ruleArticles = rule_articles,
            ruleNextPage = rule_next_page,
            ruleTitle = rule_title,
            rulePubDate = rule_pub_date,
            ruleDescription = rule_description,
            ruleImage = rule_image,
            ruleLink = rule_link,
            ruleContent = rule_content,
            contentWhitelist = content_whitelist,
            contentBlacklist = content_blacklist,
            shouldOverrideUrlLoading = should_override_url_loading,
            style = style,
            enableJs = enable_js == 1L,
            loadWithBaseUrl = load_with_base_url == 1L,
            injectJs = inject_js,
            lastUpdateTime = last_update_time,
            customOrder = custom_order.toInt()
        )
    }

}
