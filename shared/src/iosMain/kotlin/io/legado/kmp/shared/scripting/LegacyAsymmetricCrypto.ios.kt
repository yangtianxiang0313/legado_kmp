@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.legado.kmp.shared.scripting

import platform.CoreFoundation.CFDataRef
import platform.CoreFoundation.CFDataCreate
import platform.CoreFoundation.CFDictionaryRef
import platform.CoreFoundation.CFStringRef
import platform.Foundation.NSData
import platform.Foundation.NSMutableDictionary
import platform.Foundation.NSNumber
import platform.Foundation.NSString
import platform.Foundation.getBytes
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.reinterpret
import kotlinx.cinterop.usePinned
import platform.Security.SecKeyCopyPublicKey
import platform.Security.SecKeyCreateDecryptedData
import platform.Security.SecKeyCreateEncryptedData
import platform.Security.SecKeyCreateSignature
import platform.Security.SecKeyCreateWithData
import platform.Security.SecKeyIsAlgorithmSupported
import platform.Security.SecKeyRef
import platform.Security.SecKeyVerifySignature
import platform.Security.kSecAttrKeyClass
import platform.Security.kSecAttrKeyClassPrivate
import platform.Security.kSecAttrKeyClassPublic
import platform.Security.kSecAttrKeySizeInBits
import platform.Security.kSecAttrKeyType
import platform.Security.kSecAttrKeyTypeECSECPrimeRandom
import platform.Security.kSecAttrKeyTypeRSA
import platform.Security.kSecKeyAlgorithmECDSASignatureMessageX962SHA1
import platform.Security.kSecKeyAlgorithmECDSASignatureMessageX962SHA224
import platform.Security.kSecKeyAlgorithmECDSASignatureMessageX962SHA256
import platform.Security.kSecKeyAlgorithmECDSASignatureMessageX962SHA384
import platform.Security.kSecKeyAlgorithmECDSASignatureMessageX962SHA512
import platform.Security.kSecKeyAlgorithmRSAEncryptionOAEPSHA1
import platform.Security.kSecKeyAlgorithmRSAEncryptionOAEPSHA224
import platform.Security.kSecKeyAlgorithmRSAEncryptionOAEPSHA256
import platform.Security.kSecKeyAlgorithmRSAEncryptionOAEPSHA384
import platform.Security.kSecKeyAlgorithmRSAEncryptionOAEPSHA512
import platform.Security.kSecKeyAlgorithmRSAEncryptionPKCS1
import platform.Security.kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA1
import platform.Security.kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA224
import platform.Security.kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256
import platform.Security.kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA384
import platform.Security.kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA512
import platform.Security.kSecKeyAlgorithmRSASignatureMessagePSSSHA1
import platform.Security.kSecKeyAlgorithmRSASignatureMessagePSSSHA224
import platform.Security.kSecKeyAlgorithmRSASignatureMessagePSSSHA256
import platform.Security.kSecKeyAlgorithmRSASignatureMessagePSSSHA384
import platform.Security.kSecKeyAlgorithmRSASignatureMessagePSSSHA512
import platform.Security.kSecKeyOperationTypeDecrypt
import platform.Security.kSecKeyOperationTypeEncrypt
import platform.Security.kSecKeyOperationTypeSign
import platform.Security.kSecKeyOperationTypeVerify

internal actual object LegacyAsymmetricCrypto {
    actual fun encrypt(
        transformation: String,
        publicKey: ByteArray?,
        privateKey: ByteArray?,
        usePublicKey: Boolean,
        data: ByteArray
    ): ByteArray {
        val algorithm = resolveCipherAlgorithm(transformation)
        val key = loadCipherKey(
            transformation = transformation,
            publicKey = publicKey,
            privateKey = privateKey,
            usePublicKey = usePublicKey
        )
        require(SecKeyIsAlgorithmSupported(key, kSecKeyOperationTypeEncrypt, algorithm)) {
            "Legacy asymmetric crypto encrypt is not supported on iOS for transformation=$transformation"
        }
        val payload = SecKeyCreateEncryptedData(key, algorithm, data.toCFData(), null)
            ?: error("Legacy asymmetric crypto encrypt failed on iOS: transformation=$transformation")
        return payload.toByteArray()
    }

    actual fun decrypt(
        transformation: String,
        publicKey: ByteArray?,
        privateKey: ByteArray?,
        usePublicKey: Boolean,
        data: ByteArray
    ): ByteArray {
        val algorithm = resolveCipherAlgorithm(transformation)
        val key = loadCipherKey(
            transformation = transformation,
            publicKey = publicKey,
            privateKey = privateKey,
            usePublicKey = usePublicKey
        )
        require(SecKeyIsAlgorithmSupported(key, kSecKeyOperationTypeDecrypt, algorithm)) {
            "Legacy asymmetric crypto decrypt is not supported on iOS for transformation=$transformation"
        }
        val payload = SecKeyCreateDecryptedData(key, algorithm, data.toCFData(), null)
            ?: error("Legacy asymmetric crypto decrypt failed on iOS: transformation=$transformation")
        return payload.toByteArray()
    }

    actual fun sign(
        algorithm: String,
        publicKey: ByteArray?,
        privateKey: ByteArray?,
        data: ByteArray
    ): ByteArray {
        val securityAlgorithm = resolveSignatureAlgorithm(algorithm)
        val key = loadPrivateKey(
            algorithm = resolveSignatureKeyAlgorithm(algorithm),
            encoded = requireNotNull(privateKey) {
                "Legacy JS sign helper requires a private key"
            }
        )
        require(SecKeyIsAlgorithmSupported(key, kSecKeyOperationTypeSign, securityAlgorithm)) {
            "Legacy sign helper is not supported on iOS for algorithm=$algorithm"
        }
        val payload = SecKeyCreateSignature(key, securityAlgorithm, data.toCFData(), null)
            ?: error("Legacy sign helper failed on iOS: algorithm=$algorithm")
        return payload.toByteArray()
    }

    actual fun verify(
        algorithm: String,
        publicKey: ByteArray?,
        privateKey: ByteArray?,
        data: ByteArray,
        signature: ByteArray
    ): Boolean {
        val securityAlgorithm = resolveSignatureAlgorithm(algorithm)
        val keyAlgorithm = resolveSignatureKeyAlgorithm(algorithm)
        val verifier = when {
            publicKey != null -> loadPublicKey(keyAlgorithm, publicKey)
            privateKey != null -> SecKeyCopyPublicKey(loadPrivateKey(keyAlgorithm, privateKey))
            else -> error("Legacy JS sign helper requires a public key for verification")
        }
        require(SecKeyIsAlgorithmSupported(verifier, kSecKeyOperationTypeVerify, securityAlgorithm)) {
            "Legacy sign verify helper is not supported on iOS for algorithm=$algorithm"
        }
        return SecKeyVerifySignature(
            verifier,
            securityAlgorithm,
            data.toCFData(),
            signature.toCFData(),
            null
        )
    }
}

private fun loadCipherKey(
    transformation: String,
    publicKey: ByteArray?,
    privateKey: ByteArray?,
    usePublicKey: Boolean
): SecKeyRef {
    val keyAlgorithm = resolveCipherKeyAlgorithm(transformation)
    return if (usePublicKey) {
        loadPublicKey(
            algorithm = keyAlgorithm,
            encoded = requireNotNull(publicKey) {
                "Legacy JS asymmetric helper requires a public key"
            }
        )
    } else {
        loadPrivateKey(
            algorithm = keyAlgorithm,
            encoded = requireNotNull(privateKey) {
                "Legacy JS asymmetric helper requires a private key"
            }
        )
    }
}

private fun loadPublicKey(algorithm: String, encoded: ByteArray): SecKeyRef {
    val decoded = encoded.decodeLegacyKeyMaterial()
    val attributes = keyAttributes(
        keyType = resolveSecurityKeyType(algorithm),
        keyClass = kSecAttrKeyClassPublic,
        keySizeBits = decoded.size * 8
    )
    return SecKeyCreateWithData(decoded.toCFData(), attributes, null)
        ?: error("Failed to load legacy public key on iOS for algorithm=$algorithm")
}

private fun loadPrivateKey(algorithm: String, encoded: ByteArray): SecKeyRef {
    val decoded = encoded.decodeLegacyKeyMaterial()
    val attributes = keyAttributes(
        keyType = resolveSecurityKeyType(algorithm),
        keyClass = kSecAttrKeyClassPrivate,
        keySizeBits = decoded.size * 8
    )
    return SecKeyCreateWithData(decoded.toCFData(), attributes, null)
        ?: error("Failed to load legacy private key on iOS for algorithm=$algorithm")
}

private fun keyAttributes(
    keyType: CFStringRef?,
    keyClass: CFStringRef?,
    keySizeBits: Int
): CFDictionaryRef? {
    val attributes = NSMutableDictionary()
    attributes.setObject(keyType, forKey = kSecAttrKeyType as NSString)
    attributes.setObject(keyClass, forKey = kSecAttrKeyClass as NSString)
    attributes.setObject(NSNumber(integer = keySizeBits.toLong()), forKey = kSecAttrKeySizeInBits as NSString)
    return attributes as CFDictionaryRef?
}

private fun resolveCipherAlgorithm(transformation: String): CFStringRef? {
    val upper = transformation.trim().uppercase()
    return when {
        upper == "RSA" || "PKCS1PADDING" in upper -> kSecKeyAlgorithmRSAEncryptionPKCS1
        "OAEPWITHSHA-1" in upper || "OAEPSHA1" in upper || "OAEPPADDING" in upper -> kSecKeyAlgorithmRSAEncryptionOAEPSHA1
        "OAEPWITHSHA-224" in upper || "OAEPSHA224" in upper -> kSecKeyAlgorithmRSAEncryptionOAEPSHA224
        "OAEPWITHSHA-256" in upper || "OAEPSHA256" in upper -> kSecKeyAlgorithmRSAEncryptionOAEPSHA256
        "OAEPWITHSHA-384" in upper || "OAEPSHA384" in upper -> kSecKeyAlgorithmRSAEncryptionOAEPSHA384
        "OAEPWITHSHA-512" in upper || "OAEPSHA512" in upper -> kSecKeyAlgorithmRSAEncryptionOAEPSHA512
        else -> error("Legacy asymmetric crypto transformation is not supported on iOS yet: $transformation")
    }
}

private fun resolveSignatureAlgorithm(algorithm: String): CFStringRef? {
    val upper = algorithm.trim().uppercase()
    val isPss = "PSS" in upper
    return when {
        "WITHRSA" in upper || upper == "RSA" -> when {
            "SHA1" in upper -> if (isPss) kSecKeyAlgorithmRSASignatureMessagePSSSHA1 else kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA1
            "SHA224" in upper -> if (isPss) kSecKeyAlgorithmRSASignatureMessagePSSSHA224 else kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA224
            "SHA256" in upper -> if (isPss) kSecKeyAlgorithmRSASignatureMessagePSSSHA256 else kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256
            "SHA384" in upper -> if (isPss) kSecKeyAlgorithmRSASignatureMessagePSSSHA384 else kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA384
            "SHA512" in upper -> if (isPss) kSecKeyAlgorithmRSASignatureMessagePSSSHA512 else kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA512
            else -> error("Legacy sign algorithm is not supported on iOS yet: $algorithm")
        }
        "WITHECDSA" in upper || "ECDSA" in upper || "WITHEC" in upper -> when {
            "SHA1" in upper -> kSecKeyAlgorithmECDSASignatureMessageX962SHA1
            "SHA224" in upper -> kSecKeyAlgorithmECDSASignatureMessageX962SHA224
            "SHA256" in upper -> kSecKeyAlgorithmECDSASignatureMessageX962SHA256
            "SHA384" in upper -> kSecKeyAlgorithmECDSASignatureMessageX962SHA384
            "SHA512" in upper -> kSecKeyAlgorithmECDSASignatureMessageX962SHA512
            else -> error("Legacy sign algorithm is not supported on iOS yet: $algorithm")
        }
        else -> error("Legacy sign algorithm is not supported on iOS yet: $algorithm")
    }
}

private fun resolveCipherKeyAlgorithm(transformation: String): String {
    val algorithm = transformation.substringBefore('/').trim().uppercase()
    return normalizeKeyAlgorithm(algorithm)
}

private fun resolveSignatureKeyAlgorithm(algorithm: String): String {
    val upper = algorithm.trim().uppercase()
    val keyAlgorithm = upper.substringAfterLast("WITH", upper)
    return normalizeKeyAlgorithm(keyAlgorithm.substringBefore('/'))
}

private fun normalizeKeyAlgorithm(value: String): String {
    return when (value.trim().uppercase()) {
        "ECDSA", "EC" -> "EC"
        "RSA", "RSA/PSS", "RSASSA-PSS" -> "RSA"
        else -> value.trim().uppercase()
    }
}

private fun resolveSecurityKeyType(algorithm: String): CFStringRef? {
    return when (normalizeKeyAlgorithm(algorithm)) {
        "RSA" -> kSecAttrKeyTypeRSA
        "EC" -> kSecAttrKeyTypeECSECPrimeRandom
        else -> error("Legacy asymmetric key type is not supported on iOS yet: $algorithm")
    }
}

private fun ByteArray.toNSData(): NSData {
    if (isEmpty()) return NSData()
    return usePinned { pinned ->
        CFDataCreate(null, pinned.addressOf(0).reinterpret(), size.toLong()) as NSData
    }
}

private fun ByteArray.toCFData(): CFDataRef? = toNSData() as CFDataRef?

private fun CFDataRef.toByteArray(): ByteArray = (this as NSData).toByteArray()

private fun NSData.toByteArray(): ByteArray {
    val count = length.toInt()
    if (count == 0) return ByteArray(0)
    val output = ByteArray(count)
    output.usePinned { pinned ->
        getBytes(pinned.addressOf(0), length)
    }
    return output
}
