package io.legado.kmp.shared.scripting

import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi

internal expect object LegacySymmetricCrypto {
    fun encrypt(
        transformation: String,
        key: ByteArray?,
        iv: ByteArray?,
        data: ByteArray
    ): ByteArray

    fun decrypt(
        transformation: String,
        key: ByteArray?,
        iv: ByteArray?,
        data: ByteArray
    ): ByteArray
}

internal fun String.toLegacyCryptoKeyBytes(): ByteArray {
    decodeLegacyJsByteArrayLiteral()?.let { return it }
    return encodeToByteArray()
}

@OptIn(ExperimentalEncodingApi::class)
internal fun String.decodeLegacyCipherInput(): ByteArray {
    val trimmed = trim()
    if (trimmed.isEmpty()) return ByteArray(0)
    if (trimmed.length % 2 == 0 && trimmed.all { it.isDigit() || it.lowercaseChar() in 'a'..'f' }) {
        return trimmed.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    }
    val normalizedBase64 = trimmed.replace("\n", "").replace("\r", "")
    runCatching {
        return Base64.decode(normalizedBase64)
    }
    return trimmed.encodeToByteArray()
}

internal fun ByteArray.encodeHex(): String = joinToString(separator = "") { byte ->
    byte.toInt().and(0xff).toString(16).padStart(2, '0')
}
