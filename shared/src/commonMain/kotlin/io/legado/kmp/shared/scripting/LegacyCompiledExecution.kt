package io.legado.kmp.shared.scripting

import com.dokar.quickjs.QuickJs
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlin.coroutines.CoroutineContext

/**
 * Process-local cache of bytecode compiled from the exact, complete execution text
 * produced by buildLegacyJsDomExecution (jsLib and rule together, not separately).
 * Keep one cache across calls, but supply a fresh caller-owned realm each time,
 * with host bindings, input globals and the shim already installed. This class
 * never retains/closes realms, executes libraries ahead of rules, or caches results.
 *
 * Only QuickJs.compile output created here is accepted; bytecode is private and
 * never persisted. No wrappers, appended statements or module conversion alter
 * global eval semantics or the completion value. Compilation/evaluation failures,
 * including cancellation, propagate without replaying evaluation as source text.
 *
 * Limits cover retained payload (both key strings at two bytes per character plus
 * bytecode), not object overhead or transient compilation/evaluation allocations.
 */
internal class LegacyCompiledExecution {
    // Published snapshots are never mutated. Epoch and state use reference equality.
    private val cache = MutableStateFlow(CacheState())

    /**
     * Evaluate once in [js]; [libraryKey] is the caller's opaque jsLib identity,
     * using the same value for [removeLibrary]. The entire unmodified [execution]
     * is also part of the key, so a changed library body or rule cannot hit old code.
     * Calls on different realms may compile concurrently; no cache lock covers JS.
     */
    suspend fun evaluate(js: QuickJs, execution: String, libraryKey: String): Any? {
        val context = currentCoroutineContext()
        context.ensureActive()
        val key = Key(libraryKey, execution)
        val keyBytes = (libraryKey.length.toLong() + execution.length.toLong()) * 2L
        val bytecode = if (keyBytes > MAX_ENTRY_BYTES) {
            // Large keys bypass compilation caching without retaining their text.
            null
        } else {
            val lookup = lookup(key, context)
            lookup.bytecode ?: run {
                context.ensureActive()
                val compiled = js.compile(execution, filename = SCRIPT_FILENAME, asModule = false)
                // compile is synchronous: observe cancellation before publication or execution.
                context.ensureActive()
                retain(Entry(key, compiled, keyBytes + compiled.size.toLong()), lookup.epoch, context)
                compiled
            }
        }

        context.ensureActive()
        // Never catch an evaluation failure to retry: library/host side effects may exist.
        val result = if (bytecode == null) {
            js.evaluate<Any?>(execution, filename = SCRIPT_FILENAME, asModule = false)
        } else {
            js.evaluate<Any?>(bytecode)
        }
        context.ensureActive()
        return result
    }

    /** Drop all retained code and prevent earlier cache misses from repopulating it. */
    fun clear() {
        cache.value = CacheState()
    }

    /**
     * Drop this library's entries, including publications from earlier cache misses.
     * A new global epoch also discards unrelated in-flight publications, but keeps
     * unrelated resident entries; no unbounded per-library tombstones are retained.
     * Invalidation does not cancel calls or revoke bytecode already acquired by them.
     */
    fun removeLibrary(key: String) {
        while (true) {
            val previous = cache.value
            val entries = previous.entries.filterNot { it.key.libraryKey == key }
            val next = CacheState(entries = entries, retainedBytes = entries.sumOf { it.retainedBytes })
            if (cache.compareAndSet(previous, next)) return
        }
    }

    private fun lookup(key: Key, context: CoroutineContext): Lookup {
        while (true) {
            context.ensureActive()
            val previous = cache.value
            val index = previous.entries.indexOfFirst { it.key == key }
            if (index < 0) return Lookup(previous.epoch, null)
            val entry = previous.entries[index]
            if (index == previous.entries.lastIndex) return Lookup(previous.epoch, entry.bytecode)
            val entries = previous.entries.toMutableList().apply {
                removeAt(index)
                add(entry)
            }
            val next = CacheState(previous.epoch, entries, previous.retainedBytes)
            if (cache.compareAndSet(previous, next)) return Lookup(previous.epoch, entry.bytecode)
        }
    }

    private fun retain(entry: Entry, epoch: Any, context: CoroutineContext) {
        if (entry.retainedBytes > MAX_ENTRY_BYTES) return
        while (true) {
            context.ensureActive()
            val previous = cache.value
            if (previous.epoch !== epoch) return
            // Concurrent misses compile independently; retain only the first publication.
            if (previous.entries.any { it.key == entry.key }) return
            val entries = previous.entries.toMutableList()
            var retainedBytes = previous.retainedBytes + entry.retainedBytes
            while (entries.size >= MAX_ENTRIES || retainedBytes > MAX_TOTAL_BYTES) {
                retainedBytes -= entries.removeAt(0).retainedBytes
            }
            entries.add(entry)
            val next = CacheState(epoch, entries, retainedBytes)
            if (cache.compareAndSet(previous, next)) return
        }
    }

    private data class Key(val libraryKey: String, val execution: String)

    private class Entry(val key: Key, val bytecode: ByteArray, val retainedBytes: Long)

    private class Lookup(val epoch: Any, val bytecode: ByteArray?)

    // Entries are ordered least to most recently used, with identity-based epoch tokens.
    private class CacheState(
        val epoch: Any = Any(),
        val entries: List<Entry> = emptyList(),
        val retainedBytes: Long = 0L,
    )

    private companion object {
        const val MAX_ENTRIES = 16
        const val MAX_TOTAL_BYTES = 2L * 1024 * 1024
        const val MAX_ENTRY_BYTES = 512L * 1024
        const val SCRIPT_FILENAME = "main.js"
    }
}
