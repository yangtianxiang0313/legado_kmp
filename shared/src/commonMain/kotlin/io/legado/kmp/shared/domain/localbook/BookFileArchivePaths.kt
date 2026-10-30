package io.legado.kmp.shared.domain.localbook

internal fun requireBookFileArchivePath(path: String): String {
    require(path.isNotEmpty() && path.encodeToByteArray().size <= BookFileArchiveLimits.PATH_BYTES) {
        "Archive path is empty or exceeds 1024 UTF-8 bytes"
    }
    require(path.none { it.code < 32 || it.code in 127..159 || it in "\\:" }) {
        "Archive path contains unsafe characters"
    }
    val parts = path.removeSuffix("/").split('/')
    require(parts.none {
        it.isEmpty() || it == "." || it == ".." || it.endsWith(' ') || it.endsWith('.')
    }) { "Archive path is absolute or ambiguous" }
    return path
}

/** Component trie avoids retaining every full prefix of deeply nested paths. */
internal class BookFileArchivePaths {
    private class Node(val name: String, val directory: Boolean, var explicit: Boolean) {
        val children = mutableMapOf<String, Node>()
    }

    private val roots = mutableMapOf<String, Node>()
    private var entries = 0
    private var pathBytes = 0
    private var nodes = 0
    private var nodeBytes = 0

    fun add(path: String, directory: Boolean) {
        requireBookFileArchivePath(path)
        require(directory || !path.endsWith('/')) { "Archive file has a directory path" }
        require(entries < BookFileArchiveLimits.ENTRIES) { "Archive contains more than 10000 entries" }
        val bytes = path.encodeToByteArray().size
        require(bytes <= BookFileArchiveLimits.TOTAL_PATH_BYTES - pathBytes) {
            "Archive paths exceed the 4 MiB index budget"
        }
        entries++
        pathBytes += bytes
        val parts = path.removeSuffix("/").split('/')
        var children = roots
        parts.forEachIndexed { index, part ->
            val explicit = index == parts.lastIndex
            val isDirectory = !explicit || directory
            // Folding both ways also detects expanding case pairs such as sharp-s/SS.
            val key = part.uppercase().lowercase()
            val previous = children[key]
            if (previous != null) {
                require(previous.name == part && previous.directory && isDirectory) {
                    "Archive has a case conflict or a file/directory collision"
                }
                require(!explicit || !previous.explicit) { "Archive contains a duplicate path" }
                if (explicit) previous.explicit = true
                children = previous.children
            } else {
                require(nodes < BookFileArchiveLimits.PATH_NODES) { "Archive has too many directory nodes" }
                val retainedBytes = part.encodeToByteArray().size + key.encodeToByteArray().size
                require(retainedBytes <= BookFileArchiveLimits.TOTAL_NODE_BYTES - nodeBytes) {
                    "Archive directory nodes exceed their memory budget"
                }
                val node = Node(part, isDirectory, explicit)
                children[key] = node
                children = node.children
                nodes++
                nodeBytes += retainedBytes
            }
        }
    }
}
