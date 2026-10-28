package io.legado.kmp.shared.data.database

import app.cash.sqldelight.db.SqlDriver

/**
 * Factory interface for creating platform-specific SQLDelight drivers
 */
expect class DriverFactory {
    /**
     * Create a SQLDriver for the given database name
     */
    fun createDriver(name: String): SqlDriver
}
