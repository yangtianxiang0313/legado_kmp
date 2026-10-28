package io.legado.kmp.shared.scripting

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.intOrNull
import okio.ByteString.Companion.toByteString

internal fun randomUUID(): String {
    val bytes = ByteArray(16)
    val random = kotlin.random.Random
    for (i in bytes.indices) {
        bytes[i] = random.nextInt(256).toByte()
    }
    // Set version 4
    bytes[6] = ((bytes[6].toInt() and 0x0f) or 0x40).toByte()
    // Set variant
    bytes[8] = ((bytes[8].toInt() and 0x3f) or 0x80).toByte()
    val hex = bytes.joinToString("") { (it.toInt() and 0xff).toString(16).padStart(2, '0') }
    return "${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20, 32)}"
}

internal fun legacyDigest(data: String, algorithm: String): ByteArray {
    return legacyDigestBytes(data.encodeToByteArray(), algorithm.normalizedLegacyHashAlgorithm())
}

internal fun legacyHmac(data: String, algorithm: String, key: String): ByteArray {
    return legacyHmacBytes(data.encodeToByteArray(), algorithm, key.encodeToByteArray())
}

internal fun legacyHmacBytes(data: ByteArray, algorithm: String, key: ByteArray): ByteArray {
    val normalized = algorithm.normalizedLegacyHashAlgorithm()
    val blockSize = when (normalized) {
        "MD5", "SHA1", "SHA256" -> 64
        "SHA512" -> 128
        else -> throw IllegalArgumentException("Unsupported HMAC algorithm: $algorithm")
    }
    val keyBytes = if (key.size > blockSize) legacyDigestBytes(key, normalized) else key
    val paddedKey = ByteArray(blockSize)
    keyBytes.copyInto(paddedKey, endIndex = keyBytes.size.coerceAtMost(blockSize))
    val outerKeyPad = ByteArray(blockSize)
    val innerKeyPad = ByteArray(blockSize)
    for (index in 0 until blockSize) {
        outerKeyPad[index] = (paddedKey[index].toInt() xor 0x5c).toByte()
        innerKeyPad[index] = (paddedKey[index].toInt() xor 0x36).toByte()
    }
    val inner = legacyDigestBytes(innerKeyPad + data, normalized)
    return legacyDigestBytes(outerKeyPad + inner, normalized)
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
