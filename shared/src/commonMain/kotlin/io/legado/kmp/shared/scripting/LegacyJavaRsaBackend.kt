package io.legado.kmp.shared.scripting

internal enum class LegacyJavaRsaSignatureAlgorithm(val digestInfoSize: Int) {
    SHA1(35),
    SHA224(47),
    SHA256(51),
    SHA384(67),
    SHA512(83),
}

internal expect object LegacyJavaRsaBackend {
    fun validate(key: LegacyJavaRsaKey)

    fun cipher(mode: Int, key: LegacyJavaRsaKey, data: ByteArray): ByteArray

    fun sign(algorithm: LegacyJavaRsaSignatureAlgorithm, key: LegacyJavaRsaKey, data: ByteArray): ByteArray

    fun verify(
        algorithm: LegacyJavaRsaSignatureAlgorithm,
        key: LegacyJavaRsaKey,
        data: ByteArray,
        signature: ByteArray,
    ): Boolean
}
