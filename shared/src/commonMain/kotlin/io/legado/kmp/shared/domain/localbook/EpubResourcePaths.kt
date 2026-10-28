package io.legado.kmp.shared.domain.localbook

import io.ktor.http.encodeURLPathPart

/** Archive identities only: no URI is ever resolved against the host filesystem. */
internal object EpubResourcePaths {
    private const val PREFIX = "epub-resource:///"
    private val scheme = Regex("^[A-Za-z][A-Za-z0-9+.-]*:")

    fun toUrl(path: String): String {
        BookArchiveZipReader.validatePath(path)
        return PREFIX + path.split('/').joinToString("/") { it.encodeURLPathPart() }
    }

    fun resolve(baseDirectory: String, reference: String): String? {
        val value = reference.trim()
        if (value.isEmpty() || value.length > 8192) return null
        val local = if (value.startsWith(PREFIX)) value.removePrefix(PREFIX) else value
        if (local.startsWith("//") || scheme.containsMatchIn(local)) return null
        val encodedPath = local.substringBefore('#').substringBefore('?')
        if (encodedPath.isEmpty()) return null
        val path = decodePath(encodedPath)
        require(path.none { it.isISOControl() || it in "\\:" }) { "EPUB 资源路径无效" }
        val parts = if (value.startsWith(PREFIX) || path.startsWith('/')) mutableListOf()
            else baseDirectory.split('/').filter { it.isNotEmpty() }.toMutableList()
        path.split('/').forEach { part ->
            when (part) {
                "", "." -> Unit
                ".." -> {
                    require(parts.isNotEmpty()) { "EPUB 资源路径越过归档根目录" }
                    parts.removeAt(parts.lastIndex)
                }
                else -> parts.add(part)
            }
        }
        val result = parts.joinToString("/")
        BookArchiveZipReader.validatePath(result)
        return result
    }

    private fun decodePath(path: String): String {
        if ('%' !in path) return path
        val bytes = mutableListOf<Byte>()
        var cursor = 0
        while (cursor < path.length) {
            if (path[cursor] == '%') {
                require(cursor + 2 < path.length) { "EPUB 资源路径百分号编码不完整" }
                val byte = path.substring(cursor + 1, cursor + 3).toIntOrNull(16)
                    ?: error("EPUB 资源路径百分号编码无效")
                bytes += byte.toByte()
                cursor += 3
            } else {
                val end = path.indexOf('%', cursor).takeIf { it >= 0 } ?: path.length
                bytes.addAll(path.substring(cursor, end).encodeToByteArray().toList())
                cursor = end
            }
        }
        return bytes.toByteArray().decodeToString(throwOnInvalidSequence = true)
    }
}
