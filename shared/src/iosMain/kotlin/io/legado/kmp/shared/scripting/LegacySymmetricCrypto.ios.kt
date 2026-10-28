@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.legado.kmp.shared.scripting

import kotlinx.cinterop.ByteVar
import kotlinx.cinterop.ULongVarOf
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.alloc
import kotlinx.cinterop.allocArray
import kotlinx.cinterop.convert
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.readBytes
import kotlinx.cinterop.usePinned
import platform.CoreCrypto.CCAlgorithm
import platform.CoreCrypto.CCCrypt
import platform.CoreCrypto.CCOperation
import platform.CoreCrypto.CCOptions
import platform.CoreCrypto.kCCAlgorithm3DES
import platform.CoreCrypto.kCCAlgorithmAES
import platform.CoreCrypto.kCCAlgorithmDES
import platform.CoreCrypto.kCCBlockSize3DES
import platform.CoreCrypto.kCCBlockSizeAES128
import platform.CoreCrypto.kCCBlockSizeDES
import platform.CoreCrypto.kCCDecrypt
import platform.CoreCrypto.kCCEncrypt
import platform.CoreCrypto.kCCKeySize3DES
import platform.CoreCrypto.kCCKeySizeAES128
import platform.CoreCrypto.kCCKeySizeDES
import platform.CoreCrypto.kCCOptionECBMode
import platform.CoreCrypto.kCCOptionPKCS7Padding
import platform.CoreCrypto.kCCSuccess
import platform.posix.arc4random_buf

internal actual object LegacySymmetricCrypto {
    actual fun encrypt(
        transformation: String,
        key: ByteArray?,
        iv: ByteArray?,
        data: ByteArray
    ): ByteArray = runCipher(kCCEncrypt, transformation, key, iv, data)

    actual fun decrypt(
        transformation: String,
        key: ByteArray?,
        iv: ByteArray?,
        data: ByteArray
    ): ByteArray = runCipher(kCCDecrypt, transformation, key, iv, data)

    private fun runCipher(
        operation: CCOperation,
        transformation: String,
        key: ByteArray?,
        iv: ByteArray?,
        data: ByteArray
    ): ByteArray {
        val config = parseSymmetricCipherConfig(transformation)
        val actualKey = key ?: randomBytes(config.defaultKeySize)
        val actualIv = if (config.needsIv) {
            iv ?: ByteArray(config.blockSize)
        } else {
            null
        }
        val outputCapacity = data.size + config.blockSize

        return memScoped {
            val output = allocArray<ByteVar>(outputCapacity)
            val outputMoved = ULongArray(1)

            actualKey.usePinned { keyPinned ->
                data.usePinned { dataPinned ->
                    outputMoved.usePinned { outputMovedPinned ->
                        actualIv?.usePinned { ivPinned ->
                            val status = CCCrypt(
                                operation,
                                config.algorithm,
                                config.options,
                                keyPinned.addressOf(0),
                                actualKey.size.convert(),
                                ivPinned.addressOf(0),
                                dataPinned.addressOf(0),
                                data.size.convert(),
                                output,
                                outputCapacity.convert(),
                                outputMovedPinned.addressOf(0)
                            )
                            require(status == kCCSuccess) {
                                "Legacy symmetric crypto failed on iOS: transformation=$transformation status=$status"
                            }
                        } ?: run {
                            val status = CCCrypt(
                                operation,
                                config.algorithm,
                                config.options,
                                keyPinned.addressOf(0),
                                actualKey.size.convert(),
                                null,
                                dataPinned.addressOf(0),
                                data.size.convert(),
                                output,
                                outputCapacity.convert(),
                                outputMovedPinned.addressOf(0)
                            )
                            require(status == kCCSuccess) {
                                "Legacy symmetric crypto failed on iOS: transformation=$transformation status=$status"
                            }
                        }
                    }
                }
            }

            output.readBytes(outputMoved[0].toInt())
        }
    }

    private fun randomBytes(size: Int): ByteArray {
        val bytes = ByteArray(size)
        bytes.usePinned { pinned ->
            arc4random_buf(pinned.addressOf(0), bytes.size.convert())
        }
        return bytes
    }
}

private data class SymmetricCipherConfig(
    val algorithm: CCAlgorithm,
    val options: CCOptions,
    val blockSize: Int,
    val defaultKeySize: Int,
    val needsIv: Boolean,
)

private fun parseSymmetricCipherConfig(transformation: String): SymmetricCipherConfig {
    val parts = transformation.trim().split('/').map(String::trim).filter(String::isNotEmpty)
    require(parts.isNotEmpty()) { "Missing crypto algorithm in transformation: $transformation" }

    val algorithmName = parts[0].uppercase()
    val mode = parts.getOrNull(1)?.uppercase() ?: "ECB"
    val padding = parts.getOrNull(2)?.uppercase() ?: "PKCS7PADDING"

    val (algorithm, blockSize, defaultKeySize) = when (algorithmName) {
        "AES" -> Triple(kCCAlgorithmAES, kCCBlockSizeAES128.toInt(), kCCKeySizeAES128.toInt())
        "DESEDE", "TRIPLEDES", "3DES" -> Triple(kCCAlgorithm3DES, kCCBlockSize3DES.toInt(), kCCKeySize3DES.toInt())
        "DES" -> Triple(kCCAlgorithmDES, kCCBlockSizeDES.toInt(), kCCKeySizeDES.toInt())
        else -> error("Legacy symmetric crypto algorithm is not supported on iOS yet: $algorithmName")
    }

    val normalizedMode = when (mode) {
        "CBC", "ECB" -> mode
        else -> error("Legacy symmetric crypto mode is not supported on iOS yet: $mode")
    }
    val normalizedPadding = when (padding) {
        "PKCS5PADDING", "PKCS7PADDING", "NOPADDING" -> padding
        else -> error("Legacy symmetric crypto padding is not supported on iOS yet: $padding")
    }

    var options = 0
    if (normalizedMode == "ECB") {
        options = options or kCCOptionECBMode.toInt()
    }
    if (normalizedPadding != "NOPADDING") {
        options = options or kCCOptionPKCS7Padding.toInt()
    }

    return SymmetricCipherConfig(
        algorithm = algorithm,
        options = options.convert(),
        blockSize = blockSize,
        defaultKeySize = defaultKeySize,
        needsIv = normalizedMode != "ECB",
    )
}
