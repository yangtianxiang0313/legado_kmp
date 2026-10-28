package io.legado.kmp.shared.data.adapter

import app.cash.sqldelight.ColumnAdapter
import kotlinx.serialization.encodeToString
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.Json

/**
 * SQLDelight ColumnAdapter for List<String>
 * Stores list as JSON array string
 */
val StringListAdapter = object : ColumnAdapter<List<String>, String> {
    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = false
    }

    override fun decode(databaseValue: String): List<String> {
        return if (databaseValue.isEmpty()) {
            emptyList()
        } else {
            try {
                json.decodeFromString(databaseValue)
            } catch (e: Exception) {
                emptyList()
            }
        }
    }

    override fun encode(value: List<String>): String {
        return if (value.isEmpty()) "" else json.encodeToString(value)
    }
}

/**
 * SQLDelight ColumnAdapter for List<Int>
 */
val IntListAdapter = object : ColumnAdapter<List<Int>, String> {
    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = false
    }

    override fun decode(databaseValue: String): List<Int> {
        return if (databaseValue.isEmpty()) {
            emptyList()
        } else {
            try {
                json.decodeFromString(databaseValue)
            } catch (e: Exception) {
                emptyList()
            }
        }
    }

    override fun encode(value: List<Int>): String {
        return if (value.isEmpty()) "" else json.encodeToString(value)
    }
}
