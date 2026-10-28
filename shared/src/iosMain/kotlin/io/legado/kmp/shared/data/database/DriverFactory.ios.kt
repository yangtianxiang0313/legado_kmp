package io.legado.kmp.shared.data.database

import app.cash.sqldelight.db.SqlDriver
import app.cash.sqldelight.driver.native.NativeSqliteDriver
import io.legado.kmp.data.database.LegadoDatabase

/**
 * iOS implementation of DriverFactory using NativeSqliteDriver
 */
actual class DriverFactory {
    actual fun createDriver(name: String): SqlDriver {
        return NativeSqliteDriver(
            schema = LegadoDatabase.Schema,
            name = name
        )
    }
}
