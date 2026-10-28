package io.legado.kmp.shared.domain.repository

import io.legado.kmp.shared.model.ReplaceRule
import kotlinx.coroutines.flow.Flow

/**
 * Repository interface for ReplaceRule operations
 * Abstracts the data source and provides a clean API for the domain layer
 */
interface ReplaceRuleRepository {

    /**
     * Observe all replacement rules as a Flow
     *
     * @return Flow emitting list of all replacement rules
     */
    fun observeAllRules(): Flow<List<ReplaceRule>>

    /**
     * Observe only enabled replacement rules as a Flow
     *
     * @return Flow emitting list of enabled replacement rules
     */
    fun observeEnabledRules(): Flow<List<ReplaceRule>>

    /**
     * Get all replacement rules (one-time query)
     *
     * @return List of all replacement rules
     */
    suspend fun getAllRules(): List<ReplaceRule>

    /**
     * Get only enabled replacement rules (one-time query)
     *
     * @return List of enabled replacement rules
     */
    suspend fun getEnabledRules(): List<ReplaceRule>

    /**
     * Get a specific rule by its ID
     *
     * @param id The rule ID
     * @return The rule if found, null otherwise
     */
    suspend fun getById(id: Long): ReplaceRule?

    /**
     * Get rules by group
     *
     * @param group The group name
     * @return List of rules in the group
     */
    suspend fun getByGroup(group: String): List<ReplaceRule>

    /**
     * Search rules by name
     *
     * @param name The search keyword
     * @return List of matching rules
     */
    suspend fun searchByName(name: String): List<ReplaceRule>

    /**
     * Insert a new rule
     *
     * @param rule The rule to insert
     * @return The ID of the inserted rule
     */
    suspend fun insert(rule: ReplaceRule): Long

    /**
     * Insert multiple rules in a single transaction
     *
     * @param rules List of rules to insert
     */
    suspend fun insertAll(rules: List<ReplaceRule>)

    /**
     * Update an existing rule
     *
     * @param rule The rule with updated values
     */
    suspend fun update(rule: ReplaceRule)

    /**
     * Update the enabled status of a rule
     *
     * @param id The rule ID
     * @param enabled The new enabled status
     */
    suspend fun updateEnabled(id: Long, enabled: Boolean)

    /**
     * Update the sort order of a rule
     *
     * @param id The rule ID
     * @param order The new sort order
     */
    suspend fun updateOrder(id: Long, order: Int)

    /**
     * Delete a rule by its ID
     *
     * @param id The rule ID
     */
    suspend fun deleteById(id: Long)

    /**
     * Delete a specific rule
     *
     * @param rule The rule to delete
     */
    suspend fun delete(rule: ReplaceRule)

    /**
     * Delete all rules
     */
    suspend fun deleteAll()

    /**
     * Insert or update a rule (upsert)
     *
     * @param rule The rule to insert or update
     */
    suspend fun save(rule: ReplaceRule)

    /**
     * Count all rules
     *
     * @return The number of rules
     */
    suspend fun count(): Int

    /**
     * Count enabled rules
     *
     * @return The number of enabled rules
     */
    suspend fun countEnabled(): Int

    /**
     * Get rules that should be applied for a specific source
     *
     * @param sourceUrl The source URL
     * @return List of applicable rules
     */
    suspend fun getApplicableRules(sourceUrl: String?): List<ReplaceRule>
}
