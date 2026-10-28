package io.legado.kmp.shared.data.adapter

import app.cash.sqldelight.ColumnAdapter

/**
 * SQLDelight ColumnAdapter for Boolean type
 * Converts Boolean to INTEGER (1 for true, 0 for false)
 */
val BooleanAdapter = object : ColumnAdapter<Boolean, Long> {
    override fun decode(databaseValue: Long): Boolean = databaseValue == 1L

    override fun encode(value: Boolean): Long = if (value) 1L else 0L
}
