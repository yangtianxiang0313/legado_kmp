package io.legado.kmp.shared.facade

import io.legado.kmp.shared.scripting.LegacySymmetricCrypto
import io.legado.kmp.shared.util.md5Hex
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi

/** Android BackupAES compatibility only; this legacy format is not authenticated encryption. */
@OptIn(ExperimentalEncodingApi::class)
internal object AndroidBackupCipher {
    const val CONTRACT = "AndroidBackupAES/MD5-16/AES-ECB-PKCS5Padding"
    private const val TRANSFORMATION = "AES/ECB/PKCS5Padding"

    fun encrypt(text: String, password: String): String {
        val key = password.md5Hex().take(16).encodeToByteArray()
        val plain = text.encodeToByteArray()
        return try {
            Base64.encode(LegacySymmetricCrypto.encrypt(TRANSFORMATION, key, null, plain))
        } finally {
            key.fill(0)
            plain.fill(0)
        }
    }

    fun decrypt(text: String, password: String): String {
        val cipher = Base64.decode(text.trim().replace("\n", "").replace("\r", ""))
        require(cipher.isNotEmpty() && cipher.size % 16 == 0) { "Invalid Android backup ciphertext" }
        // BackupAES uses the first 16 ASCII bytes of the lowercase MD5, not the raw MD5 bytes.
        val key = password.md5Hex().take(16).encodeToByteArray()
        return try {
            val plain = LegacySymmetricCrypto.decrypt(TRANSFORMATION, key, null, cipher)
            try {
                plain.decodeToString(throwOnInvalidSequence = true)
            } finally {
                plain.fill(0)
            }
        } finally {
            key.fill(0)
        }
    }
}
