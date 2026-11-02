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
    bindLegacyJavaRsaHost(json)
    function("__legacyJavaCipherConfig") { args ->
        require(args.size == 1) { "Unsupported Java Cipher config host arguments" }
        val transformation = args[0] as? String
            ?: throw IllegalArgumentException("Expected a Java Cipher transformation")
        json.encodeToString(LegacyJavaCipherSupport.config(transformation))
    }
    function("__legacyJavaCipherInit") { args ->
        require(args.size == 4) { "Unsupported Java Cipher init host arguments" }
        val transformation = args[0] as? String
            ?: throw IllegalArgumentException("Expected a Java Cipher transformation")
        val opmode = legacyJavaCipherOperation(args[1])
        val key = args[2] as? String
            ?: throw IllegalArgumentException("Expected a Java Cipher key byte array")
        require(args[3] == null || args[3] is String) { "Expected a Java Cipher IV byte array or null" }
        json.encodeToString(LegacyJavaCipherSupport.init(transformation, opmode, key, args[3] as? String))
    }
    function("__legacyJavaCipherProcess") { args ->
        require(args.size == 5) { "Unsupported Java Cipher process host arguments" }
        val transformation = args[0] as? String
            ?: throw IllegalArgumentException("Expected a Java Cipher transformation")
        val opmode = legacyJavaCipherOperation(args[1])
        val key = args[2] as? String
            ?: throw IllegalArgumentException("Expected a Java Cipher key byte array")
        require(args[3] == null || args[3] is String) { "Expected a Java Cipher IV byte array or null" }
        val data = args[4] as? String
            ?: throw IllegalArgumentException("Expected a Java Cipher input byte array")
        LegacyJavaCipherSupport.process(transformation, opmode, key, args[3] as? String, data)
    }
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
        json.legacyCryptoText(args.firstOrNull()).orEmpty().md5Hex()
    }
    function("__legacyMd5Encode16") { args ->
        json.legacyCryptoText(args.firstOrNull()).orEmpty().md5Hex().substring(8, 24)
    }
    function("__legacyDigestHex") { args ->
        runCatching {
            legacyDigest(
                data = json.legacyCryptoText(args.firstOrNull()).orEmpty(),
                algorithm = json.legacyCryptoText(args.getOrNull(1)).orEmpty()
            ).encodeHex()
        }.getOrDefault("")
    }
    function("__legacyDigestBase64") { args ->
        runCatching {
            @OptIn(ExperimentalEncodingApi::class)
            Base64.encode(
                legacyDigest(
                    data = json.legacyCryptoText(args.firstOrNull()).orEmpty(),
                    algorithm = json.legacyCryptoText(args.getOrNull(1)).orEmpty()
                )
            )
        }.getOrDefault("")
    }
    function("__legacyHMacHex") { args ->
        runCatching {
            legacyHmac(
                data = json.legacyCryptoText(args.firstOrNull()).orEmpty(),
                algorithm = json.legacyCryptoText(args.getOrNull(1)).orEmpty(),
                key = json.legacyCryptoText(args.getOrNull(2)).orEmpty()
            ).encodeHex()
        }.getOrDefault("")
    }
    function("__legacyHMacBase64") { args ->
        runCatching {
            @OptIn(ExperimentalEncodingApi::class)
            Base64.encode(
                legacyHmac(
                    data = json.legacyCryptoText(args.firstOrNull()).orEmpty(),
                    algorithm = json.legacyCryptoText(args.getOrNull(1)).orEmpty(),
                    key = json.legacyCryptoText(args.getOrNull(2)).orEmpty()
                )
            )
        }.getOrDefault("")
    }
    function("__legacySymmetricEncryptBase64") { args ->
        val transformation = json.legacyCryptoText(args.firstOrNull()).orEmpty()
        val key = json.legacyCryptoKey(args.getOrNull(1), nullTextIsAbsent = false)
        val iv = json.legacyCryptoKey(args.getOrNull(2))
        val data = json.legacyCryptoText(args.getOrNull(3)).orEmpty().encodeToByteArray()
        @OptIn(ExperimentalEncodingApi::class)
        Base64.encode(LegacySymmetricCrypto.encrypt(transformation, key, iv, data))
    }
    function("__legacySymmetricEncrypt") { args ->
        val transformation = json.legacyCryptoText(args.firstOrNull()).orEmpty()
        val key = json.legacyCryptoKey(args.getOrNull(1), nullTextIsAbsent = false)
        val iv = json.legacyCryptoKey(args.getOrNull(2))
        val data = json.legacyCryptoText(args.getOrNull(3)).orEmpty().toLegacyCryptoTextInput()
        json.encodeToString(LegacySymmetricCrypto.encrypt(transformation, key, iv, data).toJsonElement())
    }
    function("__legacySymmetricEncryptHex") { args ->
        val transformation = json.legacyCryptoText(args.firstOrNull()).orEmpty()
        val key = json.legacyCryptoKey(args.getOrNull(1), nullTextIsAbsent = false)
        val iv = json.legacyCryptoKey(args.getOrNull(2))
        val data = json.legacyCryptoText(args.getOrNull(3)).orEmpty().encodeToByteArray()
        LegacySymmetricCrypto.encrypt(transformation, key, iv, data).encodeHex()
    }
    function("__legacySymmetricDecrypt") { args ->
        val transformation = json.legacyCryptoText(args.firstOrNull()).orEmpty()
        val key = json.legacyCryptoKey(args.getOrNull(1), nullTextIsAbsent = false)
        val iv = json.legacyCryptoKey(args.getOrNull(2))
        val data = json.legacyCryptoText(args.getOrNull(3)).orEmpty().toLegacyCryptoBinaryInput()
        json.encodeToString(LegacySymmetricCrypto.decrypt(transformation, key, iv, data).toJsonElement())
    }
    function("__legacySymmetricDecryptStr") { args ->
        val transformation = json.legacyCryptoText(args.firstOrNull()).orEmpty()
        val key = json.legacyCryptoKey(args.getOrNull(1), nullTextIsAbsent = false)
        val iv = json.legacyCryptoKey(args.getOrNull(2))
        val data = json.legacyCryptoText(args.getOrNull(3)).orEmpty().decodeLegacyCipherInput()
        json.encodeToString(LegacySymmetricCrypto.decrypt(transformation, key, iv, data).decodeToString())
    }
    function("__legacyAsymmetricEncrypt") { args ->
        val transformation = json.legacyCryptoText(args.firstOrNull()).orEmpty()
        val publicKey = json.legacyCryptoKey(args.getOrNull(1))
        val privateKey = json.legacyCryptoKey(args.getOrNull(2))
        val usePublicKey = args.getOrNull(3)?.toString()?.toBooleanStrictOrNull() ?: true
        val data = json.legacyCryptoText(args.getOrNull(4)).orEmpty().toLegacyCryptoTextInput()
        json.encodeToString(LegacyAsymmetricCrypto.encrypt(transformation, publicKey, privateKey, usePublicKey, data).toJsonElement())
    }
    function("__legacyAsymmetricEncryptBase64") { args ->
        val transformation = json.legacyCryptoText(args.firstOrNull()).orEmpty()
        val publicKey = json.legacyCryptoKey(args.getOrNull(1))
        val privateKey = json.legacyCryptoKey(args.getOrNull(2))
        val usePublicKey = args.getOrNull(3)?.toString()?.toBooleanStrictOrNull() ?: true
        val data = json.legacyCryptoText(args.getOrNull(4)).orEmpty().toLegacyCryptoTextInput()
        @OptIn(ExperimentalEncodingApi::class)
        Base64.encode(LegacyAsymmetricCrypto.encrypt(transformation, publicKey, privateKey, usePublicKey, data))
    }
    function("__legacyAsymmetricEncryptHex") { args ->
        val transformation = json.legacyCryptoText(args.firstOrNull()).orEmpty()
        val publicKey = json.legacyCryptoKey(args.getOrNull(1))
        val privateKey = json.legacyCryptoKey(args.getOrNull(2))
        val usePublicKey = args.getOrNull(3)?.toString()?.toBooleanStrictOrNull() ?: true
        val data = json.legacyCryptoText(args.getOrNull(4)).orEmpty().toLegacyCryptoTextInput()
        LegacyAsymmetricCrypto.encrypt(transformation, publicKey, privateKey, usePublicKey, data).encodeHex()
    }
    function("__legacyAsymmetricDecrypt") { args ->
        val transformation = json.legacyCryptoText(args.firstOrNull()).orEmpty()
        val publicKey = json.legacyCryptoKey(args.getOrNull(1))
        val privateKey = json.legacyCryptoKey(args.getOrNull(2))
        val usePublicKey = args.getOrNull(3)?.toString()?.toBooleanStrictOrNull() ?: true
        val data = json.legacyCryptoText(args.getOrNull(4)).orEmpty().toLegacyCryptoBinaryInput()
        json.encodeToString(LegacyAsymmetricCrypto.decrypt(transformation, publicKey, privateKey, usePublicKey, data).toJsonElement())
    }
    function("__legacyAsymmetricDecryptStr") { args ->
        val transformation = json.legacyCryptoText(args.firstOrNull()).orEmpty()
        val publicKey = json.legacyCryptoKey(args.getOrNull(1))
        val privateKey = json.legacyCryptoKey(args.getOrNull(2))
        val usePublicKey = args.getOrNull(3)?.toString()?.toBooleanStrictOrNull() ?: true
        val data = json.legacyCryptoText(args.getOrNull(4)).orEmpty().toLegacyCryptoBinaryInput()
        json.encodeToString(LegacyAsymmetricCrypto.decrypt(transformation, publicKey, privateKey, usePublicKey, data).decodeToString())
    }
    function("__legacySign") { args ->
        val algorithm = json.legacyCryptoText(args.firstOrNull()).orEmpty()
        val publicKey = json.legacyCryptoKey(args.getOrNull(1))
        val privateKey = json.legacyCryptoKey(args.getOrNull(2))
        val data = json.legacyCryptoText(args.getOrNull(3)).orEmpty().toLegacyCryptoTextInput()
        json.encodeToString(LegacyAsymmetricCrypto.sign(algorithm, publicKey, privateKey, data).toJsonElement())
    }
    function("__legacySignHex") { args ->
        val algorithm = json.legacyCryptoText(args.firstOrNull()).orEmpty()
        val publicKey = json.legacyCryptoKey(args.getOrNull(1))
        val privateKey = json.legacyCryptoKey(args.getOrNull(2))
        val data = json.legacyCryptoText(args.getOrNull(3)).orEmpty().toLegacyCryptoTextInput()
        LegacyAsymmetricCrypto.sign(algorithm, publicKey, privateKey, data).encodeHex()
    }
    function("__legacyVerifySign") { args ->
        val algorithm = json.legacyCryptoText(args.firstOrNull()).orEmpty()
        val publicKey = json.legacyCryptoKey(args.getOrNull(1))
        val privateKey = json.legacyCryptoKey(args.getOrNull(2))
        val data = json.legacyCryptoText(args.getOrNull(3)).orEmpty().toLegacyCryptoTextInput()
        val signature = json.legacyCryptoText(args.getOrNull(4)).orEmpty().toLegacyCryptoBinaryInput()
        LegacyAsymmetricCrypto.verify(algorithm, publicKey, privateKey, data, signature)
    }
}

// JSON escaping protects text from the native bridge's NUL-terminated string conversion.
private fun Json.legacyCryptoText(value: Any?): String? =
    value?.toString()?.let { decodeFromString<String>(it) }

private fun Json.legacyCryptoKey(value: Any?, nullTextIsAbsent: Boolean = true): ByteArray? =
    legacyCryptoText(value)
        ?.takeUnless { nullTextIsAbsent && (it == "undefined" || it == "null") }
        ?.toLegacyCryptoKeyBytes()

private fun legacyJavaCipherOperation(value: Any?): Int {
    val number = (value as? Number)?.toDouble()
        ?: throw IllegalArgumentException("Expected a Java Cipher numeric opmode")
    require(number == 1.0 || number == 2.0) { "Unsupported Java Cipher opmode; expected 1 or 2" }
    return number.toInt()
}
