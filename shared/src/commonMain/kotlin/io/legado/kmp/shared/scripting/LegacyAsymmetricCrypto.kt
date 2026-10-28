package io.legado.kmp.shared.scripting

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive

internal expect object LegacyAsymmetricCrypto {
    fun encrypt(
        transformation: String,
        publicKey: ByteArray?,
        privateKey: ByteArray?,
        usePublicKey: Boolean,
        data: ByteArray
    ): ByteArray

    fun decrypt(
        transformation: String,
        publicKey: ByteArray?,
        privateKey: ByteArray?,
        usePublicKey: Boolean,
        data: ByteArray
    ): ByteArray

    fun sign(
        algorithm: String,
        publicKey: ByteArray?,
        privateKey: ByteArray?,
        data: ByteArray
    ): ByteArray

    fun verify(
        algorithm: String,
        publicKey: ByteArray?,
        privateKey: ByteArray?,
        data: ByteArray,
        signature: ByteArray
    ): Boolean
}

internal fun String.toLegacyCryptoTextInput(): ByteArray {
    decodeLegacyJsByteArrayLiteral()?.let { return it }
    return encodeToByteArray()
}

internal fun String.toLegacyCryptoBinaryInput(): ByteArray {
    decodeLegacyJsByteArrayLiteral()?.let { return it }
    return decodeLegacyCipherInput()
}

internal fun ByteArray.decodeLegacyKeyMaterial(): ByteArray {
    val text = runCatching { decodeToString() }.getOrNull()?.trim().orEmpty()
    if (text.isBlank()) return this
    if ("-----BEGIN" in text && "-----END" in text) {
        val payload = text
            .lineSequence()
            .map(String::trim)
            .filter { line ->
                line.isNotBlank() &&
                    !line.startsWith("-----BEGIN") &&
                    !line.startsWith("-----END")
            }
            .joinToString(separator = "")
        if (payload.isNotBlank()) {
            return payload.decodeLegacyCipherInput()
        }
    }
    return text.decodeLegacyCipherInput()
}

internal fun String.decodeLegacyJsByteArrayLiteral(): ByteArray? {
    val trimmed = trim()
    if (!trimmed.startsWith("[") || !trimmed.endsWith("]")) return null
    val parsed = runCatching {
        Json.parseToJsonElement(trimmed)
    }.getOrNull() ?: return null
    val array = parsed as? JsonArray ?: return null
    return array.map { element ->
        element.jsonPrimitive.intOrNull?.toByte() ?: return null
    }.toByteArray()
}
