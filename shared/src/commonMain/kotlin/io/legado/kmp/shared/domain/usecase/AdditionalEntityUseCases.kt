package io.legado.kmp.shared.domain.usecase

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
import kotlinx.coroutines.flow.Flow

class GetBookChapterReviewsUseCase(private val repository: BookChapterReviewRepository) {
    operator fun invoke(): Flow<List<BookChapterReview>> = repository.observeAll()
    suspend fun getAll(): List<BookChapterReview> = repository.getAll()
    suspend fun getByBookId(bookId: Long): List<BookChapterReview> = repository.getByBookId(bookId)
}

class SaveBookChapterReviewUseCase(private val repository: BookChapterReviewRepository) {
    suspend fun save(review: BookChapterReview) = repository.save(review)
}

class DeleteBookChapterReviewUseCase(private val repository: BookChapterReviewRepository) {
    suspend fun delete(bookId: Long, chapterId: Long) = repository.delete(bookId, chapterId)
}

class GetDictRulesUseCase(private val repository: DictRuleRepository) {
    operator fun invoke(): Flow<List<DictRule>> = repository.observeAll()
    fun observeEnabled(): Flow<List<DictRule>> = repository.observeEnabled()
    suspend fun getAll(): List<DictRule> = repository.getAll()
    suspend fun getEnabled(): List<DictRule> = repository.getEnabled()
}

class SaveDictRuleUseCase(private val repository: DictRuleRepository) {
    suspend fun save(rule: DictRule) = repository.save(rule)
    suspend fun saveAll(rules: List<DictRule>) = repository.saveAll(rules)
}

class DeleteDictRuleUseCase(private val repository: DictRuleRepository) {
    suspend fun delete(name: String) = repository.delete(name)
    suspend fun deleteAll() = repository.deleteAll()
}

class GetHttpTTSUseCase(private val repository: HttpTTSRepository) {
    operator fun invoke(): Flow<List<HttpTTS>> = repository.observeAll()
    suspend fun getAll(): List<HttpTTS> = repository.getAll()
}

class SaveHttpTTSUseCase(private val repository: HttpTTSRepository) {
    suspend fun save(engine: HttpTTS) = repository.save(engine)
    suspend fun saveAll(engines: List<HttpTTS>) = repository.saveAll(engines)
}

class DeleteHttpTTSUseCase(private val repository: HttpTTSRepository) {
    suspend fun delete(id: Long) = repository.delete(id)
    suspend fun deleteAll() = repository.deleteAll()
}

class GetKeyboardAssistsUseCase(private val repository: KeyboardAssistRepository) {
    operator fun invoke(): Flow<List<KeyboardAssist>> = repository.observeAll()
    suspend fun getAll(): List<KeyboardAssist> = repository.getAll()
    suspend fun getByType(type: Int): List<KeyboardAssist> = repository.getByType(type)
}

class SaveKeyboardAssistUseCase(private val repository: KeyboardAssistRepository) {
    suspend fun save(assist: KeyboardAssist) = repository.save(assist)
    suspend fun saveAll(assists: List<KeyboardAssist>) = repository.saveAll(assists)
}

class DeleteKeyboardAssistUseCase(private val repository: KeyboardAssistRepository) {
    suspend fun delete(type: Int, key: String) = repository.delete(type, key)
    suspend fun deleteAll() = repository.deleteAll()
}

class GetRuleSubsUseCase(private val repository: RuleSubRepository) {
    operator fun invoke(): Flow<List<RuleSub>> = repository.observeAll()
    suspend fun getAll(): List<RuleSub> = repository.getAll()
}

class SaveRuleSubUseCase(private val repository: RuleSubRepository) {
    suspend fun save(ruleSub: RuleSub) = repository.save(ruleSub)
    suspend fun saveAll(ruleSubs: List<RuleSub>) = repository.saveAll(ruleSubs)
}

class DeleteRuleSubUseCase(private val repository: RuleSubRepository) {
    suspend fun delete(id: Long) = repository.delete(id)
    suspend fun deleteAll() = repository.deleteAll()
}

class GetServersUseCase(private val repository: ServerRepository) {
    operator fun invoke(): Flow<List<Server>> = repository.observeAll()
    suspend fun getAll(): List<Server> = repository.getAll()
}

class SaveServerUseCase(private val repository: ServerRepository) {
    suspend fun save(server: Server) = repository.save(server)
    suspend fun saveAll(servers: List<Server>) = repository.saveAll(servers)
}

class DeleteServerUseCase(private val repository: ServerRepository) {
    suspend fun delete(id: Long) = repository.delete(id)
    suspend fun deleteAll() = repository.deleteAll()
}
