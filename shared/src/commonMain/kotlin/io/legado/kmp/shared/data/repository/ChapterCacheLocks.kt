package io.legado.kmp.shared.data.repository

import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/** Directory-scoped locks shared by repository instances, retained only while leased. */
internal object ChapterCacheLocks {
    private val registryLock = Mutex()
    private val entries = mutableMapOf<String, Entry>()

    suspend fun <T> withLock(directory: String, block: suspend () -> T): T {
        val entry = registryLock.withLock {
            entries.getOrPut(directory) { Entry() }.also { it.leases += 1 }
        }
        try {
            return entry.mutex.withLock { block() }
        } finally {
            // Waiting callers own leases too; cancellation must not leak or split a lock.
            withContext(NonCancellable) {
                registryLock.withLock {
                    entry.leases -= 1
                    if (entry.leases == 0) entries.remove(directory)
                }
            }
        }
    }

    suspend fun <T> withLocks(first: String, second: String, block: suspend () -> T): T {
        if (first == second) return withLock(first, block)
        val earlier = minOf(first, second)
        val later = maxOf(first, second)
        return withLock(earlier) { withLock(later, block) }
    }

    private class Entry {
        val mutex = Mutex()
        var leases = 0
    }
}
