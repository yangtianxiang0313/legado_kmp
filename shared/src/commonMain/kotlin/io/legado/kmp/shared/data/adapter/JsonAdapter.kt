package io.legado.kmp.shared.data.adapter

import app.cash.sqldelight.ColumnAdapter
import kotlinx.serialization.encodeToString
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.Json

/**
 * Generic SQLDelight ColumnAdapter for serializing objects to JSON
 *
 * Usage:
 * ```kotlin
 * data class MyData(val id: String, val name: String)
 *
 * val myAdapter = JsonAdapter(MyData::class)
 * ```
 *
 * Note: For nullable types, handle null in the model layer instead of using adapters.
 */
inline fun <reified T : Any> JsonAdapter() = object : ColumnAdapter<T, String> {
    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = false
    }

    override fun decode(databaseValue: String): T =
        json.decodeFromString(databaseValue)

    override fun encode(value: T): String =
        json.encodeToString(value)
}

/**
 * Helper function to encode any object to JSON string
 */
fun encodeToJson(value: Any): String {
    return Json {
        ignoreUnknownKeys = true
        isLenient = true
        encodeDefaults = false
    }.encodeToString(value)
}

/**
 * Helper function to decode JSON string to specific type
 */
inline fun <reified T : Any> decodeFromJson(jsonString: String): T? {
    return try {
        Json {
            ignoreUnknownKeys = true
            isLenient = true
        }.decodeFromString(jsonString)
    } catch (e: Exception) {
        null
    }
}
