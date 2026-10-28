@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.legado.kmp.shared.source

import kotlinx.cinterop.addressOf
import kotlinx.cinterop.convert
import kotlinx.cinterop.usePinned
import platform.CoreCrypto.CCCrypt
import platform.CoreCrypto.CCOperation
import platform.CoreCrypto.kCCAlgorithmAES
import platform.CoreCrypto.kCCDecrypt
import platform.CoreCrypto.kCCEncrypt
import platform.CoreCrypto.kCCOptionPKCS7Padding
import platform.CoreCrypto.kCCSuccess
import platform.posix.timingsafe_bcmp

internal object IosSourceStateCrypto {
    fun encrypt(key: ByteArray, iv: ByteArray, data: ByteArray): ByteArray =
        crypt(kCCEncrypt, key, iv, data)

    fun decrypt(key: ByteArray, iv: ByteArray, data: ByteArray): ByteArray =
        crypt(kCCDecrypt, key, iv, data)

    fun tagsEqual(expected: ByteArray, actual: ByteArray): Boolean {
        require(expected.size == 32 && actual.size == 32)
        return expected.usePinned { expectedPinned ->
            actual.usePinned { actualPinned ->
                timingsafe_bcmp(expectedPinned.addressOf(0), actualPinned.addressOf(0), expected.size.convert()) == 0
            }
        }
    }

    private fun crypt(operation: CCOperation, key: ByteArray, iv: ByteArray, data: ByteArray): ByteArray {
        require(key.size == 32 && iv.size == 16)
        require(data.size <= Int.MAX_VALUE - 16)
        val output = ByteArray(data.size + 16)
        val moved = ULongArray(1)
        // A zero-length message still needs a valid pinned address; CommonCrypto adds the padding.
        val input = if (data.isEmpty()) ByteArray(1) else data
        return try {
            val status = key.usePinned { keyPinned ->
                iv.usePinned { ivPinned ->
                    input.usePinned { inputPinned ->
                        output.usePinned { outputPinned ->
                            moved.usePinned { movedPinned ->
                                CCCrypt(
                                    operation,
                                    kCCAlgorithmAES,
                                    kCCOptionPKCS7Padding.convert(),
                                    keyPinned.addressOf(0),
                                    key.size.convert(),
                                    ivPinned.addressOf(0),
                                    inputPinned.addressOf(0),
                                    data.size.convert(),
                                    outputPinned.addressOf(0),
                                    output.size.convert(),
                                    movedPinned.addressOf(0)
                                )
                            }
                        }
                    }
                }
            }
            check(status == kCCSuccess && moved[0] <= output.size.toULong())
            output.copyOf(moved[0].toInt())
        } finally {
            output.fill(0)
            if (input !== data) input.fill(0)
        }
    }
}
