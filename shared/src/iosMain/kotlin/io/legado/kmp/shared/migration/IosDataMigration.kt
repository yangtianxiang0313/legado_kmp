package io.legado.kmp.shared.migration

/**
 * iOS-specific implementation of DataMigration
 * Since the original Legado app is Android-only, iOS doesn't need migration
 *
 * This is a no-op implementation that satisfies the expect/actual contract
 */
actual object DataMigrationFactory {
    actual suspend fun create(config: MigrationConfig): DataMigration? {
        // iOS doesn't need migration from Room
        return null
    }
}
