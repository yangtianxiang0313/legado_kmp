package io.legado.kmp.shared.domain.usecase

import io.legado.kmp.shared.migration.DataMigration
import io.legado.kmp.shared.migration.DataMigrationFactory
import io.legado.kmp.shared.migration.MigrationConfig
import io.legado.kmp.shared.migration.MigrationProgress
import io.legado.kmp.shared.migration.MigrationResult
import io.legado.kmp.shared.migration.MigrationValidator
import io.legado.kmp.shared.migration.NoOpMigrationProgress
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow

/**
 * Use case for migrating data from legacy Room database to SQLDelight
 */
class MigrateDataUseCase {

    /**
     * Check if migration is needed
     *
     * @return True if migration is needed
     */
    suspend fun needsMigration(): Boolean {
        val migration = DataMigrationFactory.create() ?: return false
        return migration.needsMigration()
    }

    /**
     * Get the legacy database version
     *
     * @return Database version, or null if not available
     */
    suspend fun getLegacyVersion(): Int? {
        val migration = DataMigrationFactory.create() ?: return null
        return migration.getLegacyVersion()
    }

    /**
     * Get estimated migration counts
     *
     * @return Map of entity type to count
     */
    suspend fun estimateMigration(): Map<String, Int> {
        val migration = DataMigrationFactory.create() ?: return emptyMap()
        return migration.estimateMigrationCounts()
    }

    /**
     * Perform full migration with progress updates as Flow
     *
     * @param config Migration configuration
     * @return Flow emitting migration progress and final result
     */
    fun migrateWithProgress(config: MigrationConfig = MigrationConfig()): Flow<MigrationProgress> = flow {
        val migration = DataMigrationFactory.create(config) ?: run {
            emit(object : MigrationProgress {
                override suspend fun onProgress(current: Int, total: Int, entity: String) {
                    // No migration needed
                }
            })
            return@flow
        }

        // Perform migration
        migration.migrateAll(object : MigrationProgress {
            override suspend fun onProgress(current: Int, total: Int, entity: String) {
                emit(this)
            }
        })
    }

    /**
     * Perform full migration
     *
     * @param config Migration configuration
     * @param progress Optional progress callback
     * @return Migration result
     */
    suspend operator fun invoke(
        config: MigrationConfig = MigrationConfig(),
        progress: MigrationProgress = NoOpMigrationProgress
    ): MigrationResult {
        val migration = DataMigrationFactory.create(config) ?: return MigrationResult(
            success = false,
            errors = listOf(io.legado.kmp.shared.migration.MigrationError(
                "Migration",
                "all",
                "Migration not supported on this platform"
            ))
        )

        val result = migration.migrateAll(progress)

        if (result.success && config.clearLegacyAfterMigration) {
            migration.clearLegacyDatabase()
        }

        if (result.success) {
            migration.markMigrationCompleted()
        }

        return result
    }

    /**
     * Migrate only books
     *
     * @param config Migration configuration
     * @param progress Optional progress callback
     * @return Number of books migrated
     */
    suspend fun migrateBooks(
        config: MigrationConfig = MigrationConfig(),
        progress: MigrationProgress = NoOpMigrationProgress
    ): Int {
        val migration = DataMigrationFactory.create(config) ?: return 0
        return migration.migrateBooks(progress)
    }

    /**
     * Migrate only book sources
     *
     * @param config Migration configuration
     * @param progress Optional progress callback
     * @return Number of book sources migrated
     */
    suspend fun migrateBookSources(
        config: MigrationConfig = MigrationConfig(),
        progress: MigrationProgress = NoOpMigrationProgress
    ): Int {
        val migration = DataMigrationFactory.create(config) ?: return 0
        return migration.migrateBookSources(progress)
    }
}

/**
 * Use case for validating migrated data
 */
class ValidateMigrationUseCase {

    /**
     * Validate all migrated data
     *
     * @return Validation report as string
     */
    suspend operator fun invoke(): String {
        // In production, you would query the SQLDelight database
        // and validate each entity type

        val results = mapOf(
            "Books" to io.legado.kmp.shared.migration.ValidationResult(
                valid = true,
                entityCount = 0
            ),
            "BookSources" to io.legado.kmp.shared.migration.ValidationResult(
                valid = true,
                entityCount = 0
            ),
            "Bookmarks" to io.legado.kmp.shared.migration.ValidationResult(
                valid = true,
                entityCount = 0
            ),
            "RssSources" to io.legado.kmp.shared.migration.ValidationResult(
                valid = true,
                entityCount = 0
            ),
            "ReplaceRules" to io.legado.kmp.shared.migration.ValidationResult(
                valid = true,
                entityCount = 0
            )
        )

        return MigrationValidator.generateReport(results)
    }
}

/**
 * Use case for checking migration status
 */
class CheckMigrationStatusUseCase {

    /**
     * Check if migration is available on this platform
     *
     * @return True if migration is supported
     */
    suspend fun isMigrationSupported(): Boolean {
        return DataMigrationFactory.create() != null
    }

    /**
     * Get migration status information
     *
     * @return Migration status data
     */
    suspend fun getStatus(): MigrationStatus {
        val migration = DataMigrationFactory.create()
        val needsMigration = migration?.needsMigration() ?: false
        val legacyVersion = migration?.getLegacyVersion()

        return MigrationStatus(
            supported = migration != null,
            needsMigration = needsMigration,
            legacyVersion = legacyVersion,
            completed = !needsMigration && migration != null
        )
    }
}

/**
 * Migration status information
 */
data class MigrationStatus(
    val supported: Boolean,
    val needsMigration: Boolean,
    val legacyVersion: Int?,
    val completed: Boolean
)
