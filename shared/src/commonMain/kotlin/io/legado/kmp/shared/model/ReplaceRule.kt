package io.legado.kmp.shared.model

import kotlinx.serialization.Serializable

/**
 * Represents a text replacement rule
 * Used for content cleaning and text transformation
 *
 * @property id Unique identifier (primary key)
 * @property name Rule name
 * @property group Rule group for organization
 * @property pattern Pattern to match (regex or literal)
 * @property replacement Replacement string
 * @property scope Book sources this applies to
 * @property scopeTitle Apply to title
 * @property scopeContent Apply to content
 * @property excludeScope Sources to exclude
 * @property isEnabled Whether the rule is enabled
 * @property isRegex Whether pattern is regex
 * @property timeoutMillisecond Timeout for regex matching
 * @property order Sort order
 */
@Serializable
data class ReplaceRule(
    val id: Long = io.legado.kmp.shared.util.currentTimeMillis(),
    val name: String = "",
    val group: String? = null,
    val pattern: String = "",
    val replacement: String = "",
    val scope: String? = null,
    val scopeTitle: Boolean = false,
    val scopeContent: Boolean = true,
    val excludeScope: String? = null,
    val isEnabled: Boolean = true,
    val isRegex: Boolean = true,
    val timeoutMillisecond: Long = 3000L,
    val order: Int = 0
) {
    companion object {
        /**
         * Create a ReplaceRule from SQLDelight generated mapping
         */
        fun from(
            id: Long,
            name: String,
            rule_group: String?,
            pattern: String,
            replacement: String,
            scope: String?,
            scope_title: Long,
            scope_content: Long,
            exclude_scope: String?,
            is_enabled: Long,
            is_regex: Long,
            timeout_millisecond: Long,
            sort_order: Long
        ): ReplaceRule = ReplaceRule(
            id = id,
            name = name,
            group = rule_group,
            pattern = pattern,
            replacement = replacement,
            scope = scope,
            scopeTitle = scope_title == 1L,
            scopeContent = scope_content == 1L,
            excludeScope = exclude_scope,
            isEnabled = is_enabled == 1L,
            isRegex = is_regex == 1L,
            timeoutMillisecond = timeout_millisecond,
            order = sort_order.toInt()
        )
    }
}

/**
 * Extension to convert ReplaceRule to SQLDelight parameter map
 */
fun ReplaceRule.toInsertMap(): Map<String, Any?> = mapOf(
    "id" to id,
    "name" to name,
    "rule_group" to group,
    "pattern" to pattern,
    "replacement" to replacement,
    "scope" to scope,
    "scope_title" to if (scopeTitle) 1L else 0L,
    "scope_content" to if (scopeContent) 1L else 0L,
    "exclude_scope" to excludeScope,
    "is_enabled" to if (isEnabled) 1L else 0L,
    "is_regex" to if (isRegex) 1L else 0L,
    "timeout_millisecond" to timeoutMillisecond,
    "sort_order" to order.toLong()
)

/**
 * Get the compiled regex for this rule
 * Only valid if isRegex is true
 */
val ReplaceRule.regex: Regex?
    get() {
        if (!isRegex || pattern.isBlank()) return null
        return try {
            Regex(pattern)
        } catch (e: Exception) {
            null
        }
    }

/**
 * Check if this rule is valid
 */
val ReplaceRule.isValid: Boolean
    get() {
        if (pattern.isBlank()) return false
        if (isRegex) {
            if (regex == null) return false
            // Check for potentially problematic patterns
            if (pattern.endsWith('|') && !pattern.endsWith("\\|")) {
                return false
            }
        }
        return true
    }

/**
 * Get the display name with group
 */
val ReplaceRule.displayName: String
    get() = if (group.isNullOrBlank()) {
        name
    } else {
        "$name ($group)"
    }

/**
 * Get valid timeout (default to 3000ms if invalid)
 */
val ReplaceRule.validTimeout: Long
    get() = if (timeoutMillisecond <= 0) 3000L else timeoutMillisecond

/**
 * Apply this rule to a string
 */
fun ReplaceRule.applyTo(input: String): String {
    if (!isEnabled || pattern.isBlank()) return input

    return try {
        if (isRegex) {
            regex?.replace(input, replacement) ?: input
        } else {
            input.replace(pattern, replacement)
        }
    } catch (e: Exception) {
        input
    }
}

/**
 * Apply this rule to title if scopeTitle is enabled
 */
fun ReplaceRule.applyToTitle(title: String): String {
    return if (scopeTitle) applyTo(title) else title
}

/**
 * Apply this rule to content if scopeContent is enabled
 */
fun ReplaceRule.applyToContent(content: String): String {
    return if (scopeContent) applyTo(content) else content
}

/**
 * Check if this rule applies to a specific scope
 */
fun ReplaceRule.appliesToScope(sourceUrl: String?): Boolean {
    if (scope.isNullOrBlank()) return true // No scope means applies to all
    if (sourceUrl.isNullOrBlank()) return true

    // Check if source matches scope pattern
    val scopePatterns = scope.split(',').map { it.trim() }
    return scopePatterns.any { pattern ->
        sourceUrl.contains(pattern, ignoreCase = true)
    }
}

/**
 * Check if this rule is excluded for a specific scope
 */
fun ReplaceRule.isExcludedForScope(sourceUrl: String?): Boolean {
    if (excludeScope.isNullOrBlank() || sourceUrl.isNullOrBlank()) return false

    val excludePatterns = excludeScope.split(',').map { it.trim() }
    return excludePatterns.any { pattern ->
        sourceUrl.contains(pattern, ignoreCase = true)
    }
}

/**
 * Check if this rule should be applied for a given source
 */
fun ReplaceRule.shouldApply(sourceUrl: String?): Boolean {
    return isEnabled && isValid && appliesToScope(sourceUrl) && !isExcludedForScope(sourceUrl)
}

/**
 * Get scope patterns as a list
 */
val ReplaceRule.scopePatterns: List<String>
    get() = scope?.split(',')?.map { it.trim() }?.filter { it.isNotEmpty() } ?: emptyList()

/**
 * Get exclude scope patterns as a list
 */
val ReplaceRule.excludeScopePatterns: List<String>
    get() = excludeScope?.split(',')?.map { it.trim() }?.filter { it.isNotEmpty() } ?: emptyList()
