package io.legado.kmp.shared.domain.localbook

internal data class NativeEpubArchiveHeader(
    val path: String,
    val size: Long,
    val directory: Boolean,
    val formatName: String,
    val headerPosition: Long,
)

internal fun requireNativeEpubArchivePath(path: String): String {
    try {
        BookArchiveZipReader.validatePath(path)
    } catch (_: IllegalArgumentException) {
        // The shared validator can include untrusted paths in its error messages.
        error("EPUB 压缩包路径无效")
    }
    return path
}

internal class NativeEpubArchivePaths {
    private data class Node(val path: String, val directory: Boolean)

    private val explicitPaths = mutableSetOf<String>()
    private val nodes = mutableMapOf<String, Node>()

    fun add(header: NativeEpubArchiveHeader) {
        val validatedPath = requireNativeEpubArchivePath(header.path)
        require(header.directory || !validatedPath.endsWith('/')) {
            "EPUB 压缩包条目类型与目录路径不一致"
        }
        val path = validatedPath.removeSuffix("/")
        require(explicitPaths.add(path.lowercase())) {
            "EPUB 压缩包包含重名或大小写冲突的路径"
        }
        val parts = path.split('/')
        var prefix = ""
        parts.forEachIndexed { index, part ->
            prefix = if (prefix.isEmpty()) part else "$prefix/$part"
            val directory = index < parts.lastIndex || header.directory
            val key = prefix.lowercase()
            val previous = nodes[key]
            require(previous == null || (previous.path == prefix && previous.directory && directory)) {
                "EPUB 压缩包路径存在大小写或文件与目录冲突"
            }
            nodes[key] = Node(prefix, directory)
        }
    }
}
