package io.legado.kmp.shared.data.adapter

import app.cash.sqldelight.ColumnAdapter
import kotlinx.datetime.Instant

/**
 * SQLDelight ColumnAdapter for Instant type
 * Converts Instant to epoch milliseconds
 */
val InstantAdapter = object : ColumnAdapter<Instant, Long> {
    override fun decode(databaseValue: Long): Instant =
        Instant.fromEpochMilliseconds(databaseValue)

    override fun encode(value: Instant): Long = value.toEpochMilliseconds()
}
