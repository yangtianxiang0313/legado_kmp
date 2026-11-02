@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.legado.kmp.shared.platform

import kotlinx.cinterop.addressOf
import kotlinx.cinterop.convert
import kotlinx.cinterop.usePinned
import platform.CoreCrypto.CCHmac
import platform.CoreCrypto.CC_MD5_DIGEST_LENGTH
import platform.CoreCrypto.CC_SHA1_DIGEST_LENGTH
import platform.CoreCrypto.CC_SHA256_DIGEST_LENGTH
import platform.CoreCrypto.CC_SHA512_DIGEST_LENGTH
import platform.CoreCrypto.kCCHmacAlgMD5
import platform.CoreCrypto.kCCHmacAlgSHA1
import platform.CoreCrypto.kCCHmacAlgSHA256
import platform.CoreCrypto.kCCHmacAlgSHA512

internal actual fun platformHmac(data: ByteArray, algorithm: String, key: ByteArray): ByteArray {
    val (nativeAlgorithm, digestLength) = when (algorithm) {
        "MD5" -> kCCHmacAlgMD5 to CC_MD5_DIGEST_LENGTH
        "SHA1" -> kCCHmacAlgSHA1 to CC_SHA1_DIGEST_LENGTH
        "SHA256" -> kCCHmacAlgSHA256 to CC_SHA256_DIGEST_LENGTH
        "SHA512" -> kCCHmacAlgSHA512 to CC_SHA512_DIGEST_LENGTH
        else -> throw IllegalArgumentException("Unsupported HMAC algorithm: $algorithm")
    }
    val output = ByteArray(digestLength.toInt())
    // Keep valid pinned addresses for empty inputs, while passing their original zero lengths.
    val input = if (data.isEmpty()) ByteArray(1) else data
    val keyInput = if (key.isEmpty()) ByteArray(1) else key
    keyInput.usePinned { keyPinned ->
        input.usePinned { dataPinned ->
            output.usePinned { outputPinned ->
                CCHmac(
                    nativeAlgorithm.convert(),
                    keyPinned.addressOf(0),
                    key.size.convert(),
                    dataPinned.addressOf(0),
                    data.size.convert(),
                    outputPinned.addressOf(0)
                )
            }
        }
    }
    return output
}
