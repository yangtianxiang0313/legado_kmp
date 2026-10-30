@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.legado.kmp.shared.domain.localbook

import platform.Foundation.NSRecursiveLock

/** No native state survives an operation. Failed operations retire this reader, not its borrowed source. */
internal actual class NativeBookFileArchiveReader actual constructor(
    source: LocalBookByteSource,
    format: String,
    checkCancelled: () -> Unit,
) : BookFileArchiveReader {
    private val lock = NSRecursiveLock()
    private val sourceSize = source.size
    private val nativeFormat = nativeBookFileArchiveFormat(format)
    private var borrowedSource: LocalBookByteSource? = source
    private var cancellationCheck: (() -> Unit)? = checkCancelled
    private var directory: List<NativeBookFileArchiveHeader> = emptyList()
    private var members: List<BookArchiveMember> = emptyList()
    private var active = false
    private var closed = false

    init {
        operation { cancellationCheck ->
            directory = withSession(cancellationCheck) { archive ->
                val headers = mutableListOf<NativeBookFileArchiveHeader>()
                val paths = BookFileArchivePaths()
                var declared = 0L
                while (true) {
                    val header = archive.next() ?: break
                    paths.add(header.path, header.directory)
                    require(header.size <= BookFileArchiveLimits.TOTAL_BYTES - declared) {
                        "Archive declared total exceeds 16 GiB"
                    }
                    declared += header.size
                    headers += header
                    archive.skip(header)
                }
                headers.toList()
            }
            members = directory.filterNot { it.directory }.map {
                cancellationCheck()
                BookArchiveMember(it.path, it.size)
            }
        }
    }

    actual override fun entries(): List<BookArchiveMember> = operation { members.toList() }

    actual override fun extract(path: String, write: (ByteArray) -> Unit): Long = operation { checkCancelled ->
        val headers = directory
        val selected = headers.indexOfFirst { !it.directory && it.path == path }
        require(selected >= 0) { "Selected book is not present in the indexed archive" }
        withSession(checkCancelled) { archive ->
            var written = 0L
            headers.forEachIndexed { index, expected ->
                checkCancelled()
                require(archive.next() == expected) { "Archive directory differs from its index" }
                if (index == selected) {
                    written = archive.consume(expected, write)
                } else {
                    archive.skip(expected)
                }
            }
            // Also compare trailing directories/entries, not only the prefix before the selected file.
            require(archive.next() == null) { "Archive contains unindexed entries" }
            written
        }
    }

    actual override fun validateAll() {
        operation { checkCancelled ->
            val headers = directory
            withSession(checkCancelled) { archive ->
                var total = 0L
                // One forward pass, including solid RAR/7z, without reopening once per member.
                headers.forEach { expected ->
                    checkCancelled()
                    require(archive.next() == expected) { "Archive directory differs from its index" }
                    val count = archive.consume(expected, write = null)
                    require(count <= BookFileArchiveLimits.TOTAL_BYTES - total) { "Archive actual total exceeds 16 GiB" }
                    total += count
                }
                require(archive.next() == null) { "Archive contains unindexed entries" }
            }
        }
    }

    actual override fun close() {
        lock.lock()
        try {
            // Reentrant close from a writer cancels the active operation at its next check.
            retire()
        } finally {
            lock.unlock()
        }
    }

    private fun <T> withSession(checkCancelled: () -> Unit, action: (NativeBookFileArchiveSession) -> T): T =
        withNativeBookFileArchiveSession(
            checkNotNull(borrowedSource) { "Archive reader is closed" }, sourceSize,
            nativeFormat, checkCancelled, action,
        )

    private fun checkOpen() {
        check(!closed) { "Archive reader is closed" }
        checkNotNull(cancellationCheck) { "Archive reader is closed" }.invoke()
        require(borrowedSource?.size == sourceSize) { "Archive source length changed" }
    }

    private fun retire() {
        closed = true
        borrowedSource = null
        cancellationCheck = null
        directory = emptyList()
        members = emptyList()
    }

    private fun <T> operation(action: (() -> Unit) -> T): T {
        lock.lock()
        try {
            check(!closed) { "Archive reader is closed" }
            check(!active) { "Archive reader operation is already active" }
            active = true
            try {
                checkOpen()
                return action(::checkOpen).also { checkOpen() }
            } catch (error: Throwable) {
                retire()
                throw error
            } finally {
                active = false
            }
        } finally {
            lock.unlock()
        }
    }
}
