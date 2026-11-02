package io.legado.kmp.shared.scripting

import io.legado.kmp.shared.platform.platformHmac
import io.legado.kmp.shared.platform.platformRandomUUID
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.intOrNull
import okio.ByteString.Companion.toByteString

internal fun randomUUID(): String = platformRandomUUID()

internal fun legacyDigest(data: String, algorithm: String): ByteArray {
    return legacyDigestBytes(data.encodeToByteArray(), algorithm.normalizedLegacyHashAlgorithm())
}

internal fun legacyHmac(data: String, algorithm: String, key: String): ByteArray {
    return legacyHmacBytes(data.encodeToByteArray(), algorithm, key.encodeToByteArray())
}

internal fun legacyHmacBytes(data: ByteArray, algorithm: String, key: ByteArray): ByteArray {
    val normalized = algorithm.normalizedLegacyHashAlgorithm()
    require(normalized in setOf("MD5", "SHA1", "SHA256", "SHA512")) {
        "Unsupported HMAC algorithm: $algorithm"
    }
    return platformHmac(data, normalized, key)
}

// The Java shim first validates/copies through byteArray; do not decode these bytes as text.
internal fun legacyJavaCryptoBytes(serialized: String): ByteArray {
    val values = Json.parseToJsonElement(serialized) as? JsonArray
        ?: throw IllegalArgumentException("Expected a Java crypto byte array")
    return ByteArray(values.size) { index ->
        val value = values[index] as? JsonPrimitive
        require(value != null && !value.isString) { "Expected an integer Java crypto byte" }
        val byte = value.intOrNull
        require(byte != null && byte in -128..255) { "Invalid Java crypto byte" }
        byte.toByte()
    }
}

private fun legacyDigestBytes(data: ByteArray, normalizedAlgorithm: String): ByteArray {
    val bytes = data.toByteString()
    return when (normalizedAlgorithm) {
        "MD5" -> bytes.md5()
        "SHA1" -> bytes.sha1()
        "SHA256" -> bytes.sha256()
        "SHA512" -> bytes.sha512()
        else -> throw IllegalArgumentException("Unsupported digest algorithm: $normalizedAlgorithm")
    }.toByteArray()
}

private fun String.normalizedLegacyHashAlgorithm(): String {
    return uppercase()
        .replace("-", "")
        .replace("_", "")
        .replace("/", "")
        .replace(" ", "")
        .removePrefix("HMAC")
}
