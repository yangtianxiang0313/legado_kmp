package io.legado.kmp.shared.scripting

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive

private const val LEGACY_BASE64_NO_PADDING = 1
private const val LEGACY_BASE64_URL_SAFE = 8

internal fun Any?.legacyBase64Flags(): Int {
    return toString().toDoubleOrNull()?.toInt() ?: 0
}

internal fun String.normalizedLegacyBase64(flags: Int): String {
    val source = if ((flags and LEGACY_BASE64_URL_SAFE) != 0) {
        replace('-', '+').replace('_', '/')
    } else {
        this
    }.filterNot { it == '\r' || it == '\n' || it == ' ' || it == '\t' }
    val missingPadding = (4 - source.length % 4) % 4
    return source + "=".repeat(missingPadding)
}

internal fun String.withLegacyBase64Flags(flags: Int): String {
    var encoded = this
    if ((flags and LEGACY_BASE64_URL_SAFE) != 0) {
        encoded = encoded.replace('+', '-').replace('/', '_')
    }
    if ((flags and LEGACY_BASE64_NO_PADDING) != 0) {
        encoded = encoded.trimEnd('=')
    }
    return encoded
}

internal fun String.toLegacyByteArray(): ByteArray {
    return try {
        Json.parseToJsonElement(this).jsonArray.mapNotNull { element ->
            element.jsonPrimitive.intOrNull?.and(0xff)?.toByte()
        }.toByteArray()
    } catch (_: Exception) {
        ByteArray(0)
    }
}

internal fun String.decodeLegacyHexBytes(): ByteArray {
    val source = trim()
    require(source.length % 2 == 0)
    return ByteArray(source.length / 2) { index ->
        val offset = index * 2
        val high = source[offset].digitToInt(16)
        val low = source[offset + 1].digitToInt(16)
        ((high shl 4) or low).toByte()
    }
}
