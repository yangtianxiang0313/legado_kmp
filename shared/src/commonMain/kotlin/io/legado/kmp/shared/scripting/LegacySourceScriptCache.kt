package io.legado.kmp.shared.scripting

import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Caches text only, never JavaScript contexts or source state. Library keys are
 * opaque identities supplied by the caller; persistent URL caching stays outside.
 */
internal class LegacySourceScriptCache {
    private enum class Pool { NORMALIZED, LIBRARY }

    private data class Key(val pool: Pool, val text: String)

    private class Pending(var users: Int = 0)

    private val mutex = Mutex()
    // Insertion order is access order because every hit moves its entry to the end.
    private val entries = LinkedHashMap<Key, String>()
    private val pending = HashMap<Key, Pending>()
    private var cachedCharacters = 0L

    suspend fun normalized(script: String): String {
        currentCoroutineContext().ensureActive()
        val trimmed = script.trim()
        return getOrLoad(Key(Pool.NORMALIZED, trimmed)) {
            normalizeLegacyJavascriptSyntax(trimmed)
        }
    }

    suspend fun library(key: String, load: suspend () -> String): String =
        getOrLoad(Key(Pool.LIBRARY, key), load)

    fun clear() {
        withState {
            entries.clear()
            cachedCharacters = 0L
            // Detached tokens can no longer publish, even if the same key reloads.
            pending.clear()
        }
    }

    fun removeLibrary(key: String) {
        val cacheKey = Key(Pool.LIBRARY, key)
        withState {
            removeEntry(cacheKey)
            pending.remove(cacheKey)
        }
    }

    private suspend fun getOrLoad(key: Key, load: suspend () -> String): String {
        val context = currentCoroutineContext()
        context.ensureActive()
        if (key.text.length > MAX_ENTRY_CHARACTERS) {
            val value = load()
            context.ensureActive()
            return value
        }

        val token = mutex.withLock {
            context.ensureActive()
            touch(key)?.let { return it }
            pending.getOrPut(key) { Pending() }.also { it.users++ }
        }

        try {
            val value = load()
            context.ensureActive()
            val characters = key.text.length.toLong() + value.length.toLong()
            if (characters > MAX_ENTRY_CHARACTERS) return value

            return mutex.withLock {
                context.ensureActive()
                if (pending[key] !== token) return@withLock value
                // Concurrent misses may compute independently; retain the first result.
                touch(key)?.let { return@withLock it }
                entries[key] = value
                cachedCharacters += characters
                trim(key.pool)
                value
            }
        } finally {
            // Cleanup must also run when the loading coroutine has been cancelled.
            withState {
                if (pending[key] === token && --token.users == 0) {
                    pending.remove(key)
                }
            }
        }
    }

    // State helpers are called only while holding mutex; none invokes user code.
    private fun touch(key: Key): String? {
        val value = entries.remove(key) ?: return null
        entries[key] = value
        return value
    }

    private fun removeEntry(key: Key) {
        val value = entries.remove(key) ?: return
        cachedCharacters -= key.text.length.toLong() + value.length.toLong()
    }

    private fun trim(pool: Pool) {
        while (entries.keys.count { it.pool == pool } > MAX_POOL_ENTRIES) {
            removeEntry(entries.keys.first { it.pool == pool })
        }
        while (cachedCharacters > MAX_TOTAL_CHARACTERS) {
            removeEntry(entries.keys.first())
        }
    }

    private fun <T> withState(block: () -> T): T = runBlocking {
        mutex.withLock { block() }
    }

    private companion object {
        const val MAX_POOL_ENTRIES = 16
        // Count keys and values conservatively, including any shared string storage.
        const val MAX_TOTAL_CHARACTERS = 2 * 1024 * 1024 / 2 // 2 MiB of UTF-16.
        const val MAX_ENTRY_CHARACTERS = 512 * 1024 / 2 // 512 KiB of UTF-16.
    }
}
