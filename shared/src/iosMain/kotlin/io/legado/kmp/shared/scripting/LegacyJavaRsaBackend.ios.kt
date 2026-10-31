@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.legado.kmp.shared.scripting

import kotlinx.cinterop.IntVar
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.alloc
import kotlinx.cinterop.allocArrayOf
import kotlinx.cinterop.convert
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.ptr
import kotlinx.cinterop.readBytes
import kotlinx.cinterop.reinterpret
import kotlinx.cinterop.usePinned
import kotlinx.cinterop.value
import platform.CoreFoundation.CFDataCreate
import platform.CoreFoundation.CFDataGetBytePtr
import platform.CoreFoundation.CFDataGetLength
import platform.CoreFoundation.CFDataRef
import platform.CoreFoundation.CFDictionaryCreate
import platform.CoreFoundation.CFNumberCreate
import platform.CoreFoundation.CFRelease
import platform.CoreFoundation.CFStringRef
import platform.CoreFoundation.CFTypeRef
import platform.CoreFoundation.kCFNumberIntType
import platform.Security.SecKeyCreateDecryptedData
import platform.Security.SecKeyCreateEncryptedData
import platform.Security.SecKeyCreateSignature
import platform.Security.SecKeyCreateWithData
import platform.Security.SecKeyGetBlockSize
import platform.Security.SecKeyIsAlgorithmSupported
import platform.Security.SecKeyOperationType
import platform.Security.SecKeyRef
import platform.Security.SecKeyVerifySignature
import platform.Security.kSecAttrKeyClass
import platform.Security.kSecAttrKeyClassPrivate
import platform.Security.kSecAttrKeyClassPublic
import platform.Security.kSecAttrKeySizeInBits
import platform.Security.kSecAttrKeyType
import platform.Security.kSecAttrKeyTypeRSA
import platform.Security.kSecKeyAlgorithmRSAEncryptionPKCS1
import platform.Security.kSecKeyAlgorithmRSAEncryptionRaw
import platform.Security.kSecKeyAlgorithmRSASignatureDigestPKCS1v15Raw
import platform.Security.kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA1
import platform.Security.kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA224
import platform.Security.kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256
import platform.Security.kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA384
import platform.Security.kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA512
import platform.Security.kSecKeyOperationTypeDecrypt
import platform.Security.kSecKeyOperationTypeEncrypt
import platform.Security.kSecKeyOperationTypeSign
import platform.Security.kSecKeyOperationTypeVerify

internal actual object LegacyJavaRsaBackend {
    actual fun validate(key: LegacyJavaRsaKey) {
        withRsaKey(key) { Unit }
    }

    actual fun cipher(mode: Int, key: LegacyJavaRsaKey, data: ByteArray): ByteArray = withRsaKey(key) { nativeKey ->
        require(mode == 1 || mode == 2) { "Unsupported Java RSA Cipher opmode" }
        if (mode == 1) {
            require(data.size <= key.blockSize - 11) { "IllegalBlockSizeException: Java RSA plaintext is too long" }
        } else {
            require(data.size == key.blockSize) { "IllegalBlockSizeException: invalid Java RSA ciphertext length" }
            require(key.containsRepresentative(data)) { BAD_RSA_PADDING }
        }
        when {
            mode == 1 && key.kind == "public" -> {
                requireRsaAlgorithm(nativeKey, kSecKeyOperationTypeEncrypt, kSecKeyAlgorithmRSAEncryptionPKCS1)
                withRsaData(data) { input ->
                    copyOwnedRsaData(
                        SecKeyCreateEncryptedData(nativeKey, kSecKeyAlgorithmRSAEncryptionPKCS1, input, null),
                        "Java RSA public-key encryption failed",
                    )
                }
            }
            mode == 2 && key.kind == "private" -> {
                requireRsaAlgorithm(nativeKey, kSecKeyOperationTypeDecrypt, kSecKeyAlgorithmRSAEncryptionPKCS1)
                withRsaData(data) { input ->
                    copyOwnedRsaData(
                        SecKeyCreateDecryptedData(nativeKey, kSecKeyAlgorithmRSAEncryptionPKCS1, input, null),
                        BAD_RSA_PADDING,
                    )
                }
            }
            mode == 1 -> {
                // Java's private-key Cipher operation is type-1 padding, not a message signature.
                requireRsaAlgorithm(nativeKey, kSecKeyOperationTypeSign, kSecKeyAlgorithmRSASignatureDigestPKCS1v15Raw)
                withRsaData(data) { input ->
                    copyOwnedRsaData(
                        SecKeyCreateSignature(nativeKey, kSecKeyAlgorithmRSASignatureDigestPKCS1v15Raw, input, null),
                        "Java RSA private-key encryption failed",
                    )
                }
            }
            else -> {
                // Only recover a Java type-1 block; raw RSA is never exposed as a Cipher mode.
                requireRsaAlgorithm(nativeKey, kSecKeyOperationTypeEncrypt, kSecKeyAlgorithmRSAEncryptionRaw)
                val recovered = withRsaData(data) { input ->
                    copyOwnedRsaData(
                        SecKeyCreateEncryptedData(nativeKey, kSecKeyAlgorithmRSAEncryptionRaw, input, null),
                        BAD_RSA_PADDING,
                    )
                }
                try {
                    unpadRsaTypeOne(recovered, key.blockSize)
                } finally {
                    recovered.fill(0)
                }
            }
        }
    }

    actual fun sign(
        algorithm: LegacyJavaRsaSignatureAlgorithm,
        key: LegacyJavaRsaKey,
        data: ByteArray,
    ): ByteArray {
        require(key.kind == "private") { "InvalidKeyException: Java RSA signing requires a private key" }
        return withRsaKey(key) { nativeKey ->
            val securityAlgorithm = algorithm.securityAlgorithm()
            requireRsaAlgorithm(nativeKey, kSecKeyOperationTypeSign, securityAlgorithm)
            withRsaData(data) { input ->
                copyOwnedRsaData(
                    SecKeyCreateSignature(nativeKey, securityAlgorithm, input, null),
                    "SignatureException: Java RSA signing failed",
                )
            }
        }
    }

    actual fun verify(
        algorithm: LegacyJavaRsaSignatureAlgorithm,
        key: LegacyJavaRsaKey,
        data: ByteArray,
        signature: ByteArray,
    ): Boolean {
        require(key.kind == "public") { "InvalidKeyException: Java RSA verification requires a public key" }
        return withRsaKey(key) { nativeKey ->
            val securityAlgorithm = algorithm.securityAlgorithm()
            requireRsaAlgorithm(nativeKey, kSecKeyOperationTypeVerify, securityAlgorithm)
            if (!key.containsRepresentative(signature)) return@withRsaKey false
            withRsaData(data) { input ->
                withRsaData(signature) { signatureData ->
                    // No CFError is requested: mismatches return false without exposing diagnostics or input.
                    SecKeyVerifySignature(nativeKey, securityAlgorithm, input, signatureData, null)
                }
            }
        }
    }
}

private const val BAD_RSA_PADDING = "BadPaddingException: invalid Java RSA ciphertext or PKCS1Padding"

private fun LegacyJavaRsaSignatureAlgorithm.securityAlgorithm(): CFStringRef? = when (this) {
    LegacyJavaRsaSignatureAlgorithm.SHA1 -> kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA1
    LegacyJavaRsaSignatureAlgorithm.SHA224 -> kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA224
    LegacyJavaRsaSignatureAlgorithm.SHA256 -> kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256
    LegacyJavaRsaSignatureAlgorithm.SHA384 -> kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA384
    LegacyJavaRsaSignatureAlgorithm.SHA512 -> kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA512
}

private fun requireRsaAlgorithm(key: SecKeyRef, operation: SecKeyOperationType, algorithm: CFStringRef?) {
    require(SecKeyIsAlgorithmSupported(key, operation, algorithm)) {
        "InvalidKeyException: Java RSA operation is not supported by this Security key"
    }
}

private fun unpadRsaTypeOne(block: ByteArray, blockSize: Int): ByteArray {
    require(block.size == blockSize && block.size >= 11) { BAD_RSA_PADDING }
    require(block[0] == 0.toByte() && block[1] == 1.toByte()) { BAD_RSA_PADDING }
    var separator = 2
    while (separator < block.size && block[separator] == 0xff.toByte()) separator++
    require(separator >= 10 && separator < block.size && block[separator] == 0.toByte()) { BAD_RSA_PADDING }
    return block.copyOfRange(separator + 1, block.size)
}

private fun <T> withRsaKey(material: LegacyJavaRsaKey, action: (SecKeyRef) -> T): T =
    withRsaData(material.pkcs1) { encoded ->
        memScoped {
            require(material.kind == "public" || material.kind == "private") { "Invalid Java RSA key kind" }
            val bits = alloc<IntVar>()
            bits.value = material.keySizeBits
            val size = checkNotNull(CFNumberCreate(null, kCFNumberIntType, bits.ptr)) {
                "Cannot allocate Java RSA key size"
            }
            try {
                val attributes: List<Pair<CFStringRef?, CFTypeRef?>> = listOf(
                    kSecAttrKeyType to kSecAttrKeyTypeRSA,
                    kSecAttrKeyClass to if (material.kind == "public") kSecAttrKeyClassPublic else kSecAttrKeyClassPrivate,
                    kSecAttrKeySizeInBits to size,
                )
                val keys = allocArrayOf(*attributes.map { it.first }.toTypedArray())
                val values = allocArrayOf(*attributes.map { it.second }.toTypedArray())
                // Borrowed values remain alive until the dictionary and the synchronous import are finished.
                val dictionary = checkNotNull(
                    CFDictionaryCreate(null, keys.reinterpret(), values.reinterpret(), attributes.size.convert(), null, null)
                ) { "Cannot allocate Java RSA key attributes" }
                try {
                    val key = SecKeyCreateWithData(encoded, dictionary, null)
                        ?: throw IllegalArgumentException("InvalidKeyException: Security rejected the Java RSA key")
                    try {
                        require(SecKeyGetBlockSize(key).toLong() == material.blockSize.toLong()) {
                            "InvalidKeyException: Java RSA modulus size does not match the Security key"
                        }
                        action(key)
                    } finally {
                        CFRelease(key)
                    }
                } finally {
                    CFRelease(dictionary)
                }
            } finally {
                CFRelease(size)
            }
        }
    }

private fun <T> withRsaData(bytes: ByteArray, action: (CFDataRef) -> T): T {
    val data = checkNotNull(
        if (bytes.isEmpty()) {
            CFDataCreate(null, null, 0)
        } else {
            bytes.usePinned { pinned ->
                CFDataCreate(null, pinned.addressOf(0).reinterpret(), bytes.size.convert())
            }
        }
    ) { "Cannot allocate Java RSA data" }
    try {
        return action(data)
    } finally {
        CFRelease(data)
    }
}

private fun copyOwnedRsaData(data: CFDataRef?, failure: String): ByteArray {
    requireNotNull(data) { failure }
    try {
        val length = CFDataGetLength(data)
        check(length >= 0 && length <= Int.MAX_VALUE.toLong()) { "Invalid Java RSA native output length" }
        if (length == 0L) return ByteArray(0)
        val pointer = checkNotNull(CFDataGetBytePtr(data)) { "Invalid Java RSA native output buffer" }
        return pointer.readBytes(length.toInt())
    } finally {
        CFRelease(data)
    }
}
