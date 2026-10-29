package io.legado.kmp.shared.scripting

import io.legado.kmp.shared.model.BookSource
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * Retains static snapshot text only, never realms, execution results or login state.
 * The budget counts key strings and code as UTF-16, excluding object overhead.
 */
internal class LegacySourceSnapshotCache {
    // Published snapshots are immutable; state and epoch use reference equality.
    private val cache = MutableStateFlow(CacheState())

    fun code(source: BookSource?): String {
        if (source == null) return buildSourceSnapshotCode(null)

        val epoch = cache.value.epoch
        val key = Key(source)
        val keyBytes = key.textBytes()
        if (keyBytes <= MAX_TOTAL_BYTES) {
            lookup(key, epoch)?.let { return it }
        }

        // Serialize captured values, not a second read of potentially mutable input.
        val code = buildSourceSnapshotCode(key.toSource())
        val retainedBytes = keyBytes + code.length.toLong() * 2L
        if (retainedBytes <= MAX_TOTAL_BYTES) {
            retain(Entry(key, code, retainedBytes), epoch)
        }
        return code
    }

    /** Old calls may finish, but cannot publish into the new epoch. */
    fun clear() {
        cache.value = CacheState()
    }

    private fun lookup(key: Key, epoch: Any): String? {
        while (true) {
            val previous = cache.value
            if (previous.epoch !== epoch) return null
            val index = previous.entries.indexOfFirst { it.key == key }
            if (index < 0) return null
            val entry = previous.entries[index]
            if (index == previous.entries.lastIndex) return entry.code
            val entries = previous.entries.toMutableList().apply {
                removeAt(index)
                add(entry)
            }
            val next = CacheState(epoch, entries, previous.retainedBytes)
            if (cache.compareAndSet(previous, next)) return entry.code
        }
    }

    private fun retain(entry: Entry, epoch: Any) {
        while (true) {
            val previous = cache.value
            if (previous.epoch !== epoch) return
            // Concurrent misses may serialize independently; keep the first publication.
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

    // Keep these fields in sync with buildSourceSnapshotCode, not BookSource.equals.
    private data class Key(
        val bookSourceUrl: String,
        val bookSourceName: String,
        val bookSourceGroup: String?,
        val bookSourceType: Int,
        val bookUrlPattern: String?,
        val bookSourceComment: String?,
        val header: String?,
        val loginUrl: String?,
        val loginUi: String?,
        val loginCheckJs: String?,
        val coverDecodeJs: String?,
        val variableComment: String?,
        val enabledCookieJar: Boolean,
        val concurrentRate: String?,
        val enabled: Boolean,
        val enabledExplore: Boolean,
        val customOrder: Int,
        val lastUpdateTime: Long,
        val respondTime: Long,
        val weight: Int,
        val exploreUrl: String?,
        val exploreScreen: String?,
    ) {
        constructor(source: BookSource) : this(
            bookSourceUrl = source.bookSourceUrl,
            bookSourceName = source.bookSourceName,
            bookSourceGroup = source.bookSourceGroup,
            bookSourceType = source.bookSourceType,
            bookUrlPattern = source.bookUrlPattern,
            bookSourceComment = source.bookSourceComment,
            header = source.header,
            loginUrl = source.loginUrl,
            loginUi = source.loginUi,
            loginCheckJs = source.loginCheckJs,
            coverDecodeJs = source.coverDecodeJs,
            variableComment = source.variableComment,
            enabledCookieJar = source.enabledCookieJar,
            concurrentRate = source.concurrentRate,
            enabled = source.enabled,
            enabledExplore = source.enabledExplore,
            customOrder = source.customOrder,
            lastUpdateTime = source.lastUpdateTime,
            respondTime = source.respondTime,
            weight = source.weight,
            exploreUrl = source.exploreUrl,
            exploreScreen = source.exploreScreen,
        )

        fun textBytes(): Long = (
            bookSourceUrl.length.toLong() +
                bookSourceName.length +
                (bookSourceGroup?.length ?: 0) +
                (bookUrlPattern?.length ?: 0) +
                (bookSourceComment?.length ?: 0) +
                (header?.length ?: 0) +
                (loginUrl?.length ?: 0) +
                (loginUi?.length ?: 0) +
                (loginCheckJs?.length ?: 0) +
                (coverDecodeJs?.length ?: 0) +
                (variableComment?.length ?: 0) +
                (concurrentRate?.length ?: 0) +
                (exploreUrl?.length ?: 0) +
                (exploreScreen?.length ?: 0)
            ) * 2L

        fun toSource(): BookSource = BookSource(
            bookSourceUrl = bookSourceUrl,
            bookSourceName = bookSourceName,
            bookSourceGroup = bookSourceGroup,
            bookSourceType = bookSourceType,
            bookUrlPattern = bookUrlPattern,
            bookSourceComment = bookSourceComment,
            header = header,
            loginUrl = loginUrl,
            loginUi = loginUi,
            loginCheckJs = loginCheckJs,
            coverDecodeJs = coverDecodeJs,
            variableComment = variableComment,
            enabledCookieJar = enabledCookieJar,
            concurrentRate = concurrentRate,
            enabled = enabled,
            enabledExplore = enabledExplore,
            customOrder = customOrder,
            lastUpdateTime = lastUpdateTime,
            respondTime = respondTime,
            weight = weight,
            exploreUrl = exploreUrl,
            exploreScreen = exploreScreen,
        )
    }

    private class Entry(val key: Key, val code: String, val retainedBytes: Long)

    // Least to most recently used; no mutable source objects are retained.
    private class CacheState(
        val epoch: Any = Any(),
        val entries: List<Entry> = emptyList(),
        val retainedBytes: Long = 0L,
    )

    private companion object {
        const val MAX_ENTRIES = 16
        const val MAX_TOTAL_BYTES = 1024L * 1024
    }
}
