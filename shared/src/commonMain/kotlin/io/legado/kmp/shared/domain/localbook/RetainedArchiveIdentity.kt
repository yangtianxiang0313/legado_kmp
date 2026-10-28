package io.legado.kmp.shared.domain.localbook

import io.legado.kmp.shared.model.BookType
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

@Serializable
internal data class RetainedArchiveIdentity(val archiveId: String, val entryPath: String, val format: String) {
    fun validate() {
        require(format in RetainedArchiveOrigins.FORMATS) { "压缩包格式无效" }
        require(archiveId.length == 64 && archiveId.all { it in "0123456789abcdef" }) { "压缩包身份无效" }
        validateRetainedArchivePath(entryPath)
        require(!entryPath.endsWith('/') &&
            entryPath.substringAfterLast('.', "").lowercase() in RetainedArchiveOrigins.BOOK_FORMATS) {
            "仅支持压缩包内的 TXT/EPUB/PDF/UMD/MOBI 书籍"
        }
    }
}

internal data class RetainedArchiveBookFile(val identity: RetainedArchiveIdentity, val path: String) {
    val origin: String get() = RetainedArchiveOrigins.encode(identity)
}

internal object RetainedArchiveOrigins {
    val FORMATS = listOf("zip", "rar", "7z")
    val BOOK_FORMATS = setOf("txt", "epub", "pdf", "umd", "mobi", "azw", "azw3")
    private const val ZIP_PREFIX = "${BookType.LOCAL_TAG}::zip-v1:"
    private const val ARCHIVE_PREFIX = "${BookType.LOCAL_TAG}::archive-v2:"

    // Keep ZIP's serialized shape unchanged, including the absence of a format field.
    @Serializable
    private data class ZipIdentity(val archiveId: String, val entryPath: String)

    @OptIn(ExperimentalEncodingApi::class)
    fun encode(identity: RetainedArchiveIdentity): String {
        identity.validate()
        val (prefix, json) = if (identity.format == "zip") {
            ZIP_PREFIX to Json.encodeToString(ZipIdentity(identity.archiveId, identity.entryPath))
        } else {
            ARCHIVE_PREFIX to Json.encodeToString(identity)
        }
        return prefix + Base64.UrlSafe.encode(json.encodeToByteArray())
    }

    @OptIn(ExperimentalEncodingApi::class)
    fun decode(origin: String): RetainedArchiveIdentity? {
        val prefix = when {
            origin.startsWith(ZIP_PREFIX) -> ZIP_PREFIX
            origin.startsWith(ARCHIVE_PREFIX) -> ARCHIVE_PREFIX
            else -> return null
        }
        require(origin.length <= 8192) { "压缩书籍来源身份过长" }
        val json = Base64.UrlSafe.decode(origin.removePrefix(prefix)).decodeToString(throwOnInvalidSequence = true)
        val identity = if (prefix == ZIP_PREFIX) {
            val zip = Json.decodeFromString<ZipIdentity>(json)
            RetainedArchiveIdentity(zip.archiveId, zip.entryPath, "zip")
        } else {
            Json.decodeFromString<RetainedArchiveIdentity>(json).also {
                require(it.format == "rar" || it.format == "7z") { "压缩书籍来源格式与版本不一致" }
            }
        }
        identity.validate()
        return identity
    }
}

internal fun validateRetainedArchivePath(path: String) {
    try {
        BookArchiveZipReader.validatePath(path)
    } catch (error: IllegalArgumentException) {
        throw IllegalArgumentException("压缩包路径无效：$path", error)
    }
}
