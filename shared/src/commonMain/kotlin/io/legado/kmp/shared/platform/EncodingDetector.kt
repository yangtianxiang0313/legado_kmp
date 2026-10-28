package io.legado.kmp.shared.platform

/**
 * Platform abstraction for character encoding detection
 * Used to detect encoding of text files (important for local book parsing)
 */
expect class EncodingDetector() {

    /**
     * Detect character encoding from byte array
     * @param bytes File content bytes
     * @return Detected charset name (e.g., "UTF-8", "GBK", "BIG5")
     */
    fun detect(bytes: ByteArray): String

    /**
     * Detect encoding and return charset name with confidence
     * @param bytes File content bytes
     * @param hint Optional hint for expected encoding
     * @return Pair of charset name and confidence score (0-1)
     */
    fun detectWithConfidence(bytes: ByteArray, hint: String? = null): Pair<String, Float>

    /**
     * Check if bytes are valid UTF-8
     * @param bytes File content bytes
     * @return true if valid UTF-8
     */
    fun isValidUtf8(bytes: ByteArray): Boolean
}
