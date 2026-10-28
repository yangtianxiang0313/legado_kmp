package io.legado.kmp.shared.scripting

import com.dokar.quickjs.QuickJs
import com.dokar.quickjs.binding.function
import io.legado.kmp.shared.util.md5Hex
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi

/** Registration-only companion; the crypto implementations remain in their existing helpers. */
internal suspend fun QuickJs.bindLegacyCryptoHost(json: Json) {
    function("__legacyJavaHmacBytes") { args ->
        require(args.size == 3) { "Unsupported Java HMAC host arguments" }
        val algorithm = args[0] as? String
            ?: throw IllegalArgumentException("Expected a Java HMAC algorithm")
        val key = args[1] as? String
            ?: throw IllegalArgumentException("Expected a Java HMAC key byte array")
        val data = args[2] as? String
            ?: throw IllegalArgumentException("Expected a Java HMAC input byte array")
        legacyHmacBytes(legacyJavaCryptoBytes(data), algorithm, legacyJavaCryptoBytes(key))
    }
    function("__legacyMd5Encode") { args ->
        args.firstOrNull()?.toString().orEmpty().md5Hex()
    }
    function("__legacyMd5Encode16") { args ->
        args.firstOrNull()?.toString().orEmpty().md5Hex().substring(8, 24)
    }
    function("__legacyDigestHex") { args ->
        runCatching {
            legacyDigest(
                data = args.firstOrNull()?.toString().orEmpty(),
                algorithm = args.getOrNull(1)?.toString().orEmpty()
            ).encodeHex()
        }.getOrDefault("")
    }
    function("__legacyDigestBase64") { args ->
        runCatching {
            @OptIn(ExperimentalEncodingApi::class)
            Base64.encode(
                legacyDigest(
                    data = args.firstOrNull()?.toString().orEmpty(),
                    algorithm = args.getOrNull(1)?.toString().orEmpty()
                )
            )
        }.getOrDefault("")
    }
    function("__legacyHMacHex") { args ->
        runCatching {
            legacyHmac(
                data = args.firstOrNull()?.toString().orEmpty(),
                algorithm = args.getOrNull(1)?.toString().orEmpty(),
                key = args.getOrNull(2)?.toString().orEmpty()
            ).encodeHex()
        }.getOrDefault("")
    }
    function("__legacyHMacBase64") { args ->
        runCatching {
            @OptIn(ExperimentalEncodingApi::class)
            Base64.encode(
                legacyHmac(
                    data = args.firstOrNull()?.toString().orEmpty(),
                    algorithm = args.getOrNull(1)?.toString().orEmpty(),
                    key = args.getOrNull(2)?.toString().orEmpty()
                )
            )
        }.getOrDefault("")
    }
    function("__legacySymmetricEncryptBase64") { args ->
        val transformation = args.firstOrNull()?.toString().orEmpty()
        val key = args.getOrNull(1)?.toString()?.toLegacyCryptoKeyBytes()
        val iv = args.getOrNull(2)?.toString()?.takeUnless { it == "undefined" || it == "null" }?.toLegacyCryptoKeyBytes()
        val data = args.getOrNull(3)?.toString().orEmpty().encodeToByteArray()
        @OptIn(ExperimentalEncodingApi::class)
        Base64.encode(LegacySymmetricCrypto.encrypt(transformation, key, iv, data))
    }
    function("__legacySymmetricEncrypt") { args ->
        val transformation = args.firstOrNull()?.toString().orEmpty()
        val key = args.getOrNull(1)?.toString()?.toLegacyCryptoKeyBytes()
        val iv = args.getOrNull(2)?.toString()?.takeUnless { it == "undefined" || it == "null" }?.toLegacyCryptoKeyBytes()
        val data = args.getOrNull(3)?.toString().orEmpty().toLegacyCryptoTextInput()
        json.encodeToString(LegacySymmetricCrypto.encrypt(transformation, key, iv, data).toJsonElement())
    }
    function("__legacySymmetricEncryptHex") { args ->
        val transformation = args.firstOrNull()?.toString().orEmpty()
        val key = args.getOrNull(1)?.toString()?.toLegacyCryptoKeyBytes()
        val iv = args.getOrNull(2)?.toString()?.takeUnless { it == "undefined" || it == "null" }?.toLegacyCryptoKeyBytes()
        val data = args.getOrNull(3)?.toString().orEmpty().encodeToByteArray()
        LegacySymmetricCrypto.encrypt(transformation, key, iv, data).encodeHex()
    }
    function("__legacySymmetricDecrypt") { args ->
        val transformation = args.firstOrNull()?.toString().orEmpty()
        val key = args.getOrNull(1)?.toString()?.toLegacyCryptoKeyBytes()
        val iv = args.getOrNull(2)?.toString()?.takeUnless { it == "undefined" || it == "null" }?.toLegacyCryptoKeyBytes()
        val data = args.getOrNull(3)?.toString().orEmpty().toLegacyCryptoBinaryInput()
        json.encodeToString(LegacySymmetricCrypto.decrypt(transformation, key, iv, data).toJsonElement())
    }
    function("__legacySymmetricDecryptStr") { args ->
        val transformation = args.firstOrNull()?.toString().orEmpty()
        val key = args.getOrNull(1)?.toString()?.toLegacyCryptoKeyBytes()
        val iv = args.getOrNull(2)?.toString()?.takeUnless { it == "undefined" || it == "null" }?.toLegacyCryptoKeyBytes()
        val data = args.getOrNull(3)?.toString().orEmpty().decodeLegacyCipherInput()
        LegacySymmetricCrypto.decrypt(transformation, key, iv, data).decodeToString()
    }
    function("__legacyAsymmetricEncrypt") { args ->
        val transformation = args.firstOrNull()?.toString().orEmpty()
        val publicKey = args.getOrNull(1)?.toString()?.takeUnless { it == "undefined" || it == "null" }?.toLegacyCryptoKeyBytes()
        val privateKey = args.getOrNull(2)?.toString()?.takeUnless { it == "undefined" || it == "null" }?.toLegacyCryptoKeyBytes()
        val usePublicKey = args.getOrNull(3)?.toString()?.toBooleanStrictOrNull() ?: true
        val data = args.getOrNull(4)?.toString().orEmpty().toLegacyCryptoTextInput()
        json.encodeToString(LegacyAsymmetricCrypto.encrypt(transformation, publicKey, privateKey, usePublicKey, data).toJsonElement())
    }
    function("__legacyAsymmetricEncryptBase64") { args ->
        val transformation = args.firstOrNull()?.toString().orEmpty()
        val publicKey = args.getOrNull(1)?.toString()?.takeUnless { it == "undefined" || it == "null" }?.toLegacyCryptoKeyBytes()
        val privateKey = args.getOrNull(2)?.toString()?.takeUnless { it == "undefined" || it == "null" }?.toLegacyCryptoKeyBytes()
        val usePublicKey = args.getOrNull(3)?.toString()?.toBooleanStrictOrNull() ?: true
        val data = args.getOrNull(4)?.toString().orEmpty().toLegacyCryptoTextInput()
        @OptIn(ExperimentalEncodingApi::class)
        Base64.encode(LegacyAsymmetricCrypto.encrypt(transformation, publicKey, privateKey, usePublicKey, data))
    }
    function("__legacyAsymmetricEncryptHex") { args ->
        val transformation = args.firstOrNull()?.toString().orEmpty()
        val publicKey = args.getOrNull(1)?.toString()?.takeUnless { it == "undefined" || it == "null" }?.toLegacyCryptoKeyBytes()
        val privateKey = args.getOrNull(2)?.toString()?.takeUnless { it == "undefined" || it == "null" }?.toLegacyCryptoKeyBytes()
        val usePublicKey = args.getOrNull(3)?.toString()?.toBooleanStrictOrNull() ?: true
        val data = args.getOrNull(4)?.toString().orEmpty().toLegacyCryptoTextInput()
        LegacyAsymmetricCrypto.encrypt(transformation, publicKey, privateKey, usePublicKey, data).encodeHex()
    }
    function("__legacyAsymmetricDecrypt") { args ->
        val transformation = args.firstOrNull()?.toString().orEmpty()
        val publicKey = args.getOrNull(1)?.toString()?.takeUnless { it == "undefined" || it == "null" }?.toLegacyCryptoKeyBytes()
        val privateKey = args.getOrNull(2)?.toString()?.takeUnless { it == "undefined" || it == "null" }?.toLegacyCryptoKeyBytes()
        val usePublicKey = args.getOrNull(3)?.toString()?.toBooleanStrictOrNull() ?: true
        val data = args.getOrNull(4)?.toString().orEmpty().toLegacyCryptoBinaryInput()
        json.encodeToString(LegacyAsymmetricCrypto.decrypt(transformation, publicKey, privateKey, usePublicKey, data).toJsonElement())
    }
    function("__legacyAsymmetricDecryptStr") { args ->
        val transformation = args.firstOrNull()?.toString().orEmpty()
        val publicKey = args.getOrNull(1)?.toString()?.takeUnless { it == "undefined" || it == "null" }?.toLegacyCryptoKeyBytes()
        val privateKey = args.getOrNull(2)?.toString()?.takeUnless { it == "undefined" || it == "null" }?.toLegacyCryptoKeyBytes()
        val usePublicKey = args.getOrNull(3)?.toString()?.toBooleanStrictOrNull() ?: true
        val data = args.getOrNull(4)?.toString().orEmpty().toLegacyCryptoBinaryInput()
        LegacyAsymmetricCrypto.decrypt(transformation, publicKey, privateKey, usePublicKey, data).decodeToString()
    }
    function("__legacySign") { args ->
        val algorithm = args.firstOrNull()?.toString().orEmpty()
        val publicKey = args.getOrNull(1)?.toString()?.takeUnless { it == "undefined" || it == "null" }?.toLegacyCryptoKeyBytes()
        val privateKey = args.getOrNull(2)?.toString()?.takeUnless { it == "undefined" || it == "null" }?.toLegacyCryptoKeyBytes()
        val data = args.getOrNull(3)?.toString().orEmpty().toLegacyCryptoTextInput()
        json.encodeToString(LegacyAsymmetricCrypto.sign(algorithm, publicKey, privateKey, data).toJsonElement())
    }
    function("__legacySignHex") { args ->
        val algorithm = args.firstOrNull()?.toString().orEmpty()
        val publicKey = args.getOrNull(1)?.toString()?.takeUnless { it == "undefined" || it == "null" }?.toLegacyCryptoKeyBytes()
        val privateKey = args.getOrNull(2)?.toString()?.takeUnless { it == "undefined" || it == "null" }?.toLegacyCryptoKeyBytes()
        val data = args.getOrNull(3)?.toString().orEmpty().toLegacyCryptoTextInput()
        LegacyAsymmetricCrypto.sign(algorithm, publicKey, privateKey, data).encodeHex()
    }
    function("__legacyVerifySign") { args ->
        val algorithm = args.firstOrNull()?.toString().orEmpty()
        val publicKey = args.getOrNull(1)?.toString()?.takeUnless { it == "undefined" || it == "null" }?.toLegacyCryptoKeyBytes()
        val privateKey = args.getOrNull(2)?.toString()?.takeUnless { it == "undefined" || it == "null" }?.toLegacyCryptoKeyBytes()
        val data = args.getOrNull(3)?.toString().orEmpty().toLegacyCryptoTextInput()
        val signature = args.getOrNull(4)?.toString().orEmpty().toLegacyCryptoBinaryInput()
        LegacyAsymmetricCrypto.verify(algorithm, publicKey, privateKey, data, signature)
    }
}
