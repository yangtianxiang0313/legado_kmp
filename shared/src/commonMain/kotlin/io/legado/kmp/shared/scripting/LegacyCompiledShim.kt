package io.legado.kmp.shared.scripting

import com.dokar.quickjs.QuickJs
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

internal object LegacyCompiledShim {
    private const val MAX_CACHED_BYTECODE_BYTES = 8 * 1024 * 1024
    private const val SCRIPT_FILENAME = "main.js"
    // Strip only this trusted preamble's function source/line tables, not source rules or libraries.
    private val compiledSource = "\"use strip\";\n" + LEGACY_SHIM + "\nvoid 0;"

    private val compileMutex = Mutex()
    // StateFlow provides an atomic holder without platform-specific atomics or blocking clear().
    private val cache = MutableStateFlow(CacheEpoch())

    /** Install after host bindings and input globals, before any untrusted jsLib or rule. */
    suspend fun install(js: QuickJs) {
        val context = currentCoroutineContext()
        context.ensureActive()
        val bytecode = compileMutex.withLock {
            context.ensureActive()
            val epoch = cache.value
            epoch.bytecode ?: run {
                val compiled = try {
                    js.compile(compiledSource, filename = SCRIPT_FILENAME, asModule = false)
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Exception) {
                    return@withLock null
                }
                context.ensureActive()
                if (compiled.size <= MAX_CACHED_BYTECODE_BYTES) {
                    // A concurrent clear() replaces the epoch, so this publication must then fail.
                    cache.compareAndSet(epoch, CacheEpoch(compiled))
                }
                compiled
            }
        }

        context.ensureActive()
        // Compilation does not execute the shim. Never retry an evaluation that may have done so.
        if (bytecode == null) {
            js.evaluate<Any?>(compiledSource, filename = SCRIPT_FILENAME, asModule = false)
        } else {
            js.evaluate<Any?>(bytecode)
        }
    }

    /** Drop retained bytecode and prevent in-flight compilation from repopulating this epoch. */
    fun clear() {
        cache.value = CacheEpoch()
    }

    // Reference identity is the epoch token; structural equality would permit stale publication.
    private class CacheEpoch(val bytecode: ByteArray? = null)
}
