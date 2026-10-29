package io.legado.kmp.shared.facade

import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.yield

internal fun isWebBookFileInlineRule(rule: String): Boolean = rule.startsWith("data:", ignoreCase = true)

internal class WebBookFileInlineHeader(val payloadStart: Int, val mime: String) {
    override fun toString(): String = "WebBookFileInlineHeader(redacted)"
}

/** Never search the payload for delimiters, URL options, or filenames. */
internal fun webBookFileInlineHeader(rule: String): WebBookFileInlineHeader {
    requireWebBookFile(isWebBookFileInlineRule(rule), "invalidInlineData", "文件选项不是 DataURL")
    requireWebBookFile(rule.length <= WebBookFileLimits.INLINE_ENCODED_BYTES,
        "inlineTooLarge", "DataURL 编码内容（含空白和头部）超过 96 MiB 限制")
    var end = 5
    while (end < rule.length && end < WebBookFileLimits.INLINE_HEADER_BYTES && rule[end] != ',') {
        requireWebBookFile(rule[end].code in 33..126,
            "invalidInlineData", "DataURL 头部必须是安全的 ASCII MIME 和 base64 声明")
        end++
    }
    requireWebBookFile(end < rule.length && end < WebBookFileLimits.INLINE_HEADER_BYTES && rule[end] == ',',
        "invalidInlineData", "DataURL 头部无效或超过大小限制")
    val parts = rule.substring(5, end).split(';')
    requireWebBookFile(parts.size >= 2 && parts.last().equals("base64", ignoreCase = true),
        "invalidInlineData", "DataURL 仅支持 base64 编码")
    fun token(value: String): Boolean = value.isNotEmpty() && value.all {
        it in 'a'..'z' || it in 'A'..'Z' || it in '0'..'9' || it in "!#$&^_.+-"
    }
    val mime = parts.first().ifEmpty { "text/plain" }.lowercase()
    val slash = mime.indexOf('/')
    requireWebBookFile(slash > 0 && slash < mime.lastIndex &&
        token(mime.substring(0, slash)) && token(mime.substring(slash + 1)),
        "invalidInlineData", "DataURL MIME 类型无效")
    val parameters = mutableSetOf<String>()
    for (part in parts.drop(1).dropLast(1)) {
        val equals = part.indexOf('=')
        requireWebBookFile(equals > 0 && token(part.substring(0, equals)) && token(part.substring(equals + 1)),
            "invalidInlineData", "DataURL MIME 参数无效")
        val name = part.substring(0, equals).lowercase()
        requireWebBookFile(name != "base64" && parameters.add(name),
            "invalidInlineData", "DataURL MIME 参数重复或无效")
    }
    return WebBookFileInlineHeader(end + 1, mime)
}

private fun isWebBookFileBase64Whitespace(char: Char): Boolean =
    char == ' ' || char == '\t' || char == '\r' || char == '\n' || char == '\u000B' || char == '\u000C'

private class WebBookFileInlineShape(val payloadStart: Int, val symbols: Int, val decodedBytes: Long) {
    override fun toString(): String = "WebBookFileInlineShape(redacted)"
}

/** Counts the decoded size without allocating decoded bytes or a second encoded copy. */
private suspend fun inspectWebBookFileInline(rule: String): WebBookFileInlineShape {
    val header = webBookFileInlineHeader(rule)
    val context = currentCoroutineContext()
    context.ensureActive()
    var symbols = 0
    var padding = 0
    for (index in header.payloadStart until rule.length) {
        if (index % 16384 == 0) {
            context.ensureActive()
            yield()
        }
        val char = rule[index]
        when {
            isWebBookFileBase64Whitespace(char) -> Unit
            char == '=' -> {
                padding++
                requireWebBookFile(padding <= 2, "invalidInlineData", "DataURL base64 padding 无效")
            }
            char in 'A'..'Z' || char in 'a'..'z' || char in '0'..'9' || char == '+' || char == '/' -> {
                requireWebBookFile(padding == 0, "invalidInlineData", "DataURL base64 padding 后不能有内容")
                symbols++
            }
            else -> throw WebBookFileFailure("invalidInlineData", "DataURL base64 含非法字符")
        }
    }
    context.ensureActive()
    val remainder = symbols % 4
    requireWebBookFile(remainder != 1 && (padding == 0 ||
        padding == 1 && remainder == 3 || padding == 2 && remainder == 2),
        "invalidInlineData", "DataURL base64 长度或 padding 无效")
    val decodedBytes = symbols.toLong() / 4 * 3 + if (remainder == 0) 0 else remainder - 1
    requireWebBookFile(decodedBytes > 0, "invalidInlineData", "DataURL 文件内容不能为空")
    requireWebBookFile(decodedBytes <= WebBookFileLimits.INLINE_DECODED_BYTES,
        "inlineTooLarge", "DataURL 解码后超过 64 MiB 限制")
    return WebBookFileInlineShape(header.payloadStart, symbols, decodedBytes)
}

internal suspend fun validateWebBookFileInline(rule: String) {
    inspectWebBookFileInline(rule)
}

internal suspend fun prepareWebBookFileInline(option: WebBookFileOption): WebBookFileInlineData {
    val rule = option.urlRule
    val shape = inspectWebBookFileInline(rule)
    val context = currentCoroutineContext()
    val padding = (4 - shape.symbols % 4) % 4
    val normalized = StringBuilder(shape.symbols + padding)
    for (index in shape.payloadStart until rule.length) {
        if (index % 16384 == 0) {
            context.ensureActive()
            yield()
        }
        val char = rule[index]
        if (char != '=' && !isWebBookFileBase64Whitespace(char)) normalized.append(char)
    }
    repeat(padding) { normalized.append('=') }
    context.ensureActive()
    return WebBookFileInlineData(normalized.toString(), option.fileName, shape.decodedBytes)
}

internal suspend fun sameWebBookFileRule(first: String, second: String): Boolean {
    if (first === second) return true
    if (first.length != second.length) return false
    val context = currentCoroutineContext()
    for (index in first.indices) {
        if (index % 16384 == 0) {
            context.ensureActive()
            yield()
        }
        if (first[index] != second[index]) return false
    }
    context.ensureActive()
    return true
}
