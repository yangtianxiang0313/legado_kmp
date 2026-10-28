package io.legado.kmp.shared.migration

import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.model.Bookmark
import io.legado.kmp.shared.model.RssSource
import io.legado.kmp.shared.model.ReplaceRule

/**
 * Result of a data migration operation
 */
data class MigrationResult(
    val success: Boolean,
    val migratedBooks: Int = 0,
    val migratedChapters: Int = 0,
    val migratedBookSources: Int = 0,
    val migratedBookmarks: Int = 0,
    val migratedRssSources: Int = 0,
    val migratedRssArticles: Int = 0,
    val migratedRssStars: Int = 0,
    val migratedRssReadRecords: Int = 0,
    val migratedSearchBooks: Int = 0,
    val migratedReplaceRules: Int = 0,
    val migratedSupplementalData: Int = 0,
    val errors: List<MigrationError> = emptyList()
) {
    val totalMigrated: Int
        get() = migratedBooks + migratedChapters + migratedBookSources +
                migratedBookmarks + migratedRssSources + migratedRssArticles +
                migratedRssStars + migratedRssReadRecords + migratedSearchBooks +
                migratedReplaceRules + migratedSupplementalData

    val hasErrors: Boolean
        get() = errors.isNotEmpty()
}

/**
 * Represents an error during migration
 */
data class MigrationError(
    val entity: String,
    val id: String,
    val message: String,
    val cause: Throwable? = null
)

/**
 * Progress callback for migration operations
 */
fun interface MigrationProgress {
    /**
     * Called when migration progress updates
     *
     * @param current Current number of items processed
     * @param total Total number of items to process
     * @param entity Name of the entity being migrated
     */
    suspend fun onProgress(current: Int, total: Int, entity: String)
}

/**
 * No-op progress callback
 */
object NoOpMigrationProgress : MigrationProgress {
    override suspend fun onProgress(current: Int, total: Int, entity: String) {
        // Do nothing
    }
}

/**
 * Interface for data migration from legacy Room database to SQLDelight
 */
interface DataMigration {

    /**
     * Check if migration is needed
     *
     * @return True if migration should be performed
     */
    suspend fun needsMigration(): Boolean

    /**
     * Get the version of the legacy database
     *
     * @return Database version, or null if not available
     */
    suspend fun getLegacyVersion(): Int?

    /**
     * Perform full migration from legacy database to SQLDelight
     *
     * @param progress Optional progress callback
     * @return Migration result with statistics
     */
    suspend fun migrateAll(
        progress: MigrationProgress = NoOpMigrationProgress
    ): MigrationResult

    /**
     * Migrate books only
     *
     * @param progress Optional progress callback
     * @return Number of books migrated
     */
    suspend fun migrateBooks(
        progress: MigrationProgress = NoOpMigrationProgress
    ): Int

    /**
     * Migrate book chapters only
     *
     * @param progress Optional progress callback
     * @return Number of chapters migrated
     */
    suspend fun migrateChapters(
        progress: MigrationProgress = NoOpMigrationProgress
    ): Int

    /**
     * Migrate book sources only
     *
     * @param progress Optional progress callback
     * @return Number of book sources migrated
     */
    suspend fun migrateBookSources(
        progress: MigrationProgress = NoOpMigrationProgress
    ): Int

    /**
     * Migrate bookmarks only
     *
     * @param progress Optional progress callback
     * @return Number of bookmarks migrated
     */
    suspend fun migrateBookmarks(
        progress: MigrationProgress = NoOpMigrationProgress
    ): Int

    /**
     * Migrate RSS sources only
     *
     * @param progress Optional progress callback
     * @return Number of RSS sources migrated
     */
    suspend fun migrateRssSources(
        progress: MigrationProgress = NoOpMigrationProgress
    ): Int

    /**
     * Migrate replace rules only
     *
     * @param progress Optional progress callback
     * @return Number of replace rules migrated
     */
    suspend fun migrateReplaceRules(
        progress: MigrationProgress = NoOpMigrationProgress
    ): Int

    /**
     * Mark migration as completed
     * This should be called after successful migration
     */
    suspend fun markMigrationCompleted()

    /**
     * Clear legacy database after successful migration
     *
     * @return True if cleared successfully
     */
    suspend fun clearLegacyDatabase(): Boolean

    /**
     * Get estimated migration counts without actually migrating
     *
     * @return Map of entity name to count
     */
    suspend fun estimateMigrationCounts(): Map<String, Int>
}

/**
 * Migration configuration
 */
data class MigrationConfig(
    val enableMigration: Boolean = true,
    val clearLegacyAfterMigration: Boolean = false,
    val batchSize: Int = 100,
    val retryFailedMigrations: Boolean = true,
    val maxRetries: Int = 3
)

/**
 * Platform-specific data migration factory
 */
expect object DataMigrationFactory {
    /**
     * Create a data migration instance for the current platform
     *
     * @param config Migration configuration
     * @return Data migration instance, or null if not supported on this platform
     */
    suspend fun create(config: MigrationConfig = MigrationConfig()): DataMigration?
}
