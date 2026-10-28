package io.legado.kmp.shared.image

import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/** Orders loads and explicit refreshes of the same image without serializing unrelated images. */
internal class ImageRequestGate {
    private class Entry(val lock: Mutex = Mutex(), var users: Int = 0)

    private val lock = Mutex()
    private val entries = mutableMapOf<String, Entry>()

    suspend fun <T> withKey(key: String, block: suspend () -> T): T {
        val entry = lock.withLock {
            entries.getOrPut(key) { Entry() }.also { it.users++ }
        }
        try {
            return entry.lock.withLock { block() }
        } finally {
            withContext(NonCancellable) {
                lock.withLock {
                    entry.users--
                    if (entry.users == 0) entries.remove(key)
                }
            }
        }
    }
}
