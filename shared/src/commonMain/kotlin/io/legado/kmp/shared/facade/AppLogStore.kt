package io.legado.kmp.shared.facade

import io.legado.kmp.shared.util.currentTimeMillis
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

data class AppLogEntry(
    val timestamp: Long,
    val level: String,
    val tag: String,
    val message: String,
)

object AppLogStore {
    private const val MAX_ENTRIES = 500
    private val mutableEntries = MutableStateFlow<List<AppLogEntry>>(emptyList())
    val entries: StateFlow<List<AppLogEntry>> = mutableEntries.asStateFlow()

    fun record(level: String = "I", tag: String = "App", message: String) {
        val trimmed = message.take(8_000)
        val entry = AppLogEntry(
            timestamp = currentTimeMillis(),
            level = level.take(1).ifBlank { "I" },
            tag = tag.ifBlank { "App" }.take(64),
            message = trimmed,
        )
        mutableEntries.value = (mutableEntries.value + entry).takeLast(MAX_ENTRIES)
    }

    fun clear() {
        mutableEntries.value = emptyList()
    }
}
