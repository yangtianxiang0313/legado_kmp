package io.legado.kmp.shared.scripting

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** All *Json arguments are JSON byte arrays, never key descriptors or encoded text. */
internal object LegacyJavaRsaSupport {
    fun key(kind: String, encodedJson: String): JsonObject {
        val material = readKey(kind, encodedJson)
        LegacyJavaRsaBackend.validate(material)
        return buildJsonObject {
            put("kind", material.kind)
            put("algorithm", "RSA")
            put("format", if (material.kind == "public") "X.509" else "PKCS#8")
            put("encoded", JsonArray(material.encoded.map { JsonPrimitive(it.toInt() and 0xff) }))
            put("blockSize", material.blockSize)
        }
    }

    fun cipher(mode: Int, kind: String, keyJson: String, dataJson: String): List<Int> {
        require(mode == 1 || mode == 2) { "Unsupported Java RSA Cipher opmode; expected 1 or 2" }
        val material = readKey(kind, keyJson)
        val data = readBytes(dataJson)
        if (mode == 1) {
            require(data.size <= material.blockSize - 11) {
                "IllegalBlockSizeException: Java RSA plaintext exceeds one PKCS1Padding block"
            }
        } else {
            require(data.size == material.blockSize) {
                "IllegalBlockSizeException: Java RSA ciphertext must be exactly one modulus-sized block"
            }
            require(material.containsRepresentative(data)) {
                "BadPaddingException: invalid Java RSA ciphertext"
            }
        }
        val result = LegacyJavaRsaBackend.cipher(mode, material, data)
        check(if (mode == 1) result.size == material.blockSize else result.size <= material.blockSize - 11) {
            "Java RSA Cipher returned an invalid block length"
        }
        return result.unsignedList()
    }

    fun sign(algorithm: String, keyJson: String, dataJson: String): List<Int> {
        val signatureAlgorithm = signatureAlgorithm(algorithm)
        val material = readKey("private", keyJson)
        requireSignatureCapacity(material, signatureAlgorithm)
        val signature = LegacyJavaRsaBackend.sign(signatureAlgorithm, material, readBytes(dataJson))
        check(signature.size == material.blockSize) { "Java RSA signature has an invalid block length" }
        return signature.unsignedList()
    }

    fun verify(
        algorithm: String,
        kind: String,
        keyJson: String,
        dataJson: String,
        signatureJson: String,
    ): Boolean {
        val signatureAlgorithm = signatureAlgorithm(algorithm)
        require(kind == "public") { "InvalidKeyException: Java RSA verification requires a public key" }
        val material = readKey(kind, keyJson)
        requireSignatureCapacity(material, signatureAlgorithm)
        val data = readBytes(dataJson)
        val signature = readBytes(signatureJson)
        // Import even for malformed signatures: invalid keys must not masquerade as signature mismatches.
        return LegacyJavaRsaBackend.verify(signatureAlgorithm, material, data, signature)
    }

    private fun readKey(kind: String, encodedJson: String): LegacyJavaRsaKey {
        require(kind == "public" || kind == "private") { "Invalid Java RSA key kind; expected public or private" }
        return legacyJavaRsaReadKey(kind, readBytes(encodedJson))
    }

    private fun readBytes(serialized: String): ByteArray = try {
        legacyJavaCryptoBytes(serialized)
    } catch (_: Exception) {
        // JSON decoder diagnostics may contain secret input; do not preserve the cause.
        throw IllegalArgumentException("Invalid Java RSA byte array")
    }

    private fun signatureAlgorithm(algorithm: String): LegacyJavaRsaSignatureAlgorithm =
        when (algorithm.uppercase()) {
            "SHA1WITHRSA" -> LegacyJavaRsaSignatureAlgorithm.SHA1
            "SHA224WITHRSA" -> LegacyJavaRsaSignatureAlgorithm.SHA224
            "SHA256WITHRSA" -> LegacyJavaRsaSignatureAlgorithm.SHA256
            "SHA384WITHRSA" -> LegacyJavaRsaSignatureAlgorithm.SHA384
            "SHA512WITHRSA" -> LegacyJavaRsaSignatureAlgorithm.SHA512
            else -> throw IllegalArgumentException("Unsupported Java RSA signature algorithm")
        }

    private fun requireSignatureCapacity(key: LegacyJavaRsaKey, algorithm: LegacyJavaRsaSignatureAlgorithm) {
        require(key.blockSize >= algorithm.digestInfoSize + 11) {
            "InvalidKeyException: Java RSA modulus is too small for the signature algorithm"
        }
    }

    private fun ByteArray.unsignedList(): List<Int> = map { it.toInt() and 0xff }
}
