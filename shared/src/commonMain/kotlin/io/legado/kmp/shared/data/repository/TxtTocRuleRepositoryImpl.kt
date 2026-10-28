package io.legado.kmp.shared.data.repository

import app.cash.sqldelight.coroutines.asFlow
import app.cash.sqldelight.coroutines.mapToList
import io.legado.kmp.shared.data.database.LegadoDatabase
import io.legado.kmp.shared.domain.repository.TxtTocRuleRepository
import io.legado.kmp.shared.model.TxtTocRule
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

class TxtTocRuleRepositoryImpl(
    private val database: LegadoDatabase
) : TxtTocRuleRepository {

    override fun observeAll(): Flow<List<TxtTocRule>> {
        return database.txtTocRuleQueries.selectAll(
            mapper = TxtTocRule::from
        )
            .asFlow()
            .mapToList(Dispatchers.Default)
            .map { it }
    }

    override suspend fun getAll(): List<TxtTocRule> {
        return database.txtTocRuleQueries.selectAll(
            mapper = TxtTocRule::from
        ).executeAsList()
    }

    override suspend fun getEnabled(): List<TxtTocRule> {
        return database.txtTocRuleQueries.selectEnabled(
            mapper = TxtTocRule::from
        ).executeAsList()
    }

    override suspend fun getDisabled(): List<TxtTocRule> {
        return database.txtTocRuleQueries.selectDisabled(
            mapper = TxtTocRule::from
        ).executeAsList()
    }

    override suspend fun count(): Int {
        return database.txtTocRuleQueries.countAll().executeAsOne().toInt()
    }

    override suspend fun get(id: Long): TxtTocRule? {
        return database.txtTocRuleQueries.selectById(
            id = id,
            mapper = TxtTocRule::from
        ).executeAsOneOrNull()
    }

    override suspend fun getMinOrder(): Int {
        return database.txtTocRuleQueries.minOrder().executeAsOne().toInt()
    }

    override suspend fun getMaxOrder(): Int {
        return database.txtTocRuleQueries.maxOrder().executeAsOne().toInt()
    }

    override suspend fun insert(rule: TxtTocRule) {
        database.txtTocRuleQueries.insert(
            id = rule.id,
            name = rule.name,
            rule = rule.rule,
            example = rule.example,
            serial_number = rule.serialNumber.toLong(),
            enable = if (rule.enable) 1L else 0L
        )
    }

    override suspend fun update(rule: TxtTocRule) {
        database.txtTocRuleQueries.update(
            name = rule.name,
            rule = rule.rule,
            example = rule.example,
            serial_number = rule.serialNumber.toLong(),
            enable = if (rule.enable) 1L else 0L,
            id = rule.id
        )
    }

    override suspend fun delete(id: Long) {
        database.txtTocRuleQueries.deleteById(id)
    }

    override suspend fun deleteDefault() {
        database.txtTocRuleQueries.deleteDefault()
    }
}
