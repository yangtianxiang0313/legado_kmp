package io.legado.kmp.shared.facade

import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.scripting.JsContext
import io.legado.kmp.shared.scripting.JsExecutor
import io.legado.kmp.shared.scripting.JsResult
import io.legado.kmp.shared.platform.encodeBookExportText as encodePlatformBookExportText
import io.legado.kmp.shared.platform.validateBookExportCharset as validatePlatformBookExportCharset
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.JsonPrimitive

private const val FILE_NAME_BYTES = 160
private const val FILE_NAME_SCRIPT_BYTES = 16L * 1024
private const val FILE_NAME_RESULT_CHARS = 16 * 1024
private val exportAuthorPattern = Regex("^\\s*作\\s*者[:：\\s]+|\\s+著")

internal fun validateBookExportCharset(charset: String) = validatePlatformBookExportCharset(charset)

internal fun encodeBookExportText(text: String, charset: String, checkActive: () -> Unit): ByteArray =
    encodePlatformBookExportText(text, charset, checkActive)

/** Android BookExtensions bindings, followed by a bounded, single-component output name. */
internal suspend fun bookExportFileName(
    book: Book,
    extension: String,
    partIndex: Int?,
    options: BookExportOptions,
): String {
    val context = currentCoroutineContext()
    val checkActive: () -> Unit = { context.ensureActive() }
    checkActive()
    requireBookExport(extension.length <= 16, "仅支持 TXT 或 EPUB 导出文件名")
    val suffix = extension.trim().lowercase()
    requireBookExport(suffix == "txt" || suffix == "epub", "仅支持 TXT 或 EPUB 导出文件名")
    requireBookExport(partIndex == null || partIndex > 0, "导出分卷序号必须从 1 开始")
    val budget = BookExportBudget(checkActive)
    val metadataBytes = budget.textBytes(book.name, BookExportLimits.METADATA_BYTES) +
        budget.textBytes(book.author, BookExportLimits.METADATA_BYTES)
    requireBookExport(metadataBytes <= BookExportLimits.METADATA_BYTES, "导出文件名元数据超过 1 MiB 限制")

    // Android getRealAuthor uses authorRegex; Book.getRealAuthor currently has different semantics.
    val author = book.author.replace(exportAuthorPattern, "")
    val fallback = buildString {
        append(book.name)
        append(" 作者：")
        append(author)
        if (partIndex != null) append(" [$partIndex]")
    }
    val script = if (partIndex == null) options.fileNameScript else options.splitFileNameScript
    budget.textBytes(script, FILE_NAME_SCRIPT_BYTES, "导出文件名脚本超过 16 KiB 限制")
    val scriptedName = if (script.isBlank()) null else {
        evaluateExportFileName(script, book.name, author, partIndex, checkActive)
    }
    checkActive()
    val stem = scriptedName?.let { safeExportFileStem(it, suffix, checkActive) }
        ?: safeExportFileStem(fallback, suffix, checkActive)
        ?: "book"
    checkActive()
    return "$stem.$suffix"
}

private suspend fun evaluateExportFileName(
    script: String,
    name: String,
    author: String,
    partIndex: Int?,
    checkActive: () -> Unit,
): String? {
    return try {
        checkActive()
        val result = JsExecutor.Default.withMutableContext(
            JsContext(variables = mapOf("name" to name, "author" to author, "epubIndex" to (partIndex ?: ""))),
        ) { realm ->
            // eval supplies native JS completion semantics, once. Bound the value before crossing the bridge.
            // The executor's coroutine timeout cannot strictly interrupt arbitrary native JS execution.
            realm.execute("""
                (function(evaluate, stringify) {
                    var value = evaluate(${JsonPrimitive(script)});
                    if (value === null || value === void 0) return null;
                    var text = stringify(value);
                    return text.length <= $FILE_NAME_RESULT_CHARS ? text : null;
                })((0, eval), String);
            """.trimIndent())
        }
        checkActive()
        if (result is JsResult.JsError) {
            findFacadeRequestCancellation(result.exception)?.let { throw it }
            null
        } else {
            (result as? JsResult.JsString)?.value?.takeIf { it.isNotBlank() }
        }
    } catch (error: Exception) {
        checkActive()
        findFacadeRequestCancellation(error)?.let { throw it }
        // Runtime errors may contain the script or metadata. Do not retain a cause or log them.
        null
    }
}

private fun safeExportFileStem(value: String, extension: String, checkActive: () -> Unit): String? {
    val maximum = FILE_NAME_BYTES - extension.length - 1
    val output = StringBuilder(maximum)
    var size = 0
    var index = 0
    var nextCheck = 0
    while (index < value.length) {
        if (index >= nextCheck) {
            checkActive()
            nextCheck = index + 4096
        }
        val char = value[index++]
        if (char.isHighSurrogate()) {
            if (index >= value.length || !value[index].isLowSurrogate()) continue
            val low = value[index++]
            if (size + 4 > maximum) break
            output.append(char).append(low)
            size += 4
        } else {
            if (char.isLowSurrogate() || unsafeExportFileChar(char)) continue
            if (output.isEmpty() && (char.isWhitespace() || char == '.')) continue
            val bytes = when {
                char.code < 0x80 -> 1
                char.code < 0x800 -> 2
                else -> 3
            }
            if (size + bytes > maximum) break
            output.append(char)
            size += bytes
        }
    }
    checkActive()
    val stem = output.toString().trim { it.isWhitespace() || it == '.' }
    if (stem.isEmpty()) return null
    val device = stem.substringBefore('.').trimEnd().uppercase()
    val reserved = device in setOf("CON", "PRN", "AUX", "NUL") ||
        (device.length == 4 && (device.startsWith("COM") || device.startsWith("LPT")) && device[3] in '1'..'9')
    // Reapply the same codepoint budget only when a device-name prefix is actually necessary.
    return if (reserved) safeExportFileStem("_$stem", extension, checkActive) else stem
}

private fun unsafeExportFileChar(char: Char): Boolean =
    char.code in 0..31 || char.code in 127..159 || char in "\\/:*?\"<>|" ||
        char == '\u2028' || char == '\u2029' || char == '\uFEFF' ||
        char.code in 0x200B..0x200F || char.code in 0x202A..0x202E || char.code in 0x2060..0x206F
