package io.legado.kmp.shared.data.adapter

import app.cash.sqldelight.ColumnAdapter
import io.legado.kmp.shared.model.ReadConfig

/**
 * SQLDelight adapter for Book entity
 * Contains column adapters for custom types
 */
object BookAdapter {
    /**
     * Adapter for boolean columns (stored as INTEGER)
     */
    val booleanAdapter = BooleanAdapter

    /**
     * Adapter for ReadConfig (stored as JSON string)
     */
    val readConfigAdapter = object : ColumnAdapter<ReadConfig, String> {
        override fun decode(databaseValue: String): ReadConfig {
            return ReadConfig.fromJson(databaseValue)
        }

        override fun encode(value: ReadConfig): String {
            return value.toJson()
        }
    }
}
