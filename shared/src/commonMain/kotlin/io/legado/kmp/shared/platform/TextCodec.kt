package io.legado.kmp.shared.platform

expect object TextCodec {
    fun decode(bytes: ByteArray, charsetName: String): String
    fun encode(text: String, charsetName: String): ByteArray
    fun detectCharset(sample: ByteArray): String
    fun hasUtf8Bom(bytes: ByteArray): Boolean
}

/** CharsetEncoder semantics used by Android's query writer, without String.getBytes fast paths. */
internal expect fun encodeCharsetWriterText(text: String, charsetName: String): ByteArray
