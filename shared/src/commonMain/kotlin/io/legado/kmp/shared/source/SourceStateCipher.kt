package io.legado.kmp.shared.source

interface SourceStateCipher {
    fun encrypt(plainText: String): String
    fun decrypt(cipherText: String): String

    fun needsMigration(cipherText: String): Boolean = false
}
