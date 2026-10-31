package io.legado.kmp.shared.domain.localbook

import io.legado.kmp.shared.model.Book
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** A retained original changes physical reads, never the book or chapter identity. */
object LocalBookFileBinding {
    private const val KEY = "__legado_kmp_local_file_v1"
    private const val ROOT = "/Library/Application Support/LocalBooks/"
    private val formats = setOf("txt", "epub", "umd", "mobi", "azw", "azw3", "pdf")

    /** Invalid binding metadata fails closed; a missing file is never replaced by the logical path. */
    fun path(book: Book): String = boundPath(book) ?: book.bookUrl

    fun bind(book: Book, path: String): Book {
        require(retainedKey(path) != null) { "Local book binding requires a retained original path" }
        val variables = variables(book)
        return book.copy(variable = JsonObject(variables + (KEY to JsonPrimitive(path))).toString())
    }

    /** Returns the sandbox-independent directory/filename key; filesystem checks belong to the platform. */
    fun retainedKey(path: String): String? {
        if (!path.startsWith('/') || path.drop(1).split('/').any { part ->
            part.isEmpty() || part == "." || part == ".." ||
                part.any { it.code < 32 || it.code == 127 || it == '\\' }
        }) return null
        val key = path.substringAfter(ROOT, missingDelimiterValue = "")
        val parts = key.split('/')
        if (parts.size != 2) return null
        val extension = parts[0].substringBefore('-', "")
        if (extension !in formats) return null
        val digest = parts[0].substringAfter('-', "")
        if (digest.length != 64 || digest.any { it !in '0'..'9' && it !in 'a'..'f' }) return null
        val filename = parts[1]
        if (filename.substringBeforeLast('.', "").isBlank() ||
            !filename.substringAfterLast('.', "").equals(extension, ignoreCase = true)) return null
        return key
    }

    /** Non-destructive import lookup only; readers must still use the strict path accessor. */
    fun retainedKeyForBook(book: Book): String? = try {
        retainedKey(path(book))
    } catch (_: Exception) {
        null
    }

    /** Swift callers can classify metadata safely; malformed bindings never authorize a read. */
    fun format(book: Book): String = try {
        val boundPath = boundPath(book)
        if (book.isEpub) "epub" else {
            extension(book.bookUrl)
                ?: extension(book.originName)
                ?: boundPath?.let(::extension)
                ?: ""
        }
    } catch (_: Exception) {
        ""
    }

    internal fun boundPath(book: Book): String? {
        if (book.variable?.contains(KEY) != true) return null
        val value = variables(book)[KEY] ?: return null
        val path = (value as? JsonPrimitive)?.takeIf { it.isString }?.content
        require(path != null && retainedKey(path) != null) { "Invalid retained local book binding" }
        return path
    }

    private fun variables(book: Book): JsonObject {
        val variable = book.variable
        if (variable.isNullOrBlank()) return JsonObject(emptyMap())
        return Json.parseToJsonElement(variable) as? JsonObject
            ?: error("Book variables must be a JSON object")
    }

    private fun extension(path: String): String? {
        val filePath = if ("://" in path) path.substringBefore('?').substringBefore('#') else path
        return filePath.substringAfterLast('/').substringAfterLast('.', "").lowercase().takeIf { it in formats }
    }
}
