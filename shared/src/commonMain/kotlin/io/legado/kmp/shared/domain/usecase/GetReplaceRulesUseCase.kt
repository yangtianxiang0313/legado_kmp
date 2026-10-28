package io.legado.kmp.shared.domain.usecase

import io.legado.kmp.shared.domain.repository.ReplaceRuleRepository
import io.legado.kmp.shared.model.ReplaceRule
import io.legado.kmp.shared.model.applyToTitle
import io.legado.kmp.shared.model.applyToContent
import kotlinx.coroutines.flow.Flow

/**
 * Use case for getting replacement rules
 * Encapsulates the business logic for replacement rule retrieval
 */
class GetReplaceRulesUseCase(
    private val repository: ReplaceRuleRepository
) {
    /**
     * Observe all replacement rules as a Flow
     *
     * @return Flow emitting list of all replacement rules
     */
    operator fun invoke(): Flow<List<ReplaceRule>> {
        return repository.observeAllRules()
    }

    /**
     * Observe only enabled replacement rules as a Flow
     *
     * @return Flow emitting list of enabled replacement rules
     */
    fun observeEnabled(): Flow<List<ReplaceRule>> {
        return repository.observeEnabledRules()
    }

    /**
     * Get all replacement rules (one-time)
     *
     * @return List of all replacement rules
     */
    suspend fun getAll(): List<ReplaceRule> {
        return repository.getAllRules()
    }

    /**
     * Get only enabled replacement rules (one-time)
     *
     * @return List of enabled replacement rules
     */
    suspend fun getEnabled(): List<ReplaceRule> {
        return repository.getEnabledRules()
    }

    /**
     * Get a specific rule by its ID
     *
     * @param id The rule ID
     * @return The rule if found, null otherwise
     */
    suspend fun getById(id: Long): ReplaceRule? {
        return repository.getById(id)
    }

    /**
     * Get rules by group
     *
     * @param group The group name
     * @return List of rules in the group
     */
    suspend fun getByGroup(group: String): List<ReplaceRule> {
        return repository.getByGroup(group)
    }

    /**
     * Search rules by name
     *
     * @param name The search keyword
     * @return List of matching rules
     */
    suspend fun searchByName(name: String): List<ReplaceRule> {
        return repository.searchByName(name)
    }

    /**
     * Get rules applicable for a specific source
     *
     * @param sourceUrl The source URL
     * @return List of applicable rules
     */
    suspend fun getApplicableRules(sourceUrl: String?): List<ReplaceRule> {
        return repository.getApplicableRules(sourceUrl)
    }

    /**
     * Count all rules
     *
     * @return The number of rules
     */
    suspend fun count(): Int {
        return repository.count()
    }

    /**
     * Count enabled rules
     *
     * @return The number of enabled rules
     */
    suspend fun countEnabled(): Int {
        return repository.countEnabled()
    }
}

/**
 * Use case for saving replacement rules (insert or update)
 */
class SaveReplaceRuleUseCase(
    private val repository: ReplaceRuleRepository
) {
    /**
     * Save a replacement rule (insert or update)
     *
     * @param rule The rule to save
     * @return The ID of the saved rule
     */
    suspend operator fun invoke(rule: ReplaceRule): Long {
        repository.save(rule)
        return rule.id
    }

    /**
     * Insert a single rule
     *
     * @param rule The rule to insert
     * @return The ID of the inserted rule
     */
    suspend fun insert(rule: ReplaceRule): Long {
        return repository.insert(rule)
    }

    /**
     * Insert multiple rules
     *
     * @param rules The rules to insert
     */
    suspend fun insertAll(rules: List<ReplaceRule>) {
        repository.insertAll(rules)
    }

    /**
     * Update an existing rule
     *
     * @param rule The rule with updated values
     */
    suspend fun update(rule: ReplaceRule) {
        repository.update(rule)
    }

    /**
     * Update the enabled status of a rule
     *
     * @param id The rule ID
     * @param enabled The new enabled status
     */
    suspend fun updateEnabled(id: Long, enabled: Boolean) {
        repository.updateEnabled(id, enabled)
    }

    /**
     * Toggle the enabled status of a rule
     *
     * @param id The rule ID
     */
    suspend fun toggleEnabled(id: Long) {
        val rule = repository.getById(id) ?: return
        repository.updateEnabled(id, !rule.isEnabled)
    }

    /**
     * Update the sort order of a rule
     *
     * @param id The rule ID
     * @param order The new sort order
     */
    suspend fun updateOrder(id: Long, order: Int) {
        repository.updateOrder(id, order)
    }

    /**
     * Create a new rule with minimal fields
     *
     * @param name The rule name
     * @param pattern The pattern to match
     * @param replacement The replacement string
     * @return The created rule with its ID
     */
    suspend fun create(name: String, pattern: String, replacement: String): ReplaceRule {
        val rule = ReplaceRule(
            id = io.legado.kmp.shared.util.currentTimeMillis(),
            name = name,
            pattern = pattern,
            replacement = replacement
        )
        repository.insert(rule)
        return rule
    }
}

/**
 * Use case for deleting replacement rules
 */
class DeleteReplaceRuleUseCase(
    private val repository: ReplaceRuleRepository
) {
    /**
     * Delete a rule by its ID
     *
     * @param id The rule ID
     */
    suspend operator fun invoke(id: Long) {
        repository.deleteById(id)
    }

    /**
     * Delete a specific rule
     *
     * @param rule The rule to delete
     */
    suspend fun delete(rule: ReplaceRule) {
        repository.delete(rule)
    }

    /**
     * Delete multiple rules
     *
     * @param rules The rules to delete
     */
    suspend fun deleteAll(rules: List<ReplaceRule>) {
        rules.forEach { rule ->
            repository.delete(rule)
        }
    }

    /**
     * Delete all rules
     * Use with caution!
     */
    suspend fun deleteAll() {
        repository.deleteAll()
    }
}

/**
 * Use case for applying replacement rules to text
 */
class ApplyReplaceRulesUseCase(
    private val repository: ReplaceRuleRepository
) {
    /**
     * Get all applicable rules for a specific source
     *
     * @param sourceUrl The source URL (for scope filtering)
     * @return List of applicable rules
     */
    suspend fun getApplicableRules(sourceUrl: String?): List<io.legado.kmp.shared.model.ReplaceRule> {
        return repository.getApplicableRules(sourceUrl)
    }

    /**
     * Apply all applicable rules to a title
     *
     * @param title The title to process
     * @param sourceUrl The source URL (for scope filtering)
     * @return The processed title
     */
    suspend fun applyToTitle(title: String, sourceUrl: String? = null): String {
        val rules = repository.getApplicableRules(sourceUrl)
            .filter { it.scopeTitle }

        return rules.fold(title) { acc, rule ->
            rule.applyToTitle(acc)
        }
    }

    /**
     * Apply all applicable rules to content
     *
     * @param content The content to process
     * @param sourceUrl The source URL (for scope filtering)
     * @return The processed content
     */
    suspend fun applyToContent(content: String, sourceUrl: String? = null): String {
        val rules = repository.getApplicableRules(sourceUrl)
            .filter { it.scopeContent }

        return rules.fold(content) { acc, rule ->
            rule.applyToContent(acc)
        }
    }

    /**
     * Apply all applicable rules to content, filtering by both sourceUrl and bookName.
     * Matches legacy behavior: scope matches if it contains bookName OR sourceUrl.
     *
     * @param content The content to process
     * @param sourceUrl The source URL (book origin)
     * @param bookName The book name (for book-level scope matching)
     * @return The processed content
     */
    suspend fun applyToContent(content: String, sourceUrl: String?, bookName: String): String {
        val rules = getEnabledRulesByScope(sourceUrl, bookName)
            .filter { it.scopeContent }

        return rules.fold(content) { acc, rule ->
            rule.applyToContent(acc)
        }
    }

    /**
     * Apply all applicable rules to a title, filtering by both sourceUrl and bookName.
     *
     * @param title The title to process
     * @param sourceUrl The source URL (book origin)
     * @param bookName The book name (for book-level scope matching)
     * @return The processed title
     */
    suspend fun applyToTitle(title: String, sourceUrl: String?, bookName: String): String {
        val rules = getEnabledRulesByScope(sourceUrl, bookName)
            .filter { it.scopeTitle }

        return rules.fold(title) { acc, rule ->
            rule.applyToTitle(acc)
        }
    }

    /**
     * Get enabled rules filtered by bookName + origin scope, matching legacy
     * findEnabledByContentScope / findEnabledByTitleScope SQL queries:
     *
     * scope LIKE '%' || :name || '%' OR scope LIKE '%' || :origin || '%' OR scope IS NULL OR scope = ''
     * AND (excludeScope IS NULL OR (excludeScope NOT LIKE '%' || :name || '%' AND excludeScope NOT LIKE '%' || :origin || '%'))
     */
    private suspend fun getEnabledRulesByScope(
        sourceUrl: String?,
        bookName: String,
    ): List<io.legado.kmp.shared.model.ReplaceRule> {
        return repository.getEnabledRules().filter { rule ->
            if (!rule.isEnabled) return@filter false
            // Scope check: null/blank scope means applies to all
            val scopeMatch = rule.scope.isNullOrBlank() ||
                (!sourceUrl.isNullOrBlank() && rule.scope.contains(sourceUrl)) ||
                (bookName.isNotBlank() && rule.scope.contains(bookName))
            if (!scopeMatch) return@filter false
            // Exclude scope check
            val excluded = !rule.excludeScope.isNullOrBlank() && (
                (!sourceUrl.isNullOrBlank() && rule.excludeScope.contains(sourceUrl)) ||
                    (bookName.isNotBlank() && rule.excludeScope.contains(bookName))
                )
            !excluded
        }
    }

    /**
     * Apply all applicable rules to both title and content
     *
     * @param title The title to process
     * @param content The content to process
     * @param sourceUrl The source URL (for scope filtering)
     * @return Pair of processed (title, content)
     */
    suspend fun applyToBoth(
        title: String,
        content: String,
        sourceUrl: String? = null
    ): Pair<String, String> {
        val rules = repository.getApplicableRules(sourceUrl)

        val processedTitle = rules
            .filter { it.scopeTitle }
            .fold(title) { acc, rule -> rule.applyToTitle(acc) }

        val processedContent = rules
            .filter { it.scopeContent }
            .fold(content) { acc, rule -> rule.applyToContent(acc) }

        return processedTitle to processedContent
    }
}
