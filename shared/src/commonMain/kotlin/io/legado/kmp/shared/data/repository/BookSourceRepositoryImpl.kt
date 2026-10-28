package io.legado.kmp.shared.data.repository

import app.cash.sqldelight.coroutines.asFlow
import app.cash.sqldelight.coroutines.mapToList
import io.legado.kmp.data.database.schema.Book_sources
import io.legado.kmp.data.database.schema.SelectExplore
import io.legado.kmp.data.database.schema.SelectByType
import io.legado.kmp.data.database.schema.SelectGroups
import io.legado.kmp.data.database.schema.SelectEnabledGroups
import io.legado.kmp.data.database.schema.SelectExploreGroups
import io.legado.kmp.data.database.schema.SelectLogin
import io.legado.kmp.shared.data.adapter.BookSourceAdapter
import io.legado.kmp.shared.data.database.LegadoDatabase
import io.legado.kmp.shared.domain.repository.BookSourceRepository
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.model.BookSourcePart
import io.legado.kmp.shared.model.SourceGroups
import io.legado.kmp.shared.model.toInsertMap
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

/**
 * SQLDelight implementation of BookSourceRepository
 */
class BookSourceRepositoryImpl(
    private val database: LegadoDatabase
) : BookSourceRepository {

    override fun observeAllBookSources(): Flow<List<BookSource>> {
        return database.bookSourceQueries
            .selectAll()
            .asFlow()
            .mapToList(Dispatchers.Default)
            .map { list -> list.map { bookSource -> mapToBookSource(bookSource) } }
    }

    override fun observeEnabledBookSources(): Flow<List<BookSource>> {
        return database.bookSourceQueries
            .selectEnabled()
            .asFlow()
            .mapToList(Dispatchers.Default)
            .map { list -> list.map { bookSource -> mapToBookSource(bookSource) } }
    }

    override fun observeDisabledBookSources(): Flow<List<BookSource>> {
        return database.bookSourceQueries
            .selectDisabled()
            .asFlow()
            .mapToList(Dispatchers.Default)
            .map { list -> list.map { bookSource -> mapToBookSource(bookSource) } }
    }

    override fun observeExploreBookSources(): Flow<List<BookSource>> {
        return database.bookSourceQueries
            .selectExplore()
            .asFlow()
            .mapToList(Dispatchers.Default)
            .map { list -> list.map { bookSource -> mapToBookSource(bookSource) } }
    }

    override fun observeLoginBookSources(): Flow<List<BookSource>> {
        return database.bookSourceQueries
            .selectLogin()
            .asFlow()
            .mapToList(Dispatchers.Default)
            .map { list -> list.map { bookSource -> mapToBookSource(bookSource) } }
    }

    override fun observeBookSourcesByGroup(group: String): Flow<List<BookSource>> {
        return observeAllBookSources().map { sources ->
            sources.filter { it.hasGroup(group) }
        }
    }

    override fun observeEnabledBookSourcesByGroup(group: String): Flow<List<BookSource>> {
        return observeEnabledBookSources().map { sources ->
            sources.filter { it.hasGroup(group) }
        }
    }

    override fun observeNoGroupBookSources(): Flow<List<BookSource>> {
        return database.bookSourceQueries
            .selectNoGroup()
            .asFlow()
            .mapToList(Dispatchers.Default)
            .map { list -> list.map { bookSource -> mapToBookSource(bookSource) } }
    }

    override suspend fun getAllBookSources(): List<BookSource> {
        return database.bookSourceQueries
            .selectAll()
            .executeAsList()
            .map { bookSource -> mapToBookSource(bookSource) }
    }

    override suspend fun getEnabledBookSources(): List<BookSource> {
        return database.bookSourceQueries
            .selectEnabled()
            .executeAsList()
            .map { bookSource -> mapToBookSource(bookSource) }
    }

    override suspend fun getDisabledBookSources(): List<BookSource> {
        return database.bookSourceQueries
            .selectDisabled()
            .executeAsList()
            .map { bookSource -> mapToBookSource(bookSource) }
    }

    override suspend fun getExploreBookSources(): List<BookSource> {
        return database.bookSourceQueries
            .selectExplore()
            .executeAsList()
            .map { bookSource -> mapToBookSource(bookSource) }
    }

    override suspend fun getBookSource(url: String): BookSource? {
        return database.bookSourceQueries
            .selectByUrl(url)
            .executeAsOneOrNull()
            ?.let { bookSource -> mapToBookSource(bookSource) }
    }

    override suspend fun getBookSourcesByType(type: Int): List<BookSource> {
        return database.bookSourceQueries
            .selectByType(type.toLong())
            .executeAsList()
            .map { bookSource -> mapToBookSource(bookSource) }
    }

    override suspend fun getBookSourcesByGroup(group: String): List<BookSource> {
        return getAllBookSources().filter { it.hasGroup(group) }
    }

    override suspend fun getEnabledBookSourcesByGroup(group: String): List<BookSource> {
        return getEnabledBookSources().filter { it.hasGroup(group) }
    }

    override suspend fun getNoGroupBookSources(): List<BookSource> {
        return database.bookSourceQueries
            .selectNoGroup()
            .executeAsList()
            .map { bookSource -> mapToBookSource(bookSource) }
    }

    override suspend fun getLoginBookSources(): List<BookSource> {
        return database.bookSourceQueries
            .selectLogin()
            .executeAsList()
            .map { bookSource -> mapToBookSource(bookSource) }
    }

    override suspend fun searchBookSources(keyword: String): List<BookSource> {
        return database.bookSourceQueries
            .searchByName(keyword, keyword, keyword, keyword)
            .executeAsList()
            .map { bookSource -> mapToBookSource(bookSource) }
    }

    override suspend fun searchEnabledBookSources(keyword: String): List<BookSource> {
        return database.bookSourceQueries
            .searchEnabledByName(keyword, keyword, keyword, keyword)
            .executeAsList()
            .map { bookSource -> mapToBookSource(bookSource) }
    }

    override fun observeSearchBookSources(keyword: String): Flow<List<BookSource>> {
        return database.bookSourceQueries
            .searchByName(keyword, keyword, keyword, keyword)
            .asFlow()
            .mapToList(Dispatchers.Default)
            .map { list -> list.map { bookSource -> mapToBookSource(bookSource) } }
    }

    override fun observeSearchEnabledBookSources(keyword: String): Flow<List<BookSource>> {
        return database.bookSourceQueries
            .searchEnabledByName(keyword, keyword, keyword, keyword)
            .asFlow()
            .mapToList(Dispatchers.Default)
            .map { list -> list.map { bookSource -> mapToBookSource(bookSource) } }
    }

    override suspend fun getAllGroups(): List<String> {
        return processGroupsFromSelectGroups(database.bookSourceQueries.selectGroups().executeAsList())
    }

    override suspend fun getEnabledGroups(): List<String> {
        return processGroupsFromSelectEnabledGroups(database.bookSourceQueries.selectEnabledGroups().executeAsList())
    }

    override suspend fun getExploreGroups(): List<String> {
        return processGroupsFromSelectExploreGroups(database.bookSourceQueries.selectExploreGroups().executeAsList())
    }

    override fun observeAllGroups(): Flow<List<String>> {
        return database.bookSourceQueries
            .selectGroups()
            .asFlow()
            .mapToList(Dispatchers.Default)
            .map { processGroupsFromSelectGroups(it) }
    }

    override fun observeEnabledGroups(): Flow<List<String>> {
        return database.bookSourceQueries
            .selectEnabledGroups()
            .asFlow()
            .mapToList(Dispatchers.Default)
            .map { processGroupsFromSelectEnabledGroups(it) }
    }

    override fun observeExploreGroups(): Flow<List<String>> {
        return database.bookSourceQueries
            .selectExploreGroups()
            .asFlow()
            .mapToList(Dispatchers.Default)
            .map { processGroupsFromSelectExploreGroups(it) }
    }

    override suspend fun insert(bookSource: BookSource) {
        insertBookSource(bookSource)
    }

    private fun insertBookSource(bookSource: BookSource) {
        database.bookSourceQueries.insert(
            book_source_url = bookSource.bookSourceUrl,
            book_source_name = bookSource.bookSourceName,
            book_source_group = bookSource.bookSourceGroup,
            book_source_type = bookSource.bookSourceType.toLong(),
            book_url_pattern = bookSource.bookUrlPattern,
            custom_order = bookSource.customOrder.toLong(),
            enabled = if (bookSource.enabled) 1L else 0L,
            enabled_explore = if (bookSource.enabledExplore) 1L else 0L,
            js_lib = bookSource.jsLib,
            enabled_cookie_jar = if (bookSource.enabledCookieJar) 1L else 0L,
            concurrent_rate = bookSource.concurrentRate,
            header_json = bookSource.header,
            login_url = bookSource.loginUrl,
            login_ui = bookSource.loginUi,
            login_check_js = bookSource.loginCheckJs,
            cover_decode_js = bookSource.coverDecodeJs,
            book_source_comment = bookSource.bookSourceComment,
            variable_comment = bookSource.variableComment,
            last_update_time = bookSource.lastUpdateTime,
            respond_time = bookSource.respondTime,
            weight = bookSource.weight.toLong(),
            explore_url = bookSource.exploreUrl,
            explore_screen = bookSource.exploreScreen,
            rule_explore = bookSource.ruleExplore?.let { encodeRule(it) },
            search_url = bookSource.searchUrl,
            rule_search = bookSource.ruleSearch?.let { encodeRule(it) },
            rule_book_info = bookSource.ruleBookInfo?.let { encodeRule(it) },
            rule_toc = bookSource.ruleToc?.let { encodeRule(it) },
            rule_content = bookSource.ruleContent?.let { encodeRule(it) },
            rule_review = bookSource.ruleReview?.let { encodeRule(it) }
        )
    }

    override suspend fun update(bookSource: BookSource) {
        updateBookSource(bookSource)
    }

    override suspend fun updateIfUnchanged(expected: BookSource, updated: BookSource): Boolean {
        require(expected.bookSourceUrl == updated.bookSourceUrl)
        val context = currentCoroutineContext()
        context.ensureActive()
        return database.bookSourceQueries.transactionWithResult {
            val current = database.bookSourceQueries.selectByUrl(expected.bookSourceUrl).executeAsOneOrNull()
                ?: return@transactionWithResult false
            // BookSource.equals compares only URLs; compare the persisted fields before replacing them.
            if (mapToBookSource(current).toInsertMap() != expected.toInsertMap()) return@transactionWithResult false
            context.ensureActive()
            updateBookSource(updated)
            context.ensureActive()
            true
        }
    }

    private fun updateBookSource(bookSource: BookSource) {
        database.bookSourceQueries.update(
            book_source_name = bookSource.bookSourceName,
            book_source_group = bookSource.bookSourceGroup,
            book_source_type = bookSource.bookSourceType.toLong(),
            book_url_pattern = bookSource.bookUrlPattern,
            custom_order = bookSource.customOrder.toLong(),
            enabled = if (bookSource.enabled) 1L else 0L,
            enabled_explore = if (bookSource.enabledExplore) 1L else 0L,
            js_lib = bookSource.jsLib,
            enabled_cookie_jar = if (bookSource.enabledCookieJar) 1L else 0L,
            concurrent_rate = bookSource.concurrentRate,
            header_json = bookSource.header,
            login_url = bookSource.loginUrl,
            login_ui = bookSource.loginUi,
            login_check_js = bookSource.loginCheckJs,
            cover_decode_js = bookSource.coverDecodeJs,
            book_source_comment = bookSource.bookSourceComment,
            variable_comment = bookSource.variableComment,
            last_update_time = bookSource.lastUpdateTime,
            respond_time = bookSource.respondTime,
            weight = bookSource.weight.toLong(),
            explore_url = bookSource.exploreUrl,
            explore_screen = bookSource.exploreScreen,
            rule_explore = bookSource.ruleExplore?.let { encodeRule(it) },
            search_url = bookSource.searchUrl,
            rule_search = bookSource.ruleSearch?.let { encodeRule(it) },
            rule_book_info = bookSource.ruleBookInfo?.let { encodeRule(it) },
            rule_toc = bookSource.ruleToc?.let { encodeRule(it) },
            rule_content = bookSource.ruleContent?.let { encodeRule(it) },
            rule_review = bookSource.ruleReview?.let { encodeRule(it) },
            book_source_url = bookSource.bookSourceUrl
        )
    }

    override suspend fun insertOrUpdate(bookSource: BookSource) {
        val existing = getBookSource(bookSource.bookSourceUrl)
        if (existing != null) {
            update(bookSource)
        } else {
            insert(bookSource)
        }
    }

    internal fun restoreFromBackup(bookSource: BookSource) {
        val existing = database.bookSourceQueries.selectByUrl(bookSource.bookSourceUrl).executeAsOneOrNull()
        if (existing != null) {
            updateBookSource(bookSource)
        } else {
            insertBookSource(bookSource)
        }
    }

    override suspend fun insertOrUpdate(bookSources: List<BookSource>) {
        if (bookSources.isEmpty()) return
        val coroutineContext = currentCoroutineContext()
        coroutineContext.ensureActive()
        database.bookSourceQueries.transaction {
            bookSources.forEach { bookSource ->
                coroutineContext.ensureActive()
                val existing = database.bookSourceQueries
                    .selectByUrl(bookSource.bookSourceUrl)
                    .executeAsOneOrNull()
                if (existing != null) {
                    updateBookSource(bookSource)
                } else {
                    insertBookSource(bookSource)
                }
            }
            coroutineContext.ensureActive()
        }
    }

    override suspend fun delete(bookSource: BookSource) {
        database.bookSourceQueries.delete(bookSource.bookSourceUrl)
    }

    override suspend fun deleteByUrl(url: String) {
        database.bookSourceQueries.delete(url)
    }

    override suspend fun delete(bookSources: List<BookSource>) {
        bookSources.forEach { bookSource ->
            deleteByUrl(bookSource.bookSourceUrl)
        }
    }

    override suspend fun setEnabled(url: String, enabled: Boolean) {
        database.bookSourceQueries.updateEnabled(
            enabled = if (enabled) 1L else 0L,
            book_source_url = url
        )
    }

    override suspend fun setEnabledExplore(url: String, enabled: Boolean) {
        database.bookSourceQueries.updateEnabledExplore(
            enabled_explore = if (enabled) 1L else 0L,
            book_source_url = url
        )
    }

    override suspend fun updateOrder(url: String, order: Int) {
        database.bookSourceQueries.updateOrder(
            custom_order = order.toLong(),
            book_source_url = url
        )
    }

    override suspend fun updateOrder(bookSources: List<BookSource>) {
        bookSources.forEach { bookSource ->
            updateOrder(bookSource.bookSourceUrl, bookSource.customOrder)
        }
    }

    override suspend fun updateGroup(url: String, group: String?) {
        database.bookSourceQueries.updateGroup(
            book_source_group = group,
            book_source_url = url
        )
    }

    override suspend fun updateGroup(bookSources: List<BookSource>) {
        bookSources.forEach { bookSource ->
            updateGroup(bookSource.bookSourceUrl, bookSource.bookSourceGroup)
        }
    }

    override suspend fun getBookSourceCount(): Int {
        return database.bookSourceQueries.countAll().executeAsOne().toInt()
    }

    override suspend fun getMinOrder(): Int? {
        return database.bookSourceQueries.minOrder().executeAsOneOrNull()?.MIN?.toInt()
    }

    override suspend fun getMaxOrder(): Int? {
        return database.bookSourceQueries.maxOrder().executeAsOneOrNull()?.MAX?.toInt()
    }

    override suspend fun getTextSourcesWithPattern(): List<BookSource> {
        return getBookSourcesByType(io.legado.kmp.shared.model.BookSourceType.TEXT)
            .filter { it.hasBookUrlPattern }
            .sortedBy { it.customOrder }
    }

    override suspend fun getBookSourceForAddBook(baseUrl: String): BookSource? {
        return getEnabledBookSources().firstOrNull { source ->
            source.hasBookUrlPattern && baseUrl.matches(Regex(source.bookUrlPattern ?: ""))
        }
    }

    override fun observeAllBookSourceParts(): Flow<List<BookSourcePart>> {
        return observeAllBookSources().map { list -> list.map(BookSourcePart::from) }
    }

    override fun observeEnabledBookSourceParts(): Flow<List<BookSourcePart>> {
        return observeEnabledBookSources().map { list -> list.map(BookSourcePart::from) }
    }

    override fun observeEnabledExploreBookSourceParts(): Flow<List<BookSourcePart>> {
        return observeExploreBookSources().map { list -> list.map(BookSourcePart::from) }
    }

    override fun observeLoginBookSourceParts(): Flow<List<BookSourcePart>> {
        return observeLoginBookSources().map { list -> list.map(BookSourcePart::from) }
    }

    override fun observeBookSourcePartsByGroup(group: String): Flow<List<BookSourcePart>> {
        return observeBookSourcesByGroup(group).map { list -> list.map(BookSourcePart::from) }
    }

    override fun observeEnabledBookSourcePartsByGroup(group: String): Flow<List<BookSourcePart>> {
        return observeEnabledBookSourcesByGroup(group).map { list -> list.map(BookSourcePart::from) }
    }

    override fun observeSearchBookSourceParts(keyword: String): Flow<List<BookSourcePart>> {
        return observeSearchBookSources(keyword).map { list -> list.map(BookSourcePart::from) }
    }

    override fun observeSearchEnabledBookSourceParts(keyword: String): Flow<List<BookSourcePart>> {
        return observeSearchEnabledBookSources(keyword).map { list -> list.map(BookSourcePart::from) }
    }

    override suspend fun getAllBookSourceParts(): List<BookSourcePart> {
        return getAllBookSources().map(BookSourcePart::from)
    }

    override suspend fun getEnabledBookSourceParts(): List<BookSourcePart> {
        return getEnabledBookSources().map(BookSourcePart::from)
    }

    override suspend fun getEnabledExploreBookSourceParts(): List<BookSourcePart> {
        return getExploreBookSources().map(BookSourcePart::from)
    }

    override suspend fun getLoginBookSourceParts(): List<BookSourcePart> {
        return getLoginBookSources().map(BookSourcePart::from)
    }

    override suspend fun getBookSourcePartsByGroup(group: String): List<BookSourcePart> {
        return getBookSourcesByGroup(group).map(BookSourcePart::from)
    }

    override suspend fun getEnabledBookSourcePartsByGroup(group: String): List<BookSourcePart> {
        return getEnabledBookSourcesByGroup(group).map(BookSourcePart::from)
    }

    override suspend fun searchBookSourceParts(keyword: String): List<BookSourcePart> {
        return searchBookSources(keyword).map(BookSourcePart::from)
    }

    override suspend fun searchEnabledBookSourceParts(keyword: String): List<BookSourcePart> {
        return searchEnabledBookSources(keyword).map(BookSourcePart::from)
    }

    override suspend fun getTextBookSourcePartsWithPattern(): List<BookSourcePart> {
        return getTextSourcesWithPattern().map(BookSourcePart::from)
    }

    /**
     * Map SQLDelight generated Book_sources to domain model
     */
    private fun mapToBookSource(bookSource: Book_sources): BookSource = BookSource(
        bookSourceUrl = bookSource.book_source_url,
        bookSourceName = bookSource.book_source_name,
        bookSourceGroup = bookSource.book_source_group,
        bookSourceType = bookSource.book_source_type.toInt(),
        bookUrlPattern = bookSource.book_url_pattern,
        customOrder = bookSource.custom_order.toInt(),
        enabled = bookSource.enabled == 1L,
        enabledExplore = bookSource.enabled_explore == 1L,
        jsLib = bookSource.js_lib,
        enabledCookieJar = bookSource.enabled_cookie_jar == 1L,
        concurrentRate = bookSource.concurrent_rate,
        header = bookSource.header_json,
        loginUrl = bookSource.login_url,
        loginUi = bookSource.login_ui,
        loginCheckJs = bookSource.login_check_js,
        coverDecodeJs = bookSource.cover_decode_js,
        bookSourceComment = bookSource.book_source_comment,
        variableComment = bookSource.variable_comment,
        lastUpdateTime = bookSource.last_update_time,
        respondTime = bookSource.respond_time,
        weight = bookSource.weight.toInt(),
        exploreUrl = bookSource.explore_url,
        exploreScreen = bookSource.explore_screen,
        ruleExplore = bookSource.rule_explore?.let { BookSourceAdapter.decodeExploreRule(it) },
        searchUrl = bookSource.search_url,
        ruleSearch = bookSource.rule_search?.let { BookSourceAdapter.decodeSearchRule(it) },
        ruleBookInfo = bookSource.rule_book_info?.let { BookSourceAdapter.decodeBookInfoRule(it) },
        ruleToc = bookSource.rule_toc?.let { BookSourceAdapter.decodeTocRule(it) },
        ruleContent = bookSource.rule_content?.let { BookSourceAdapter.decodeContentRule(it) },
        ruleReview = bookSource.rule_review?.let { BookSourceAdapter.decodeReviewRule(it) }
    )

    /**
     * Map SQLDelight generated SelectExplore to domain model
     */
    private fun mapToBookSource(bookSource: SelectExplore): BookSource = BookSource(
        bookSourceUrl = bookSource.book_source_url,
        bookSourceName = bookSource.book_source_name,
        bookSourceGroup = bookSource.book_source_group,
        bookSourceType = bookSource.book_source_type.toInt(),
        bookUrlPattern = bookSource.book_url_pattern,
        customOrder = bookSource.custom_order.toInt(),
        enabled = bookSource.enabled == 1L,
        enabledExplore = bookSource.enabled_explore == 1L,
        jsLib = bookSource.js_lib,
        enabledCookieJar = bookSource.enabled_cookie_jar == 1L,
        concurrentRate = bookSource.concurrent_rate,
        header = bookSource.header_json,
        loginUrl = bookSource.login_url,
        loginUi = bookSource.login_ui,
        loginCheckJs = bookSource.login_check_js,
        coverDecodeJs = bookSource.cover_decode_js,
        bookSourceComment = bookSource.book_source_comment,
        variableComment = bookSource.variable_comment,
        lastUpdateTime = bookSource.last_update_time,
        respondTime = bookSource.respond_time,
        weight = bookSource.weight.toInt(),
        exploreUrl = bookSource.explore_url,
        exploreScreen = bookSource.explore_screen,
        ruleExplore = bookSource.rule_explore?.let { BookSourceAdapter.decodeExploreRule(it) },
        searchUrl = bookSource.search_url,
        ruleSearch = bookSource.rule_search?.let { BookSourceAdapter.decodeSearchRule(it) },
        ruleBookInfo = bookSource.rule_book_info?.let { BookSourceAdapter.decodeBookInfoRule(it) },
        ruleToc = bookSource.rule_toc?.let { BookSourceAdapter.decodeTocRule(it) },
        ruleContent = bookSource.rule_content?.let { BookSourceAdapter.decodeContentRule(it) },
        ruleReview = bookSource.rule_review?.let { BookSourceAdapter.decodeReviewRule(it) }
    )

    /**
     * Map SQLDelight generated SelectLogin to domain model
     */
    private fun mapToBookSource(bookSource: SelectLogin): BookSource = BookSource(
        bookSourceUrl = bookSource.book_source_url,
        bookSourceName = bookSource.book_source_name,
        bookSourceGroup = bookSource.book_source_group,
        bookSourceType = bookSource.book_source_type.toInt(),
        bookUrlPattern = bookSource.book_url_pattern,
        customOrder = bookSource.custom_order.toInt(),
        enabled = bookSource.enabled == 1L,
        enabledExplore = bookSource.enabled_explore == 1L,
        jsLib = bookSource.js_lib,
        enabledCookieJar = bookSource.enabled_cookie_jar == 1L,
        concurrentRate = bookSource.concurrent_rate,
        header = bookSource.header_json,
        loginUrl = bookSource.login_url,
        loginUi = bookSource.login_ui,
        loginCheckJs = bookSource.login_check_js,
        coverDecodeJs = bookSource.cover_decode_js,
        bookSourceComment = bookSource.book_source_comment,
        variableComment = bookSource.variable_comment,
        lastUpdateTime = bookSource.last_update_time,
        respondTime = bookSource.respond_time,
        weight = bookSource.weight.toInt(),
        exploreUrl = bookSource.explore_url,
        exploreScreen = bookSource.explore_screen,
        ruleExplore = bookSource.rule_explore?.let { BookSourceAdapter.decodeExploreRule(it) },
        searchUrl = bookSource.search_url,
        ruleSearch = bookSource.rule_search?.let { BookSourceAdapter.decodeSearchRule(it) },
        ruleBookInfo = bookSource.rule_book_info?.let { BookSourceAdapter.decodeBookInfoRule(it) },
        ruleToc = bookSource.rule_toc?.let { BookSourceAdapter.decodeTocRule(it) },
        ruleContent = bookSource.rule_content?.let { BookSourceAdapter.decodeContentRule(it) },
        ruleReview = bookSource.rule_review?.let { BookSourceAdapter.decodeReviewRule(it) }
    )

    /**
     * Map SQLDelight generated SelectByType to domain model
     */
    private fun mapToBookSource(bookSource: SelectByType): BookSource = BookSource(
        bookSourceUrl = bookSource.book_source_url,
        bookSourceName = bookSource.book_source_name,
        bookSourceGroup = bookSource.book_source_group,
        bookSourceType = bookSource.book_source_type.toInt(),
        bookUrlPattern = bookSource.book_url_pattern,
        customOrder = bookSource.custom_order.toInt(),
        enabled = bookSource.enabled == 1L,
        enabledExplore = bookSource.enabled_explore == 1L,
        jsLib = bookSource.js_lib,
        enabledCookieJar = bookSource.enabled_cookie_jar == 1L,
        concurrentRate = bookSource.concurrent_rate,
        header = bookSource.header_json,
        loginUrl = bookSource.login_url,
        loginUi = bookSource.login_ui,
        loginCheckJs = bookSource.login_check_js,
        coverDecodeJs = bookSource.cover_decode_js,
        bookSourceComment = bookSource.book_source_comment,
        variableComment = bookSource.variable_comment,
        lastUpdateTime = bookSource.last_update_time,
        respondTime = bookSource.respond_time,
        weight = bookSource.weight.toInt(),
        exploreUrl = bookSource.explore_url,
        exploreScreen = bookSource.explore_screen,
        ruleExplore = bookSource.rule_explore?.let { BookSourceAdapter.decodeExploreRule(it) },
        searchUrl = bookSource.search_url,
        ruleSearch = bookSource.rule_search?.let { BookSourceAdapter.decodeSearchRule(it) },
        ruleBookInfo = bookSource.rule_book_info?.let { BookSourceAdapter.decodeBookInfoRule(it) },
        ruleToc = bookSource.rule_toc?.let { BookSourceAdapter.decodeTocRule(it) },
        ruleContent = bookSource.rule_content?.let { BookSourceAdapter.decodeContentRule(it) },
        ruleReview = bookSource.rule_review?.let { BookSourceAdapter.decodeReviewRule(it) }
    )

    /**
     * Process groups result from SelectGroups wrapper types
     */
    private fun processGroupsFromSelectGroups(groups: List<SelectGroups>): List<String> {
        return processGroupNames(groups.map { it.book_source_group })
    }

    /**
     * Process groups result from SelectEnabledGroups wrapper types
     */
    private fun processGroupsFromSelectEnabledGroups(groups: List<SelectEnabledGroups>): List<String> {
        return processGroupNames(groups.map { it.book_source_group })
    }

    /**
     * Process groups result from SelectExploreGroups wrapper types
     */
    private fun processGroupsFromSelectExploreGroups(groups: List<SelectExploreGroups>): List<String> {
        return processGroupNames(groups.map { it.book_source_group })
    }

    private fun processGroupNames(groups: List<String?>): List<String> {
        val groupSet = linkedSetOf<String>()
        groups.forEach { group ->
            SourceGroups.split(group).forEach(groupSet::add)
        }
        return groupSet.sorted()
    }

    /**
     * Helper function to encode rule objects to JSON
     */
    private fun encodeRule(rule: Any): String = BookSourceAdapter.encodeRule(rule)
}
