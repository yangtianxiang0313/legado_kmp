package io.legado.kmp.shared.image

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Pure-Kotlin LRU cache for image byte data.
 *
 * Mirrors legado ImageProvider.BitmapLruCache semantics:
 * - Size tracking based on byte count of cached values
 * - Evicts least-recently-used entries when over capacity
 * - Thread-safe via coroutine Mutex
 *
 * Uses a doubly-linked list + HashMap for O(1) LRU operations,
 * since LinkedHashMap(accessOrder=true) is JVM-only.
 *
 * @param maxSizeBytes Maximum cache size in bytes. Default 50 MB (matching legado AppConfig.bitmapCacheSize default).
 */
class ImageLruCache(private var maxSizeBytes: Long = DEFAULT_MAX_SIZE_BYTES) {

    companion object {
        private const val MB = 1024L * 1024L
        const val DEFAULT_MAX_SIZE_BYTES: Long = 50 * MB
        private const val MAX_ALLOWED_SIZE_BYTES: Long = 256 * MB
    }

    private class Node(
        val key: String,
        var value: ByteArray,
        var prev: Node? = null,
        var next: Node? = null,
    )

    private val mutex = Mutex()
    private val map = HashMap<String, Node>()
    // Sentinel nodes for doubly-linked list
    private val head = Node("", ByteArray(0)) // dummy head (MRU end)
    private val tail = Node("", ByteArray(0)) // dummy tail (LRU end)
    private var currentSizeBytes: Long = 0L

    init {
        head.next = tail
        tail.prev = head
    }

    val size: Long get() = currentSizeBytes

    val maxSize: Long get() = maxSizeBytes

    val entryCount: Int get() = map.size

    /**
     * Retrieve cached image data by key (suspend, thread-safe).
     * Moves the accessed entry to MRU position.
     * Returns null if key is absent.
     */
    suspend fun get(key: String): ByteArray? {
        mutex.withLock {
            val node = map[key] ?: return null
            moveToHead(node)
            return node.value
        }
    }

    /**
     * Non-suspend get for contexts where suspension is not possible.
     * Not thread-safe; use only when single-thread access is guaranteed.
     */
    fun getSync(key: String): ByteArray? {
        val node = map[key] ?: return null
        moveToHead(node)
        return node.value
    }

    /**
     * Insert or update a cache entry.
     * Auto-resizes cache if a single entry exceeds current max, up to [MAX_ALLOWED_SIZE_BYTES].
     * Evicts LRU entries as needed to stay within capacity.
     */
    suspend fun put(key: String, value: ByteArray) {
        mutex.withLock {
            val entrySize = value.size.toLong()
            ensureCapacity(entrySize)

            val existing = map[key]
            if (existing != null) {
                currentSizeBytes -= existing.value.size.toLong()
                existing.value = value
                currentSizeBytes += entrySize
                moveToHead(existing)
            } else {
                val node = Node(key, value)
                map[key] = node
                addToHead(node)
                currentSizeBytes += entrySize
            }
            trimToSize(maxSizeBytes)
        }
    }

    /**
     * Remove a specific entry.
     */
    suspend fun remove(key: String): ByteArray? {
        mutex.withLock {
            val node = map.remove(key) ?: return null
            removeNode(node)
            currentSizeBytes -= node.value.size.toLong()
            return node.value
        }
    }

    /**
     * Evict all entries.
     */
    suspend fun evictAll() {
        mutex.withLock {
            evictAllInternal()
        }
    }

    /**
     * Non-suspend evictAll for cleanup / shutdown contexts.
     */
    fun evictAllSync() {
        evictAllInternal()
    }

    private fun evictAllInternal() {
        map.clear()
        head.next = tail
        tail.prev = head
        currentSizeBytes = 0L
    }

    /**
     * Resize the cache max size.
     */
    suspend fun resize(newMaxSizeBytes: Long) {
        require(newMaxSizeBytes > 0) { "maxSizeBytes must be > 0" }
        mutex.withLock {
            maxSizeBytes = newMaxSizeBytes
            trimToSize(newMaxSizeBytes)
        }
    }

    /**
     * Check if the cache contains a key.
     */
    fun containsKey(key: String): Boolean = map.containsKey(key)

    // ==================== Linked list operations ====================

    /** Add node right after head (MRU position). */
    private fun addToHead(node: Node) {
        node.prev = head
        node.next = head.next
        head.next?.prev = node
        head.next = node
    }

    /** Remove node from its current position in the list. */
    private fun removeNode(node: Node) {
        node.prev?.next = node.next
        node.next?.prev = node.prev
        node.prev = null
        node.next = null
    }

    /** Move existing node to MRU position. */
    private fun moveToHead(node: Node) {
        removeNode(node)
        addToHead(node)
    }

    /** Remove and return the LRU node (just before tail). Null if list is empty. */
    private fun removeTail(): Node? {
        val lru = tail.prev
        if (lru === head) return null
        lru?.let { removeNode(it) }
        return lru
    }

    // ==================== Capacity management ====================

    /**
     * Mirrors legado ensureLruCacheSize: auto-expand when a single image
     * is larger than the current max, or when few items exist and space is tight.
     */
    private fun ensureCapacity(entrySize: Long) {
        val lruMaxSize = maxSizeBytes
        if (entrySize > lruMaxSize) {
            maxSizeBytes = minOf(MAX_ALLOWED_SIZE_BYTES, (entrySize * 1.3).toLong())
        } else if (currentSizeBytes + entrySize > lruMaxSize && map.size < 5) {
            maxSizeBytes = minOf(MAX_ALLOWED_SIZE_BYTES, (currentSizeBytes + entrySize * 1.3).toLong())
        }
    }

    private fun trimToSize(maxSize: Long) {
        while (currentSizeBytes > maxSize && map.isNotEmpty()) {
            val lru = removeTail() ?: break
            map.remove(lru.key)
            currentSizeBytes -= lru.value.size.toLong()
        }
    }
}
