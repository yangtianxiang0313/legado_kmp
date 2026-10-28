package io.legado.kmp.shared.data.repository

import app.cash.sqldelight.coroutines.asFlow
import app.cash.sqldelight.coroutines.mapToList
import io.legado.kmp.data.database.schema.Replace_rules
import io.legado.kmp.shared.data.database.LegadoDatabase
import io.legado.kmp.shared.domain.repository.ReplaceRuleRepository
import io.legado.kmp.shared.model.ReplaceRule
import io.legado.kmp.shared.model.appliesToScope
import io.legado.kmp.shared.model.isExcludedForScope
import io.legado.kmp.shared.model.shouldApply
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

/**
 * SQLDelight implementation of ReplaceRuleRepository
 * Uses the generated SQLDelight queries for database operations
 */
class ReplaceRuleRepositoryImpl(
    private val database: LegadoDatabase
) : ReplaceRuleRepository {

    override fun observeAllRules(): Flow<List<ReplaceRule>> {
        return database.replaceRuleQueries
            .selectAll()
            .asFlow()
            .mapToList(Dispatchers.Default)
            .map { list ->
                list.map { rule ->
                    mapFromDb(rule)
                }
            }
    }

    override fun observeEnabledRules(): Flow<List<ReplaceRule>> {
        return database.replaceRuleQueries
            .selectEnabled()
            .asFlow()
            .mapToList(Dispatchers.Default)
            .map { list ->
                list.map { rule ->
                    mapFromDb(rule)
                }
            }
    }

    override suspend fun getAllRules(): List<ReplaceRule> {
        return database.replaceRuleQueries
            .selectAll()
            .executeAsList()
            .map { rule -> mapFromDb(rule) }
    }

    override suspend fun getEnabledRules(): List<ReplaceRule> {
        return database.replaceRuleQueries
            .selectEnabled()
            .executeAsList()
            .map { rule -> mapFromDb(rule) }
    }

    override suspend fun getById(id: Long): ReplaceRule? {
        return database.replaceRuleQueries
            .selectById(id)
            .executeAsOneOrNull()?.let { rule -> mapFromDb(rule) }
    }

    override suspend fun getByGroup(group: String): List<ReplaceRule> {
        return database.replaceRuleQueries
            .selectByGroup(group)
            .executeAsList()
            .map { rule -> mapFromDb(rule) }
    }

    override suspend fun searchByName(name: String): List<ReplaceRule> {
        val pattern = "%$name%"
        return database.replaceRuleQueries
            .searchByName(pattern)
            .executeAsList()
            .map { rule -> mapFromDb(rule) }
    }

    override suspend fun insert(rule: ReplaceRule): Long {
        database.replaceRuleQueries.insert(
            id = rule.id,
            name = rule.name,
            rule_group = rule.group,
            pattern = rule.pattern,
            replacement = rule.replacement,
            scope = rule.scope,
            scope_title = if (rule.scopeTitle) 1L else 0L,
            scope_content = if (rule.scopeContent) 1L else 0L,
            exclude_scope = rule.excludeScope,
            is_enabled = if (rule.isEnabled) 1L else 0L,
            is_regex = if (rule.isRegex) 1L else 0L,
            timeout_millisecond = rule.timeoutMillisecond,
            sort_order = rule.order.toLong()
        )
        return rule.id
    }

    override suspend fun insertAll(rules: List<ReplaceRule>) {
        rules.forEach { rule ->
            insert(rule)
        }
    }

    override suspend fun update(rule: ReplaceRule) {
        database.replaceRuleQueries.update(
            name = rule.name,
            rule_group = rule.group,
            pattern = rule.pattern,
            replacement = rule.replacement,
            scope = rule.scope,
            scope_title = if (rule.scopeTitle) 1L else 0L,
            scope_content = if (rule.scopeContent) 1L else 0L,
            exclude_scope = rule.excludeScope,
            is_enabled = if (rule.isEnabled) 1L else 0L,
            is_regex = if (rule.isRegex) 1L else 0L,
            timeout_millisecond = rule.timeoutMillisecond,
            sort_order = rule.order.toLong(),
            id = rule.id
        )
    }

    override suspend fun updateEnabled(id: Long, enabled: Boolean) {
        database.replaceRuleQueries.updateEnabled(
            is_enabled = if (enabled) 1L else 0L,
            id = id
        )
    }

    override suspend fun updateOrder(id: Long, order: Int) {
        database.replaceRuleQueries.updateOrder(
            sort_order = order.toLong(),
            id = id
        )
    }

    override suspend fun deleteById(id: Long) {
        database.replaceRuleQueries.deleteById(id)
    }

    override suspend fun delete(rule: ReplaceRule) {
        deleteById(rule.id)
    }

    override suspend fun deleteAll() {
        database.replaceRuleQueries.deleteAll()
    }

    override suspend fun save(rule: ReplaceRule) {
        // Since we use INSERT OR REPLACE in the schema, we can use insert directly
        insert(rule)
    }

    override suspend fun count(): Int {
        return getAllRules().size
    }

    override suspend fun countEnabled(): Int {
        return getEnabledRules().size
    }

    override suspend fun getApplicableRules(sourceUrl: String?): List<ReplaceRule> {
        return getEnabledRules().filter { rule ->
            rule.shouldApply(sourceUrl)
        }
    }

    /**
     * Map from SQLDelight generated Replace_rules to ReplaceRule model
     */
    private fun mapFromDb(rule: Replace_rules): ReplaceRule {
        return ReplaceRule.from(
            id = rule.id,
            name = rule.name,
            rule_group = rule.rule_group,
            pattern = rule.pattern,
            replacement = rule.replacement,
            scope = rule.scope,
            scope_title = rule.scope_title,
            scope_content = rule.scope_content,
            exclude_scope = rule.exclude_scope,
            is_enabled = rule.is_enabled,
            is_regex = rule.is_regex,
            timeout_millisecond = rule.timeout_millisecond,
            sort_order = rule.sort_order
        )
    }
}
