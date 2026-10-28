package io.legado.kmp.shared.data.repository

import app.cash.sqldelight.coroutines.asFlow
import app.cash.sqldelight.coroutines.mapToList
import io.legado.kmp.shared.data.database.LegadoDatabase
import io.legado.kmp.shared.domain.repository.BookChapterReviewRepository
import io.legado.kmp.shared.domain.repository.DictRuleRepository
import io.legado.kmp.shared.domain.repository.HttpTTSRepository
import io.legado.kmp.shared.domain.repository.KeyboardAssistRepository
import io.legado.kmp.shared.domain.repository.RuleSubRepository
import io.legado.kmp.shared.domain.repository.ServerRepository
import io.legado.kmp.shared.model.BookChapterReview
import io.legado.kmp.shared.model.DictRule
import io.legado.kmp.shared.model.HttpTTS
import io.legado.kmp.shared.model.KeyboardAssist
import io.legado.kmp.shared.model.RuleSub
import io.legado.kmp.shared.model.Server
import io.legado.kmp.shared.model.ServerType
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

class BookChapterReviewRepositoryImpl(
    private val database: LegadoDatabase,
) : BookChapterReviewRepository {
    override fun observeAll(): Flow<List<BookChapterReview>> {
        return database.bookChapterReviewQueries.selectAll().asFlow().mapToList(Dispatchers.Default).map { list ->
            list.map { BookChapterReview(it.book_id, it.chapter_id, it.summary_url) }
        }
    }

    override suspend fun getAll(): List<BookChapterReview> {
        return database.bookChapterReviewQueries.selectAll().executeAsList().map {
            BookChapterReview(it.book_id, it.chapter_id, it.summary_url)
        }
    }

    override suspend fun getByBookId(bookId: Long): List<BookChapterReview> {
        return database.bookChapterReviewQueries.selectByBookId(bookId).executeAsList().map {
            BookChapterReview(it.book_id, it.chapter_id, it.summary_url)
        }
    }

    override suspend fun get(bookId: Long, chapterId: Long): BookChapterReview? {
        return database.bookChapterReviewQueries.selectByIds(bookId, chapterId).executeAsOneOrNull()?.let {
            BookChapterReview(it.book_id, it.chapter_id, it.summary_url)
        }
    }

    override suspend fun save(review: BookChapterReview) {
        database.bookChapterReviewQueries.insert(review.bookId, review.chapterId, review.summaryUrl)
    }

    override suspend fun delete(bookId: Long, chapterId: Long) {
        database.bookChapterReviewQueries.deleteByIds(bookId, chapterId)
    }

    override suspend fun deleteByBookId(bookId: Long) {
        database.bookChapterReviewQueries.deleteByBookId(bookId)
    }
}

class DictRuleRepositoryImpl(
    private val database: LegadoDatabase,
) : DictRuleRepository {
    override fun observeAll(): Flow<List<DictRule>> {
        return database.dictRuleQueries.selectAll().asFlow().mapToList(Dispatchers.Default).map { rows ->
            rows.map { DictRule(it.name, it.url_rule, it.show_rule, it.enabled == 1L, it.sort_number.toInt()) }
        }
    }

    override fun observeEnabled(): Flow<List<DictRule>> {
        return database.dictRuleQueries.selectEnabled().asFlow().mapToList(Dispatchers.Default).map { rows ->
            rows.map { DictRule(it.name, it.url_rule, it.show_rule, it.enabled == 1L, it.sort_number.toInt()) }
        }
    }

    override suspend fun getAll(): List<DictRule> = database.dictRuleQueries.selectAll().executeAsList().map {
        DictRule(it.name, it.url_rule, it.show_rule, it.enabled == 1L, it.sort_number.toInt())
    }

    override suspend fun getEnabled(): List<DictRule> = database.dictRuleQueries.selectEnabled().executeAsList().map {
        DictRule(it.name, it.url_rule, it.show_rule, it.enabled == 1L, it.sort_number.toInt())
    }

    override suspend fun get(name: String): DictRule? = database.dictRuleQueries.selectByName(name).executeAsOneOrNull()?.let {
        DictRule(it.name, it.url_rule, it.show_rule, it.enabled == 1L, it.sort_number.toInt())
    }

    override suspend fun save(rule: DictRule) {
        database.dictRuleQueries.insert(rule.name, rule.urlRule, rule.showRule, if (rule.enabled) 1L else 0L, rule.sortNumber.toLong())
    }

    override suspend fun saveAll(rules: List<DictRule>) {
        rules.forEach { save(it) }
    }

    override suspend fun delete(name: String) {
        database.dictRuleQueries.deleteByName(name)
    }

    override suspend fun deleteAll() {
        database.dictRuleQueries.deleteAll()
    }
}

class HttpTTSRepositoryImpl(
    private val database: LegadoDatabase,
) : HttpTTSRepository {
    override fun observeAll(): Flow<List<HttpTTS>> {
        return database.httpTTSQueries.selectAll().asFlow().mapToList(Dispatchers.Default).map { rows ->
            rows.map {
                HttpTTS(
                    id = it.id,
                    name = it.name,
                    url = it.url,
                    contentType = it.content_type,
                    concurrentRate = it.concurrent_rate,
                    loginUrl = it.login_url,
                    loginUi = it.login_ui,
                    header = it.header_,
                    jsLib = it.js_lib,
                    enabledCookieJar = it.enabled_cookie_jar == 1L,
                    loginCheckJs = it.login_check_js,
                    lastUpdateTime = it.last_update_time,
                )
            }
        }
    }

    override suspend fun getAll(): List<HttpTTS> = database.httpTTSQueries.selectAll().executeAsList().map {
        HttpTTS(
            id = it.id,
            name = it.name,
            url = it.url,
            contentType = it.content_type,
            concurrentRate = it.concurrent_rate,
            loginUrl = it.login_url,
            loginUi = it.login_ui,
            header = it.header_,
            jsLib = it.js_lib,
            enabledCookieJar = it.enabled_cookie_jar == 1L,
            loginCheckJs = it.login_check_js,
            lastUpdateTime = it.last_update_time,
        )
    }

    override suspend fun get(id: Long): HttpTTS? = database.httpTTSQueries.selectById(id).executeAsOneOrNull()?.let {
        HttpTTS(
            id = it.id,
            name = it.name,
            url = it.url,
            contentType = it.content_type,
            concurrentRate = it.concurrent_rate,
            loginUrl = it.login_url,
            loginUi = it.login_ui,
            header = it.header_,
            jsLib = it.js_lib,
            enabledCookieJar = it.enabled_cookie_jar == 1L,
            loginCheckJs = it.login_check_js,
            lastUpdateTime = it.last_update_time,
        )
    }

    override suspend fun save(engine: HttpTTS) {
        database.httpTTSQueries.insert(
            engine.id,
            engine.name,
            engine.url,
            engine.contentType,
            engine.concurrentRate,
            engine.loginUrl,
            engine.loginUi,
            engine.header,
            engine.jsLib,
            if (engine.enabledCookieJar) 1L else 0L,
            engine.loginCheckJs,
            engine.lastUpdateTime,
        )
    }

    override suspend fun saveAll(engines: List<HttpTTS>) {
        engines.forEach { save(it) }
    }

    override suspend fun delete(id: Long) {
        database.httpTTSQueries.deleteById(id)
    }

    override suspend fun deleteAll() {
        database.httpTTSQueries.deleteAll()
    }
}

class KeyboardAssistRepositoryImpl(
    private val database: LegadoDatabase,
) : KeyboardAssistRepository {
    override fun observeAll(): Flow<List<KeyboardAssist>> {
        return database.keyboardAssistQueries.selectAll().asFlow().mapToList(Dispatchers.Default).map { rows ->
            rows.map { KeyboardAssist(it.type.toInt(), it.key, it.value_, it.serial_no.toInt()) }
        }
    }

    override suspend fun getAll(): List<KeyboardAssist> = database.keyboardAssistQueries.selectAll().executeAsList().map {
        KeyboardAssist(it.type.toInt(), it.key, it.value_, it.serial_no.toInt())
    }

    override suspend fun getByType(type: Int): List<KeyboardAssist> = database.keyboardAssistQueries.selectByType(type.toLong()).executeAsList().map {
        KeyboardAssist(it.type.toInt(), it.key, it.value_, it.serial_no.toInt())
    }

    override suspend fun save(assist: KeyboardAssist) {
        database.keyboardAssistQueries.insert(assist.type.toLong(), assist.key, assist.value, assist.serialNo.toLong())
    }

    override suspend fun saveReplacing(assist: KeyboardAssist, originalType: Int, originalKey: String?) {
        database.keyboardAssistQueries.transaction {
            if (originalKey != null) {
                require(database.keyboardAssistQueries.selectByType(originalType.toLong()).executeAsList().any {
                    it.key == originalKey
                }) { "键盘辅助项不存在" }
            }
            val keepsOriginalKey = originalKey != null && assist.type == originalType && assist.key == originalKey
            require(keepsOriginalKey || database.keyboardAssistQueries.selectByType(assist.type.toLong()).executeAsList().none {
                it.key == assist.key
            }) { "此类型下的辅助按键已存在" }
            database.keyboardAssistQueries.insert(assist.type.toLong(), assist.key, assist.value, assist.serialNo.toLong())
            if (originalKey != null && !keepsOriginalKey) {
                database.keyboardAssistQueries.deleteByTypeAndKey(originalType.toLong(), originalKey)
            }
        }
    }

    override suspend fun saveAll(assists: List<KeyboardAssist>) {
        assists.forEach { save(it) }
    }

    override suspend fun delete(type: Int, key: String) {
        database.keyboardAssistQueries.deleteByTypeAndKey(type.toLong(), key)
    }

    override suspend fun deleteAll() {
        database.keyboardAssistQueries.deleteAll()
    }
}

class RuleSubRepositoryImpl(
    private val database: LegadoDatabase,
) : RuleSubRepository {
    override fun observeAll(): Flow<List<RuleSub>> {
        return database.ruleSubQueries.selectAll().asFlow().mapToList(Dispatchers.Default).map { rows ->
            rows.map {
                RuleSub(
                    id = it.id,
                    name = it.name,
                    url = it.url,
                    type = it.type.toInt(),
                    customOrder = it.custom_order.toInt(),
                    autoUpdate = it.auto_update == 1L,
                    update = it.updated_at,
                )
            }
        }
    }

    override suspend fun getAll(): List<RuleSub> = database.ruleSubQueries.selectAll().executeAsList().map {
        RuleSub(
            id = it.id,
            name = it.name,
            url = it.url,
            type = it.type.toInt(),
            customOrder = it.custom_order.toInt(),
            autoUpdate = it.auto_update == 1L,
            update = it.updated_at,
        )
    }

    override suspend fun get(id: Long): RuleSub? = database.ruleSubQueries.selectById(id).executeAsOneOrNull()?.let {
        RuleSub(
            id = it.id,
            name = it.name,
            url = it.url,
            type = it.type.toInt(),
            customOrder = it.custom_order.toInt(),
            autoUpdate = it.auto_update == 1L,
            update = it.updated_at,
        )
    }

    override suspend fun save(ruleSub: RuleSub) {
        database.ruleSubQueries.insert(
            ruleSub.id,
            ruleSub.name,
            ruleSub.url,
            ruleSub.type.toLong(),
            ruleSub.customOrder.toLong(),
            if (ruleSub.autoUpdate) 1L else 0L,
            ruleSub.update,
        )
    }

    override suspend fun saveAll(ruleSubs: List<RuleSub>) {
        ruleSubs.forEach { save(it) }
    }

    override suspend fun delete(id: Long) {
        database.ruleSubQueries.deleteById(id)
    }

    override suspend fun deleteAll() {
        database.ruleSubQueries.deleteAll()
    }
}

class ServerRepositoryImpl(
    private val database: LegadoDatabase,
) : ServerRepository {
    override fun observeAll(): Flow<List<Server>> {
        return database.serverQueries.selectAll().asFlow().mapToList(Dispatchers.Default).map { rows ->
            rows.map {
                Server(
                    id = it.id,
                    name = it.name,
                    type = runCatching { ServerType.valueOf(it.type) }.getOrDefault(ServerType.WEBDAV),
                    config = it.config,
                    sortNumber = it.sort_number.toInt(),
                )
            }
        }
    }

    override suspend fun getAll(): List<Server> = database.serverQueries.selectAll().executeAsList().map {
        Server(
            id = it.id,
            name = it.name,
            type = runCatching { ServerType.valueOf(it.type) }.getOrDefault(ServerType.WEBDAV),
            config = it.config,
            sortNumber = it.sort_number.toInt(),
        )
    }

    override suspend fun get(id: Long): Server? = database.serverQueries.selectById(id).executeAsOneOrNull()?.let {
        Server(
            id = it.id,
            name = it.name,
            type = runCatching { ServerType.valueOf(it.type) }.getOrDefault(ServerType.WEBDAV),
            config = it.config,
            sortNumber = it.sort_number.toInt(),
        )
    }

    override suspend fun save(server: Server) {
        database.serverQueries.insert(server.id, server.name, server.type.name, server.config, server.sortNumber.toLong())
    }

    override suspend fun saveAll(servers: List<Server>) {
        servers.forEach { save(it) }
    }

    override suspend fun delete(id: Long) {
        database.serverQueries.deleteById(id)
    }

    override suspend fun deleteAll() {
        database.serverQueries.deleteAll()
    }
}
