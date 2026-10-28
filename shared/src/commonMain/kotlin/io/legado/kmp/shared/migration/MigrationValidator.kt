package io.legado.kmp.shared.migration

import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.Bookmark
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.model.ReplaceRule
import io.legado.kmp.shared.model.RssSource

/**
 * Validation result for migrated data
 */
data class ValidationResult(
    val valid: Boolean,
    val entityCount: Int,
    val invalidEntities: List<InvalidEntity> = emptyList(),
    val warnings: List<String> = emptyList()
)

/**
 * Represents an invalid entity found during validation
 */
data class InvalidEntity(
    val entityType: String,
    val entityId: String,
    val issues: List<String>
)

/**
 * Utilities for validating migrated data
 */
object MigrationValidator {

    /**
     * Validate a list of books after migration
     *
     * @param books List of books to validate
     * @return Validation result
     */
    fun validateBooks(books: List<Book>): ValidationResult {
        val invalid = mutableListOf<InvalidEntity>()
        val warnings = mutableListOf<String>()

        books.forEach { book ->
            val issues = mutableListOf<String>()

            if (book.bookUrl.isBlank()) {
                issues.add("bookUrl is blank")
            }
            if (book.name.isBlank()) {
                issues.add("name is blank")
            }
            if (book.author.isBlank()) {
                issues.add("author is blank")
            }
            if (book.origin.isBlank() && book.bookUrl.startsWith("http")) {
                warnings.add("Book '${book.name}' has no origin but has http bookUrl")
            }

            if (issues.isNotEmpty()) {
                invalid.add(InvalidEntity("Book", book.bookUrl, issues))
            }
        }

        return ValidationResult(
            valid = invalid.isEmpty(),
            entityCount = books.size,
            invalidEntities = invalid,
            warnings = warnings
        )
    }

    /**
     * Validate a list of bookmarks after migration
     *
     * @param bookmarks List of bookmarks to validate
     * @return Validation result
     */
    fun validateBookmarks(bookmarks: List<Bookmark>): ValidationResult {
        val invalid = mutableListOf<InvalidEntity>()

        bookmarks.forEach { bookmark ->
            val issues = mutableListOf<String>()

            if (bookmark.bookName.isBlank()) {
                issues.add("bookName is blank")
            }
            if (bookmark.chapterIndex < 0) {
                issues.add("chapterIndex is negative")
            }
            if (bookmark.chapterPos < 0) {
                issues.add("chapterPos is negative")
            }

            if (issues.isNotEmpty()) {
                invalid.add(InvalidEntity("Bookmark", bookmark.time.toString(), issues))
            }
        }

        return ValidationResult(
            valid = invalid.isEmpty(),
            entityCount = bookmarks.size,
            invalidEntities = invalid
        )
    }

    /**
     * Validate a list of book sources after migration
     *
     * @param sources List of book sources to validate
     * @return Validation result
     */
    fun validateBookSources(sources: List<BookSource>): ValidationResult {
        val invalid = mutableListOf<InvalidEntity>()

        sources.forEach { source ->
            val issues = mutableListOf<String>()

            if (source.bookSourceUrl.isBlank()) {
                issues.add("bookSourceUrl is blank")
            }
            if (source.bookSourceName.isBlank()) {
                issues.add("bookSourceName is blank")
            }

            if (issues.isNotEmpty()) {
                invalid.add(InvalidEntity("BookSource", source.bookSourceUrl, issues))
            }
        }

        return ValidationResult(
            valid = invalid.isEmpty(),
            entityCount = sources.size,
            invalidEntities = invalid
        )
    }

    /**
     * Validate a list of RSS sources after migration
     *
     * @param sources List of RSS sources to validate
     * @return Validation result
     */
    fun validateRssSources(sources: List<RssSource>): ValidationResult {
        val invalid = mutableListOf<InvalidEntity>()

        sources.forEach { source ->
            val issues = mutableListOf<String>()

            if (source.sourceUrl.isBlank()) {
                issues.add("sourceUrl is blank")
            }
            if (source.sourceName.isBlank()) {
                issues.add("sourceName is blank")
            }

            if (issues.isNotEmpty()) {
                invalid.add(InvalidEntity("RssSource", source.sourceUrl, issues))
            }
        }

        return ValidationResult(
            valid = invalid.isEmpty(),
            entityCount = sources.size,
            invalidEntities = invalid
        )
    }

    /**
     * Validate a list of replace rules after migration
     *
     * @param rules List of replace rules to validate
     * @return Validation result
     */
    fun validateReplaceRules(rules: List<ReplaceRule>): ValidationResult {
        val invalid = mutableListOf<InvalidEntity>()

        rules.forEach { rule ->
            val issues = mutableListOf<String>()

            if (rule.pattern.isBlank()) {
                issues.add("pattern is blank")
            }
            if (rule.isRegex) {
                try {
                    Regex(rule.pattern)
                } catch (e: Exception) {
                    issues.add("Invalid regex: ${e.message}")
                }
            }

            if (issues.isNotEmpty()) {
                invalid.add(InvalidEntity("ReplaceRule", rule.id.toString(), issues))
            }
        }

        return ValidationResult(
            valid = invalid.isEmpty(),
            entityCount = rules.size,
            invalidEntities = invalid
        )
    }

    /**
     * Generate a validation report from migration results
     *
     * @param results Map of entity type to validation results
     * @return Formatted report string
     */
    fun generateReport(results: Map<String, ValidationResult>): String {
        val report = StringBuilder()
        report.appendLine("=== Migration Validation Report ===")
        report.appendLine()

        var totalValid = 0
        var totalInvalid = 0
        var totalWarnings = 0

        results.forEach { (entity, result) ->
            report.appendLine("[$entity]")
            report.appendLine("  Total: ${result.entityCount}")
            report.appendLine("  Valid: ${result.entityCount - result.invalidEntities.size}")
            report.appendLine("  Invalid: ${result.invalidEntities.size}")
            report.appendLine("  Warnings: ${result.warnings.size}")

            if (result.invalidEntities.isNotEmpty()) {
                report.appendLine("  Invalid Entities:")
                result.invalidEntities.take(5).forEach { invalid ->
                    report.appendLine("    - ${invalid.entityType}::${invalid.entityId}")
                    invalid.issues.forEach { issue ->
                        report.appendLine("      • $issue")
                    }
                }
                if (result.invalidEntities.size > 5) {
                    report.appendLine("    ... and ${result.invalidEntities.size - 5} more")
                }
            }

            if (result.warnings.isNotEmpty()) {
                result.warnings.take(3).forEach { warning ->
                    report.appendLine("  ⚠ Warning: $warning")
                }
                if (result.warnings.size > 3) {
                    report.appendLine("  ... and ${result.warnings.size - 3} more warnings")
                }
            }

            report.appendLine()

            totalValid += result.entityCount - result.invalidEntities.size
            totalInvalid += result.invalidEntities.size
            totalWarnings += result.warnings.size
        }

        report.appendLine("--- Summary ---")
        report.appendLine("Total Entities: ${results.values.sumOf { it.entityCount }}")
        report.appendLine("Valid: $totalValid")
        report.appendLine("Invalid: $totalInvalid")
        report.appendLine("Warnings: $totalWarnings")

        val overallValid = totalInvalid == 0
        report.appendLine()
        report.appendLine("Overall Status: ${if (overallValid) "✓ PASSED" else "✗ FAILED"}")

        return report.toString()
    }
}

/**
 * Extension to check if validation passed
 */
val ValidationResult.isPassed: Boolean
    get() = valid && invalidEntities.isEmpty()

/**
 * Extension to get success rate as percentage
 */
val ValidationResult.successRate: Float
    get() = if (entityCount > 0) {
        (entityCount - invalidEntities.size).toFloat() / entityCount * 100
    } else {
        100f
    }
