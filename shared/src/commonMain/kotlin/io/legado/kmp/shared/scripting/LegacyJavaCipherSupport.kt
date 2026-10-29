package io.legado.kmp.shared.scripting

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

internal expect fun javaCipherRandomBytes(size: Int): ByteArray

/** Stateless support for the symmetric Java Cipher subset exposed by the source shim. */
internal object LegacyJavaCipherSupport {
    fun config(transformation: String): JsonObject = parseJavaCipherConfig(transformation).toJson()

    fun init(
        transformation: String,
        opmode: Int,
        keyJson: String,
        ivJson: String?,
    ): JsonObject {
        val config = parseJavaCipherConfig(transformation)
        val parameters = javaCipherParameters(config, opmode, keyJson, ivJson, generateIv = true)
        return JsonObject(config.toJson() + ("iv" to parameters.iv.toJsonElement()))
    }

    fun process(
        transformation: String,
        opmode: Int,
        keyJson: String,
        ivJson: String?,
        dataJson: String,
    ): List<Int> {
        val config = parseJavaCipherConfig(transformation)
        val parameters = javaCipherParameters(config, opmode, keyJson, ivJson, generateIv = false)
        val data = javaCipherBytes(dataJson, "input")
        if (config.padding == "NoPadding" || opmode == 2) {
            require(data.size % config.blockSize == 0) {
                "IllegalBlockSizeException: Java Cipher input must contain complete blocks"
            }
        }
        if (opmode == 2 && data.isEmpty()) {
            require(config.algorithm != "DES" || config.padding == "NoPadding") {
                "IllegalBlockSizeException: DES padded decryption requires a complete block"
            }
            return emptyList()
        }
        val result = try {
            if (opmode == 1) {
                LegacySymmetricCrypto.encrypt(config.transformation, parameters.key, parameters.iv, data)
            } else {
                LegacySymmetricCrypto.decrypt(config.transformation, parameters.key, parameters.iv, data)
            }
        } catch (_: Exception) {
            val message = when {
                opmode == 1 -> "Java Cipher encryption failed"
                config.padding == "NoPadding" -> "Java Cipher decryption failed"
                else -> "BadPaddingException: Java Cipher decryption failed (invalid ciphertext or padding)"
            }
            throw IllegalArgumentException(message)
        }
        return result.map { it.toInt() and 0xff }
    }
}

private data class JavaCipherConfig(
    val algorithm: String,
    val mode: String,
    val padding: String,
    val blockSize: Int,
) {
    val transformation: String get() = "$algorithm/$mode/$padding"

    fun toJson(): JsonObject = buildJsonObject {
        put("algorithm", algorithm)
        put("mode", mode)
        put("padding", padding)
        put("blockSize", blockSize)
    }
}

private fun parseJavaCipherConfig(transformation: String): JavaCipherConfig {
    val parts = transformation.split('/').map(String::trim)
    require((parts.size == 1 || parts.size == 3) && parts.none(String::isEmpty)) {
        "Invalid Java Cipher transformation; expected an algorithm or algorithm/mode/padding"
    }
    val algorithm = when (parts[0].uppercase()) {
        "AES" -> "AES"
        "DES" -> "DES"
        "DESEDE" -> "DESede"
        else -> throw IllegalArgumentException("Unsupported Java Cipher algorithm; expected AES, DES or DESede")
    }
    val mode = when (parts.getOrNull(1)?.uppercase() ?: "ECB") {
        "CBC" -> "CBC"
        "ECB" -> "ECB"
        else -> throw IllegalArgumentException("Unsupported Java Cipher mode; expected CBC or ECB")
    }
    val padding = when (parts.getOrNull(2)?.uppercase() ?: "PKCS5PADDING") {
        "PKCS5PADDING" -> "PKCS5Padding"
        "PKCS7PADDING" -> "PKCS7Padding"
        "NOPADDING" -> "NoPadding"
        else -> throw IllegalArgumentException("Unsupported Java Cipher padding; expected PKCS5Padding, PKCS7Padding or NoPadding")
    }
    return JavaCipherConfig(algorithm, mode, padding, if (algorithm == "AES") 16 else 8)
}

private data class JavaCipherParameters(val key: ByteArray, val iv: ByteArray?)

private fun javaCipherParameters(
    config: JavaCipherConfig,
    opmode: Int,
    keyJson: String,
    ivJson: String?,
    generateIv: Boolean,
): JavaCipherParameters {
    require(opmode == 1 || opmode == 2) { "Unsupported Java Cipher opmode; expected 1 or 2" }
    val key = javaCipherBytes(keyJson, "key")
    val validKey = when (config.algorithm) {
        "AES" -> key.size == 16 || key.size == 24 || key.size == 32
        "DES" -> key.size == 8
        "DESede" -> key.size == 24
        else -> false
    }
    require(validKey) { "InvalidKeyException: invalid Java Cipher key length" }
    val iv = ivJson?.let { javaCipherBytes(it, "IV") }
    if (config.mode == "ECB") {
        require(iv == null) { "InvalidAlgorithmParameterException: Java Cipher ECB does not accept an IV" }
        return JavaCipherParameters(key, null)
    }
    if (iv != null) {
        require(iv.size == config.blockSize) {
            "InvalidAlgorithmParameterException: Java Cipher CBC IV must match the block size"
        }
        return JavaCipherParameters(key, iv)
    }
    require(generateIv && opmode == 1) {
        "InvalidAlgorithmParameterException: Java Cipher CBC requires an explicit IV"
    }
    return JavaCipherParameters(key, javaCipherRandomBytes(config.blockSize))
}

private fun javaCipherBytes(serialized: String, name: String): ByteArray = try {
    legacyJavaCryptoBytes(serialized)
} catch (_: Exception) {
    // JSON decoder diagnostics can include the input, including secret key material.
    throw IllegalArgumentException("Invalid Java Cipher $name byte array")
}
