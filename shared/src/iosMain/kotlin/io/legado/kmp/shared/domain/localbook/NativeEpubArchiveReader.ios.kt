@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.legado.kmp.shared.domain.localbook

import platform.Foundation.NSLock

/** Scoped to one EPUB request. Native sessions borrow, and never close, the caller's byte source. */
internal actual class NativeEpubArchiveReader actual constructor(
    source: LocalBookByteSource,
    checkCancelled: () -> Unit,
) : EpubArchiveReader {
    private val lock = NSLock()
    private val sourceSize = source.size
    private var borrowedSource: LocalBookByteSource? = source
    private var cancellationCheck: (() -> Unit)? = checkCancelled
    private var session: NativeEpubArchiveSession? = null
    private var directory: List<NativeEpubArchiveHeader>? = null
    private var members: List<EpubArchiveEntry> = emptyList()
    private var pathIndices: Map<String, Int> = emptyMap()
    private var cursorIndex = -1
    private var lastFileIndex = -1

    init {
        checkCancelled()
        require(sourceSize in 1L..EpubArchiveReadLimits.ARCHIVE_BYTES) { "EPUB source is empty or exceeds 16 GiB" }
    }

    actual override fun entries(): List<EpubArchiveEntry> = operation { checkCancelled ->
        index(checkCancelled)
        members.toList()
    }

    actual override fun read(path: String, maximumBytes: Int): ByteArray = operation { checkCancelled ->
        require(maximumBytes >= 0) { "EPUB resource read limit is negative" }
        val headers = index(checkCancelled)
        val selected = pathIndices[path] ?: error("EPUB resource is not present in the indexed archive")
        val expected = headers[selected]
        require(expected.size <= maximumBytes.toLong()) { "EPUB resource exceeds its read limit" }
        if (cursorIndex >= selected) closeSession()
        val archive = session(checkCancelled)
        archive.operation(checkCancelled) {
            // A monotonic resource pass advances once per entry, not once per entry per resource.
            while (cursorIndex < selected) {
                checkCancelled()
                val header = archive.next() ?: error("EPUB directory ended before the indexed resource")
                val nextIndex = cursorIndex + 1
                require(header == headers[nextIndex]) { "EPUB file header differs from its index" }
                cursorIndex = nextIndex
                if (nextIndex != selected) archive.skip(header)
            }
            val result = archive.read(expected, maximumBytes)
            if (selected == lastFileIndex) {
                // Include trailing directories and EOF in the identity check of a complete resource pass.
                while (cursorIndex < headers.lastIndex) {
                    val header = archive.next() ?: error("EPUB directory ended early")
                    val nextIndex = cursorIndex + 1
                    require(header == headers[nextIndex]) { "EPUB file header differs from its index" }
                    archive.skip(header)
                    cursorIndex = nextIndex
                }
                require(archive.next() == null) { "EPUB directory contains unindexed entries" }
                cursorIndex = headers.size
            }
            result
        }
    }

    actual override fun closeReader() {
        lock.lock()
        try {
            try {
                closeSession()
            } finally {
                borrowedSource = null
                cancellationCheck = null
                directory = null
                members = emptyList()
                pathIndices = emptyMap()
                lastFileIndex = -1
            }
        } finally {
            lock.unlock()
        }
    }

    private fun index(checkCancelled: () -> Unit): List<NativeEpubArchiveHeader> {
        directory?.let { return it }
        val archive = session(checkCancelled)
        val headers = mutableListOf<NativeEpubArchiveHeader>()
        val paths = NativeEpubArchivePaths()
        var declared = 0L
        archive.operation(checkCancelled) {
            while (true) {
                val header = archive.next() ?: break
                require(headers.size < EpubArchiveReadLimits.ENTRIES) { "EPUB contains more than 100000 entries" }
                require(header.size <= EpubArchiveReadLimits.DECLARED_BYTES - declared) {
                    "EPUB declared resource total exceeds 64 GiB"
                }
                declared += header.size
                paths.add(header)
                headers += header
                archive.skip(header)
            }
        }
        val indexed = headers.toList()
        val indices = mutableMapOf<String, Int>()
        val files = mutableListOf<EpubArchiveEntry>()
        indexed.forEachIndexed { index, header ->
            checkCancelled()
            if (!header.directory) {
                indices[header.path] = index
                files += EpubArchiveEntry(header.path, header.size, packedSize = null)
                lastFileIndex = index
            }
        }
        directory = indexed
        members = files.toList()
        pathIndices = indices.toMap()
        cursorIndex = indexed.size
        return indexed
    }

    private fun session(checkCancelled: () -> Unit): NativeEpubArchiveSession {
        session?.let { return it }
        val source = checkNotNull(borrowedSource) { "EPUB archive reader is closed" }
        return openNativeEpubArchiveSession(source, sourceSize, checkCancelled).also {
            session = it
            cursorIndex = -1
        }
    }

    private fun closeSession(primary: Throwable? = null) {
        val previous = session
        session = null
        cursorIndex = -1
        previous?.close(primary)
    }

    private fun <T> operation(action: (() -> Unit) -> T): T {
        lock.lock()
        try {
            val checkCancelled = checkNotNull(cancellationCheck) { "EPUB archive reader is closed" }
            try {
                checkCancelled()
                require(borrowedSource?.size == sourceSize) { "EPUB source length changed" }
                return action(checkCancelled).also { checkCancelled() }
            } catch (error: Throwable) {
                closeSession(error)
                throw error
            }
        } finally {
            lock.unlock()
        }
    }
}
