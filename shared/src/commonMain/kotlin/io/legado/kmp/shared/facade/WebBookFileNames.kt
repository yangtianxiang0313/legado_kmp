package io.legado.kmp.shared.facade

import io.ktor.http.Url
import io.ktor.http.decodeURLPart
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.network.AnalyzeUrl
import io.legado.kmp.shared.network.decodeLegacyUrlOptionObject
import io.legado.kmp.shared.network.urlOptionString

/** Filename discovery is static: no AnalyzeUrl.build, JS execution, HEAD, or speculative GET. */
internal fun webBookFileOption(
    book: Book,
    urlRule: String,
    resolvedUrl: String? = null,
    resolvedType: String? = null,
): WebBookFileOption {
    requireWebBookFileRule(urlRule)
    val delimiter = AnalyzeUrl.paramPattern.findAll(urlRule).take(16).firstOrNull {
        decodeLegacyUrlOptionObject(urlRule.substring(it.range.last + 1)) != null
    }
    val rawUrl = resolvedUrl ?: delimiter?.let { urlRule.substring(0, it.range.first).trim() } ?: urlRule.trim()
    val type = resolvedType ?: delimiter?.let {
        decodeLegacyUrlOptionObject(urlRule.substring(it.range.last + 1))?.urlOptionString("type")
    }
    val knownName = knownWebBookFileName(rawUrl)
    val suffix = knownName?.substringAfterLast('.')?.lowercase() ?: webBookFileTypeSuffix(type) ?: "bin"
    val fallback = book.name.take(1024).ifBlank { "download" } +
        book.author.take(512).takeIf { it.isNotBlank() }?.let { " - $it" }.orEmpty()
    val stem = knownName?.substringBeforeLast('.') ?: fallback
    return WebBookFileOption(urlRule, "${cleanWebBookFileStem(stem)}.$suffix", suffix)
}

internal fun webBookFileTypeSuffix(type: String?): String? {
    val normalized = type?.trim()?.lowercase()?.removePrefix(".") ?: return null
    return when (normalized) {
        "text/plain" -> "txt"
        "application/epub+zip" -> "epub"
        "application/pdf" -> "pdf"
        "application/zip", "application/x-zip-compressed" -> "zip"
        "application/x-rar-compressed", "application/vnd.rar" -> "rar"
        "application/x-7z-compressed" -> "7z"
        "application/x-mobipocket-ebook" -> "mobi"
        "application/octet-stream" -> "bin"
        else -> normalized.takeIf { it.length in 1..16 && it.all { char -> char in 'a'..'z' || char in '0'..'9' } }
    }
}

private fun knownWebBookFileName(raw: String): String? {
    if (raw.contains("@js:", ignoreCase = true) || raw.contains("<js>", ignoreCase = true) ||
        "{{" in raw || "\${" in raw
    ) return null
    val url = try { Url(raw) } catch (_: Exception) { return null }
    fun candidate(value: String): String? {
        val name = value.substringAfterLast('/').substringAfterLast('\\')
        val suffix = webBookFileTypeSuffix(name.substringAfterLast('.', "")) ?: return null
        return name.takeIf { suffix !in setOf("php", "html", "htm", "asp", "aspx", "jsp") && '.' in it }
    }
    val pathName = try { url.encodedPath.substringAfterLast('/').decodeURLPart() } catch (_: Exception) { "" }
    candidate(pathName)?.let { return it }
    for (key in listOf("filename", "fileName", "file", "name", "download")) {
        url.parameters[key]?.let { candidate(it)?.let { name -> return name } }
    }
    return null
}

private fun cleanWebBookFileStem(raw: String): String {
    val text = raw.take(1024).map { char ->
        if (char.code < 32 || char.code == 127 || char in "/\\:*?\"<>|") '_' else char
    }.joinToString("").trim().trim('.')
    val result = StringBuilder()
    var index = 0
    var bytes = 0
    while (index < text.length) {
        val char = text[index]
        val paired = char.isHighSurrogate() && text.getOrNull(index + 1)?.isLowSurrogate() == true
        val piece = if (paired) text.substring(index, index + 2) else if (char.isSurrogate()) "_" else char.toString()
        val size = piece.encodeToByteArray().size
        if (bytes + size > 180) break
        result.append(piece)
        bytes += size
        index += if (paired) 2 else 1
    }
    return result.toString().trim().trim('.').ifBlank { "download" }
}
