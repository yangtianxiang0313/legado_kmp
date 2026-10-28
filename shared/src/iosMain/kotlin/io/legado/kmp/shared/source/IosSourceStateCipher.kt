package io.legado.kmp.shared.source

import okio.ByteString.Companion.toByteString
import platform.Foundation.NSBundle
import kotlin.coroutines.cancellation.CancellationException
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi

@OptIn(ExperimentalEncodingApi::class)
class IosSourceStateCipher : SourceStateCipher {
    override fun encrypt(plainText: String): String = protectFailure {
        withKeys(create = true) { encryptionKey, authenticationKey ->
            val iv = IosSourceStateKeychain.randomBytes(IV_SIZE)
            val plainBytes = plainText.encodeToByteArray()
            try {
                val encrypted = IosSourceStateCrypto.encrypt(encryptionKey, iv, plainBytes)
                val payload = iv + encrypted
                PREFIX + Base64.encode(payload + authenticate(payload, authenticationKey))
            } finally {
                plainBytes.fill(0)
            }
        }
    }

    override fun decrypt(cipherText: String): String = protectFailure {
        if (needsMigration(cipherText)) {
            // Compatibility is read-only and still requires an available, protected Keychain.
            withKeys(create = true) { _, _ -> decryptLegacy(cipherText) }
        } else {
            val envelope = Base64.decode(cipherText.substring(PREFIX.length))
            require(envelope.size >= IV_SIZE + IV_SIZE + TAG_SIZE)
            val payloadSize = envelope.size - TAG_SIZE
            require((payloadSize - IV_SIZE) % IV_SIZE == 0)
            val payload = envelope.copyOfRange(0, payloadSize)
            withKeys(create = false) { encryptionKey, authenticationKey ->
                val expectedTag = authenticate(payload, authenticationKey)
                require(IosSourceStateCrypto.tagsEqual(expectedTag, envelope.copyOfRange(payloadSize, envelope.size)))
                // No AES or padding processing happens before the entire tag is verified.
                val plainBytes = IosSourceStateCrypto.decrypt(
                    encryptionKey,
                    payload.copyOfRange(0, IV_SIZE),
                    payload.copyOfRange(IV_SIZE, payload.size)
                )
                try {
                    plainBytes.decodeToString(throwOnInvalidSequence = true)
                } finally {
                    plainBytes.fill(0)
                }
            }
        }
    }

    override fun needsMigration(cipherText: String): Boolean = !cipherText.startsWith(PREFIX)

    private fun authenticate(payload: ByteArray, key: ByteArray): ByteArray =
        (PREFIX.encodeToByteArray() + payload).toByteString().hmacSha256(key.toByteString()).toByteArray()

    private fun decryptLegacy(cipherText: String): String {
        // Unknown versioned envelopes fail Base64 decoding and never reach the legacy XOR.
        val encoded = Base64.decode(cipherText)
        val bundleId = NSBundle.mainBundle.bundleIdentifier ?: "io.legado.kmp.shared"
        val bundleBytes = bundleId.encodeToByteArray()
        val seed = if (bundleBytes.isEmpty()) "legado-ios".encodeToByteArray() else bundleBytes
        val secret = ByteArray(32) { seed[it % seed.size] }
        val plainBytes = ByteArray(encoded.size) { index ->
            (encoded[index].toInt() xor secret[index % secret.size].toInt()).toByte()
        }
        return try {
            plainBytes.decodeToString(throwOnInvalidSequence = true)
        } finally {
            plainBytes.fill(0)
            secret.fill(0)
        }
    }

    private inline fun <T> withKeys(create: Boolean, block: (ByteArray, ByteArray) -> T): T {
        val secret = IosSourceStateKeychain.load(create)
        val encryptionKey = secret.copyOfRange(0, KEY_SIZE)
        val authenticationKey = secret.copyOfRange(KEY_SIZE, KEY_SIZE * 2)
        return try {
            block(encryptionKey, authenticationKey)
        } finally {
            secret.fill(0)
            encryptionKey.fill(0)
            authenticationKey.fill(0)
        }
    }

    private inline fun <T> protectFailure(block: () -> T): T = try {
        block()
    } catch (error: CancellationException) {
        throw error
    } catch (_: Exception) {
        throw IllegalStateException("Source credential storage unavailable")
    }

    private companion object {
        private const val PREFIX = "legado-source-state:1:"
        private const val KEY_SIZE = 32
        private const val IV_SIZE = 16
        private const val TAG_SIZE = 32
    }
}
