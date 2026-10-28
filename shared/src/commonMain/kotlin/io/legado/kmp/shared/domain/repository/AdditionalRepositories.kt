package io.legado.kmp.shared.domain.repository

import io.legado.kmp.shared.model.BookChapterReview
import io.legado.kmp.shared.model.DictRule
import io.legado.kmp.shared.model.HttpTTS
import io.legado.kmp.shared.model.KeyboardAssist
import io.legado.kmp.shared.model.RuleSub
import io.legado.kmp.shared.model.Server
import kotlinx.coroutines.flow.Flow

interface BookChapterReviewRepository {
    fun observeAll(): Flow<List<BookChapterReview>>
    suspend fun getAll(): List<BookChapterReview>
    suspend fun getByBookId(bookId: Long): List<BookChapterReview>
    suspend fun get(bookId: Long, chapterId: Long): BookChapterReview?
    suspend fun save(review: BookChapterReview)
    suspend fun delete(bookId: Long, chapterId: Long)
    suspend fun deleteByBookId(bookId: Long)
}

interface DictRuleRepository {
    fun observeAll(): Flow<List<DictRule>>
    fun observeEnabled(): Flow<List<DictRule>>
    suspend fun getAll(): List<DictRule>
    suspend fun getEnabled(): List<DictRule>
    suspend fun get(name: String): DictRule?
    suspend fun save(rule: DictRule)
    suspend fun saveAll(rules: List<DictRule>)
    suspend fun delete(name: String)
    suspend fun deleteAll()
}

interface HttpTTSRepository {
    fun observeAll(): Flow<List<HttpTTS>>
    suspend fun getAll(): List<HttpTTS>
    suspend fun get(id: Long): HttpTTS?
    suspend fun save(engine: HttpTTS)
    suspend fun saveAll(engines: List<HttpTTS>)
    suspend fun delete(id: Long)
    suspend fun deleteAll()
}

interface KeyboardAssistRepository {
    fun observeAll(): Flow<List<KeyboardAssist>>
    suspend fun getAll(): List<KeyboardAssist>
    suspend fun getByType(type: Int): List<KeyboardAssist>
    suspend fun save(assist: KeyboardAssist)
    /** Null originalKey inserts a new record; otherwise replace the original atomically without overwriting another key. */
    suspend fun saveReplacing(assist: KeyboardAssist, originalType: Int, originalKey: String?)
    suspend fun saveAll(assists: List<KeyboardAssist>)
    suspend fun delete(type: Int, key: String)
    suspend fun deleteAll()
}

interface RuleSubRepository {
    fun observeAll(): Flow<List<RuleSub>>
    suspend fun getAll(): List<RuleSub>
    suspend fun get(id: Long): RuleSub?
    suspend fun save(ruleSub: RuleSub)
    suspend fun saveAll(ruleSubs: List<RuleSub>)
    suspend fun delete(id: Long)
    suspend fun deleteAll()
}

interface ServerRepository {
    fun observeAll(): Flow<List<Server>>
    suspend fun getAll(): List<Server>
    suspend fun get(id: Long): Server?
    suspend fun save(server: Server)
    suspend fun saveAll(servers: List<Server>)
    suspend fun delete(id: Long)
    suspend fun deleteAll()
}
