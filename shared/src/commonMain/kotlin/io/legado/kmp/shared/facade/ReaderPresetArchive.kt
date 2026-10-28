package io.legado.kmp.shared.facade

import io.legado.kmp.shared.preferences.ReaderPreset
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi

/**
 * Flat Android reader-preset ZIPs. Map values are standard base64 binary, including readConfig.json.
 * Limits: 64 entries, 32 MiB per entry, 64 MiB expanded and 64 MiB input ZIP.
 * JSON is limited to 4 MiB UTF-8 and the codec's 1 MiB-character budget; stored output to 64 MiB.
 * Only the font and custom day/night/e-ink images referenced by the config are returned or packed.
 * Missing resources stay missing for the platform layer to handle. No path is opened or extracted.
 */
@OptIn(ExperimentalEncodingApi::class)
class ReaderPresetArchive {
    private val codec = ReaderPresetTransferCodec()

    @Throws(RecoverableSharedException::class)
    fun unpack(base64Zip: String): Map<String, String> = recover("ReaderPresetArchive.unpack") {
        val bytes = decodeBase64(base64Zip, MAX_ARCHIVE_BYTES, "ZIP")
        val archive = BackupZipReader(
            bytes,
            BackupZipReader.Limits(
                maxArchiveBytes = MAX_ARCHIVE_BYTES,
                maxEntries = MAX_ENTRIES,
                maxEntryBytes = MAX_ENTRY_BYTES,
                maxTotalBytes = MAX_TOTAL_BYTES,
                validateName = ::validateName,
            ),
        )
        validateNames(archive.names())
        require(CONFIG_NAME in archive.names()) { "ZIP 缺少 $CONFIG_NAME" }
        val config = archive.raw(CONFIG_NAME, MAX_CONFIG_BYTES) ?: error("无法读取 $CONFIG_NAME")
        val preset = codec.decode(config.decodeToString(throwOnInvalidSequence = true))
        val result = linkedMapOf(CONFIG_NAME to Base64.encode(config))
        // Validate all metadata, but inflate only the config and resources actually used by it.
        referencedNames(preset).forEach { name ->
            archive.raw(name)?.let { result[name] = Base64.encode(it) }
        }
        result
    }

    @Throws(RecoverableSharedException::class)
    fun pack(base64Entries: Map<String, String>): String = recover("ReaderPresetArchive.pack") {
        require(base64Entries.size <= MAX_ENTRIES) { "阅读配置归档最多 $MAX_ENTRIES 项" }
        validateNames(base64Entries.keys)
        val encodedConfig = base64Entries[CONFIG_NAME] ?: error("归档缺少 $CONFIG_NAME")
        var declaredBytes = 0L
        base64Entries.forEach { (name, encoded) ->
            declaredBytes += decodedSize(encoded, MAX_ENTRY_BYTES, name)
            require(declaredBytes <= MAX_TOTAL_BYTES) { "归档文件总大小超过 64 MiB" }
        }
        val config = decodeBase64(encodedConfig, MAX_CONFIG_BYTES, CONFIG_NAME)
        val preset = codec.decode(config.decodeToString(throwOnInvalidSequence = true))
        val names = listOf(CONFIG_NAME) + referencedNames(preset).filter { it in base64Entries }

        // Reserve the exact stored ZIP size, including headers, before decoding resources.
        var storedBytes = 22L
        names.forEach { name ->
            storedBytes += 76L + 2L * name.encodeToByteArray().size +
                decodedSize(base64Entries.getValue(name), MAX_ENTRY_BYTES, name)
            require(storedBytes <= MAX_ARCHIVE_BYTES) { "阅读配置打包大小超过 64 MiB（含 ZIP 目录）" }
        }
        val entries = names.map { name ->
            ZipEntryData(name, if (name == CONFIG_NAME) config else {
                decodeBase64(base64Entries.getValue(name), MAX_ENTRY_BYTES, name)
            })
        }
        val archive = buildStoredZip(entries)
        require(archive.size.toLong() == storedBytes && archive.size <= MAX_ARCHIVE_BYTES) { "阅读配置 ZIP 大小异常" }
        Base64.encode(archive)
    }

    private fun referencedNames(preset: ReaderPreset): Set<String> {
        val references = linkedSetOf<String>()
        fun include(path: String?) {
            if (path.isNullOrEmpty()) return
            // Android exports may retain an absolute bgStr. Only its filename is matched in memory.
            val components = path.replace('\\', '/').split('/')
            require(components.none { it == ".." || it == "." }) { "资源引用不能包含相对目录跳转" }
            val name = components.last()
            validateName(name)
            require(!name.equals(CONFIG_NAME, ignoreCase = true)) { "资源不能引用 $CONFIG_NAME" }
            references += name
        }
        include(preset.textFont)
        if (preset.bgType == 2) {
            val day = preset.bgStr
            include(if (day.isNullOrEmpty() || day.startsWith('#')) preset.backgroundImagePath else day)
        }
        if (preset.bgTypeNight == 2) include(preset.bgStrNight)
        if (preset.bgTypeEInk == 2) include(preset.bgStrEInk)
        return references
    }

    private fun validateNames(names: Set<String>) {
        require(names.size <= MAX_ENTRIES) { "阅读配置归档最多 $MAX_ENTRIES 项" }
        val folded = mutableSetOf<String>()
        names.forEach { name ->
            validateName(name)
            require(folded.add(name.lowercase())) { "归档包含大小写冲突的重名文件" }
        }
    }

    private fun validateName(name: String) {
        require(name.isNotEmpty() && name.length <= MAX_NAME_BYTES && name.encodeToByteArray().size <= MAX_NAME_BYTES) {
            "归档文件名为空或超过 $MAX_NAME_BYTES 字节"
        }
        require(name.first() != '.' && name.first() != ' ' && name.last() != '.' && name.last() != ' ' &&
            ".." !in name && name.all { it.isLetterOrDigit() || it in "._- ()" }) {
            "归档只接受安全扁平文件名，不能包含路径或目录跳转"
        }
    }

    private fun decodedSize(value: String, maxBytes: Int, label: String): Long {
        require(value.length.toLong() <= ((maxBytes.toLong() + 2) / 3) * 4) { "$label 的 base64 超过大小上限" }
        val remainder = value.length % 4
        val padding = when {
            value.endsWith("==") -> 2
            value.endsWith('=') -> 1
            else -> 0
        }
        require(remainder != 1 && (padding == 0 || remainder == 0)) { "$label 的 base64 长度无效" }
        val size = value.length.toLong() / 4 * 3 - padding + when (remainder) {
            2 -> 1
            3 -> 2
            else -> 0
        }
        require(size in 0..maxBytes.toLong()) { "$label 超过大小上限" }
        return size
    }

    private fun decodeBase64(value: String, maxBytes: Int, label: String): ByteArray {
        val expected = decodedSize(value, maxBytes, label)
        return Base64.decode(value).also { require(it.size.toLong() == expected) { "$label 的 base64 数据无效" } }
    }

    private inline fun <T> recover(code: String, block: () -> T): T = try {
        block()
    } catch (error: Exception) {
        throw error.asRecoverableSharedException(code)
    }

    private companion object {
        const val CONFIG_NAME = "readConfig.json"
        const val MAX_ENTRIES = 64
        const val MAX_NAME_BYTES = 240
        const val MAX_ENTRY_BYTES = 32 * 1024 * 1024
        const val MAX_TOTAL_BYTES = 64 * 1024 * 1024
        const val MAX_ARCHIVE_BYTES = 64 * 1024 * 1024
        const val MAX_CONFIG_BYTES = 4 * 1024 * 1024
    }
}
