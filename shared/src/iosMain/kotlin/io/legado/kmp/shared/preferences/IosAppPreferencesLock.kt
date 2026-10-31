package io.legado.kmp.shared.preferences

import platform.Foundation.NSRecursiveLock

/** Shared by all stores; native defaults writes and system notifications are outside this lock. */
internal object IosAppPreferencesLock {
    private val lock = NSRecursiveLock()

    // Non-inline and non-suspending: the callback completes on the thread owning the lock.
    fun <T> withLock(action: () -> T): T {
        lock.lock()
        return try {
            action()
        } finally {
            lock.unlock()
        }
    }
}
