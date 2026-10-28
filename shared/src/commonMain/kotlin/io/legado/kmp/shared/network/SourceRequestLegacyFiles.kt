package io.legado.kmp.shared.network

import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.platform.AppFilesDirectory
import io.legado.kmp.shared.platform.EncodingDetector
import io.legado.kmp.shared.platform.FileAccess
import io.legado.kmp.shared.platform.TextCodec
import io.legado.kmp.shared.util.md5Hex
import okio.Buffer
import okio.Inflater
import okio.InflaterSource

internal class SourceRequestLegacyFiles(
    private val fileAccess: FileAccess?,
    private val appFilesDirectory: AppFilesDirectory?,
    private val prepareRequest: suspend (
        source: BookSource,
        urlRule: String,
        baseUrl: String,
        ruleData: Map<String, Any?>,
        chapter: BookChapter?,
    ) -> BuiltUrl,
    private val executeRequest: suspend (
        request: BuiltUrl,
        source: BookSource,
        ruleData: Map<String, Any?>,
        chapter: BookChapter?,
    ) -> HttpResponse,
) {

    suspend fun readLocalScript(path: String): String? {
        return readTextFile(path, charsetName = null).takeIf { it.isNotBlank() }
    }

    suspend fun downloadFile(
        source: BookSource,
        urlRule: String,
        baseUrl: String,
        ruleData: Map<String, Any?>,
        chapter: BookChapter?,
    ): String {
        val builtRequest = prepareRequest(source, urlRule, baseUrl.ifBlank { source.bookSourceUrl }, ruleData, chapter)
        val response = executeRequest(builtRequest, source, ruleData, chapter)
        val suffix = legacyDownloadSuffix(builtRequest, urlRule)
        val relativePath = "/${urlRule.md5Hex().substring(8, 24)}.$suffix"
        writeLegacyCacheFile(relativePath, response.body)
        return relativePath
    }

    suspend fun writeHexFile(
        source: BookSource,
        contentHex: String,
        urlRule: String,
        baseUrl: String,
        ruleData: Map<String, Any?>,
        chapter: BookChapter?,
    ): String {
        val builtRequest = prepareRequest(source, urlRule, baseUrl.ifBlank { source.bookSourceUrl }, ruleData, chapter)
        val type = builtRequest.type?.takeIf { it.isNotBlank() } ?: return ""
        val relativePath = "/${urlRule.md5Hex().substring(8, 24)}.$type"
        writeLegacyCacheFile(relativePath, contentHex.decodeLegacyHexFileBytes())
        return relativePath
    }

    suspend fun readFile(path: String): ByteArray? {
        val resolvedPath = resolveLegacyCacheFilePath(path) ?: return null
        val access = fileAccess ?: return null
        if (!access.exists(resolvedPath)) return null
        return access.read(resolvedPath)
    }

    suspend fun readTextFile(path: String, charsetName: String?): String {
        val bytes = readFile(path) ?: return ""
        return decodeLegacyFileText(bytes, charsetName)
    }

    suspend fun deleteFile(path: String): Boolean {
        val resolvedPath = resolveLegacyCacheFilePath(path) ?: return false
        val access = fileAccess ?: return false
        return access.delete(resolvedPath)
    }

    suspend fun getTextInFolder(path: String): String {
        val folderPath = resolveLegacyCacheFilePath(path) ?: return ""
        val access = fileAccess ?: return ""
        val fileNames = runCatching { access.listFiles(folderPath) }.getOrDefault(emptyList())
        if (fileNames.isEmpty()) {
            access.delete(folderPath)
            return ""
        }
        val contents = StringBuilder()
        fileNames.forEach { fileName ->
            val childPath = joinFilePath(folderPath, fileName)
            val bytes = runCatching { access.read(childPath) }.getOrNull() ?: return@forEach
            contents.append(decodeLegacyFileText(bytes, charsetName = null)).append('\n')
        }
        access.delete(folderPath)
        return contents.toString().trimEnd('\n')
    }

    suspend fun getZipByteArrayContent(
        source: BookSource,
        url: String,
        path: String,
        baseUrl: String,
        ruleData: Map<String, Any?>,
        chapter: BookChapter?,
    ): ByteArray? {
        if (url.isBlank() || path.isBlank()) return null
        val bytes = fetchLegacyZipBytes(
            source = source,
            url = url,
            baseUrl = baseUrl,
            ruleData = ruleData,
            chapter = chapter,
        )
        return extractLegacyZipEntry(bytes, path)
    }

    suspend fun getZipStringContent(
        source: BookSource,
        url: String,
        path: String,
        charsetName: String?,
        baseUrl: String,
        ruleData: Map<String, Any?>,
        chapter: BookChapter?,
    ): String {
        val bytes = getZipByteArrayContent(
            source = source,
            url = url,
            path = path,
            baseUrl = baseUrl,
            ruleData = ruleData,
            chapter = chapter,
        ) ?: return ""
        return decodeLegacyFileText(bytes, charsetName)
    }

    private suspend fun writeLegacyCacheFile(relativePath: String, bytes: ByteArray) {
        val access = fileAccess ?: throw SharedCapabilityException(
            capabilityGapKey = "legacy_js_local_file_helpers_unsupported",
            message = "Legacy JS local file helpers are not implemented in shared execution yet"
        )
        val root = appFilesDirectory?.path() ?: throw SharedCapabilityException(
            capabilityGapKey = "legacy_js_local_file_helpers_unsupported",
            message = "Legacy JS local file helpers are not implemented in shared execution yet"
        )
        val resolvedPath = resolveLegacyCacheFilePath(relativePath) ?: throw IllegalArgumentException("非法路径")
        access.createDirectory(root)
        access.delete(resolvedPath)
        if (!access.write(resolvedPath, bytes)) {
            throw IllegalStateException("Failed to write legacy JS cache file: $relativePath")
        }
    }

    private fun resolveLegacyCacheFilePath(path: String): String? {
        val root = appFilesDirectory?.path() ?: return null
        val normalized = path.replace('\\', '/').trim()
        if (normalized.isBlank()) return null
        val parts = normalized
            .trimStart('/')
            .split('/')
            .filter { it.isNotBlank() && it != "." }
        if (parts.isEmpty() || parts.any { it == ".." }) {
            return null
        }
        return joinFilePath(root, parts.joinToString("/"))
    }

    private fun decodeLegacyFileText(bytes: ByteArray, charsetName: String?): String {
        val detectedCharset = charsetName?.takeIf { it.isNotBlank() }
            ?: runCatching { EncodingDetector().detect(bytes) }.getOrDefault("UTF-8")
        return runCatching {
            TextCodec.decode(bytes, detectedCharset)
        }.getOrElse {
            bytes.decodeToString()
        }
    }

    private suspend fun fetchLegacyZipBytes(
        source: BookSource,
        url: String,
        baseUrl: String,
        ruleData: Map<String, Any?>,
        chapter: BookChapter?,
    ): ByteArray {
        if (!isAbsoluteWebUrl(url)) {
            return url.decodeLegacyHexFileBytes()
        }
        val builtRequest = prepareRequest(source, url, baseUrl.ifBlank { source.bookSourceUrl }, ruleData, chapter)
        return executeRequest(builtRequest, source, ruleData, chapter).body
    }

    private fun extractLegacyZipEntry(bytes: ByteArray, entryPath: String): ByteArray? {
        val normalizedEntry = entryPath.replace('\\', '/').trimStart('/')
        if (bytes.isEmpty() || normalizedEntry.isBlank()) return null
        val centralDirectoryOffset = findLegacyZipCentralDirectoryOffset(bytes) ?: return null
        var cursor = centralDirectoryOffset
        while (cursor + ZIP_CENTRAL_HEADER_SIZE <= bytes.size && bytes.readLeInt(cursor) == ZIP_CENTRAL_HEADER_SIGNATURE) {
            val method = bytes.readLeShort(cursor + 10)
            val compressedSize = bytes.readLeInt(cursor + 20)
            val nameLength = bytes.readLeShort(cursor + 28)
            val extraLength = bytes.readLeShort(cursor + 30)
            val commentLength = bytes.readLeShort(cursor + 32)
            val localHeaderOffset = bytes.readLeInt(cursor + 42)
            val nameStart = cursor + ZIP_CENTRAL_HEADER_SIZE
            val nameEnd = nameStart + nameLength
            if (nameEnd > bytes.size) return null
            val name = bytes.copyOfRange(nameStart, nameEnd).decodeToString().replace('\\', '/').trimStart('/')
            if (name == normalizedEntry) {
                return extractLegacyZipLocalEntry(
                    bytes = bytes,
                    localHeaderOffset = localHeaderOffset,
                    compressedSize = compressedSize,
                    method = method,
                )
            }
            cursor = nameEnd + extraLength + commentLength
        }
        return null
    }

    private fun extractLegacyZipLocalEntry(
        bytes: ByteArray,
        localHeaderOffset: Int,
        compressedSize: Int,
        method: Int,
    ): ByteArray? {
        if (localHeaderOffset < 0 || localHeaderOffset + ZIP_LOCAL_HEADER_SIZE > bytes.size) return null
        if (bytes.readLeInt(localHeaderOffset) != ZIP_LOCAL_HEADER_SIGNATURE) return null
        val nameLength = bytes.readLeShort(localHeaderOffset + 26)
        val extraLength = bytes.readLeShort(localHeaderOffset + 28)
        val dataStart = localHeaderOffset + ZIP_LOCAL_HEADER_SIZE + nameLength + extraLength
        val dataEnd = dataStart + compressedSize
        if (dataStart < 0 || dataEnd > bytes.size || dataStart > dataEnd) return null
        val compressed = bytes.copyOfRange(dataStart, dataEnd)
        return when (method) {
            ZIP_STORED_METHOD -> compressed
            ZIP_DEFLATED_METHOD -> compressed.inflateLegacyZipEntry()
            else -> null
        }
    }

    private fun findLegacyZipCentralDirectoryOffset(bytes: ByteArray): Int? {
        val minOffset = (bytes.size - ZIP_END_HEADER_MAX_SEARCH).coerceAtLeast(0)
        var cursor = bytes.size - ZIP_END_HEADER_SIZE
        while (cursor >= minOffset) {
            if (bytes.readLeInt(cursor) == ZIP_END_HEADER_SIGNATURE) {
                val centralDirectoryOffset = bytes.readLeInt(cursor + 16)
                if (centralDirectoryOffset in bytes.indices) return centralDirectoryOffset
            }
            cursor--
        }
        return null
    }

    private fun ByteArray.inflateLegacyZipEntry(): ByteArray? {
        val compressed = Buffer().apply { write(this@inflateLegacyZipEntry) }
        val decompressed = Buffer()
        val source = InflaterSource(compressed, Inflater(true))
        return runCatching {
            try {
                decompressed.writeAll(source)
                decompressed.readByteArray()
            } finally {
                source.close()
            }
        }.getOrNull()
    }

    private fun ByteArray.readLeShort(offset: Int): Int {
        if (offset < 0 || offset + 1 >= size) return -1
        return (this[offset].toInt() and 0xff) or
            ((this[offset + 1].toInt() and 0xff) shl 8)
    }

    private fun ByteArray.readLeInt(offset: Int): Int {
        if (offset < 0 || offset + 3 >= size) return -1
        return (this[offset].toInt() and 0xff) or
            ((this[offset + 1].toInt() and 0xff) shl 8) or
            ((this[offset + 2].toInt() and 0xff) shl 16) or
            ((this[offset + 3].toInt() and 0xff) shl 24)
    }

    private fun isAbsoluteWebUrl(value: String): Boolean {
        return value.startsWith("http://", ignoreCase = true) ||
            value.startsWith("https://", ignoreCase = true)
    }

    private fun legacyDownloadSuffix(request: BuiltUrl, urlRule: String): String {
        request.type?.takeIf { it.isNotBlank() }?.let { return it.trimStart('.') }
        val urlPath = request.urlNoQuery
            .ifBlank { urlRule }
            .substringBefore(',')
            .substringBefore('#')
            .substringBefore('?')
        val suffix = urlPath.substringAfterLast('/', urlPath)
            .substringAfterLast('.', "")
            .lowercase()
        return suffix.takeIf { it.length in 1..16 && it.all { char -> char.isLetterOrDigit() } } ?: "bin"
    }

    private fun String.decodeLegacyHexFileBytes(): ByteArray {
        val source = trim()
        if (source.length % 2 != 0) return ByteArray(0)
        return runCatching {
            ByteArray(source.length / 2) { index ->
                val offset = index * 2
                val high = source[offset].digitToInt(16)
                val low = source[offset + 1].digitToInt(16)
                ((high shl 4) or low).toByte()
            }
        }.getOrDefault(ByteArray(0))
    }

    private fun isAbsoluteFilePath(path: String): Boolean {
        return path.startsWith("/") || Regex("""^[A-Za-z]:[\\/].*""").matches(path)
    }

    private fun joinFilePath(root: String, child: String): String {
        val separator = if (root.endsWith("/") || root.endsWith("\\")) "" else "/"
        return root + separator + child.trimStart('/', '\\')
    }

    private companion object {
        private const val ZIP_LOCAL_HEADER_SIGNATURE = 0x04034b50
        private const val ZIP_CENTRAL_HEADER_SIGNATURE = 0x02014b50
        private const val ZIP_END_HEADER_SIGNATURE = 0x06054b50
        private const val ZIP_LOCAL_HEADER_SIZE = 30
        private const val ZIP_CENTRAL_HEADER_SIZE = 46
        private const val ZIP_END_HEADER_SIZE = 22
        private const val ZIP_END_HEADER_MAX_SEARCH = 65557
        private const val ZIP_STORED_METHOD = 0
        private const val ZIP_DEFLATED_METHOD = 8
    }
}
