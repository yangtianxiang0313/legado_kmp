package io.legado.kmp.shared.scripting

internal class LegacyJavaRsaKey(
    val kind: String,
    val pkcs1: ByteArray,
    val encoded: ByteArray,
    val modulus: ByteArray,
    val keySizeBits: Int,
) {
    val blockSize: Int get() = modulus.size

    fun containsRepresentative(bytes: ByteArray): Boolean =
        bytes.size == blockSize && compareUnsigned(bytes, modulus) < 0
}

// A finite RSA-only DER grammar: no BER, attributes, multi-prime keys, or generic ASN.1 recursion.
internal fun legacyJavaRsaReadKey(kind: String, encoded: ByteArray): LegacyJavaRsaKey {
    require(kind == "public" || kind == "private") { "Invalid Java RSA key kind" }
    require(encoded.size in 1..65536) { INVALID_RSA_DER }
    val document = RsaDerReader(encoded)
    val container = RsaDerReader(document.read(0x30))
    document.requireEnd()
    val privateKey = kind == "private"
    if (privateKey) container.readVersion()
    require(container.read(0x30).contentEquals(RSA_ALGORITHM_CONTENT)) { INVALID_RSA_DER }
    val pkcs1 = if (privateKey) {
        container.read(0x04)
    } else {
        val bitString = container.read(0x03)
        require(bitString.size > 1 && bitString[0] == 0.toByte()) { INVALID_RSA_DER }
        bitString.copyOfRange(1, bitString.size)
    }
    container.requireEnd()

    val rsaDocument = RsaDerReader(pkcs1)
    val rsa = RsaDerReader(rsaDocument.read(0x30))
    rsaDocument.requireEnd()
    if (privateKey) rsa.readVersion()
    val modulus = rsa.readPositiveInteger()
    val exponent = rsa.readPositiveInteger()
    val leadingBits = Int.SIZE_BITS - (modulus[0].toInt() and 0xff).countLeadingZeroBits()
    val bits = (modulus.size - 1) * 8 + leadingBits
    require(bits in 512..16384 && (modulus.last().toInt() and 1) == 1) { INVALID_RSA_DER }
    require((exponent.last().toInt() and 1) == 1 && greaterThanOne(exponent)) { INVALID_RSA_DER }
    require(compareUnsigned(exponent, modulus) < 0) { INVALID_RSA_DER }
    if (privateKey) {
        val privateExponent = rsa.readPositiveInteger()
        val prime1 = rsa.readPositiveInteger()
        val prime2 = rsa.readPositiveInteger()
        val exponent1 = rsa.readPositiveInteger()
        val exponent2 = rsa.readPositiveInteger()
        val coefficient = rsa.readPositiveInteger()
        require(greaterThanOne(privateExponent) && compareUnsigned(privateExponent, modulus) < 0) { INVALID_RSA_DER }
        require(greaterThanOne(prime1) && greaterThanOne(prime2)) { INVALID_RSA_DER }
        require((prime1.last().toInt() and 1) == 1 && (prime2.last().toInt() and 1) == 1) { INVALID_RSA_DER }
        require(!prime1.contentEquals(prime2)) { INVALID_RSA_DER }
        require(compareUnsigned(prime1, modulus) < 0 && compareUnsigned(prime2, modulus) < 0) { INVALID_RSA_DER }
        require(compareUnsigned(exponent1, prime1) < 0 && compareUnsigned(exponent2, prime2) < 0) { INVALID_RSA_DER }
        require(compareUnsigned(coefficient, prime1) < 0) { INVALID_RSA_DER }
    }
    rsa.requireEnd()

    val algorithm = rsaDer(0x30, RSA_ALGORITHM_CONTENT)
    val canonical = if (privateKey) {
        rsaDer(0x30, byteArrayOf(0x02, 0x01, 0x00) + algorithm + rsaDer(0x04, pkcs1))
    } else {
        rsaDer(0x30, algorithm + rsaDer(0x03, byteArrayOf(0) + pkcs1))
    }
    return LegacyJavaRsaKey(kind, pkcs1, canonical, modulus, bits)
}

private const val INVALID_RSA_DER = "InvalidKeySpecException: invalid or unsupported Java RSA DER key"

// rsaEncryption (1.2.840.113549.1.1.1), with the required explicit NULL parameters.
private val RSA_ALGORITHM_CONTENT = byteArrayOf(
    0x06, 0x09, 0x2a, 0x86.toByte(), 0x48, 0x86.toByte(), 0xf7.toByte(), 0x0d,
    0x01, 0x01, 0x01, 0x05, 0x00,
)

private class RsaDerReader(private val bytes: ByteArray) {
    private var position = 0

    fun read(tag: Int): ByteArray {
        require(octet() == tag) { INVALID_RSA_DER }
        val first = octet()
        val length = if (first < 0x80) {
            first
        } else {
            val count = first and 0x7f
            require(count in 1..3) { INVALID_RSA_DER }
            var value = 0
            repeat(count) { index ->
                val next = octet()
                require(index != 0 || next != 0) { INVALID_RSA_DER }
                value = (value shl 8) or next
            }
            require(value >= 0x80) { INVALID_RSA_DER }
            value
        }
        require(length <= bytes.size - position) { INVALID_RSA_DER }
        return bytes.copyOfRange(position, position + length).also { position += length }
    }

    fun readVersion() {
        val version = read(0x02)
        require(version.size == 1 && version[0] == 0.toByte()) { INVALID_RSA_DER }
    }

    fun readPositiveInteger(): ByteArray {
        val integer = read(0x02)
        require(integer.isNotEmpty() && integer[0].toInt() >= 0) { INVALID_RSA_DER }
        if (integer[0] == 0.toByte()) {
            require(integer.size > 1 && integer[1].toInt() < 0) { INVALID_RSA_DER }
            return integer.copyOfRange(1, integer.size)
        }
        return integer
    }

    fun requireEnd() {
        require(position == bytes.size) { INVALID_RSA_DER }
    }

    private fun octet(): Int {
        require(position < bytes.size) { INVALID_RSA_DER }
        return bytes[position++].toInt() and 0xff
    }
}

private fun rsaDer(tag: Int, contents: ByteArray): ByteArray {
    val size = contents.size
    val length = when {
        size < 0x80 -> byteArrayOf(size.toByte())
        size <= 0xff -> byteArrayOf(0x81.toByte(), size.toByte())
        size <= 0xffff -> byteArrayOf(0x82.toByte(), (size ushr 8).toByte(), size.toByte())
        else -> throw IllegalArgumentException(INVALID_RSA_DER)
    }
    return byteArrayOf(tag.toByte()) + length + contents
}

private fun greaterThanOne(bytes: ByteArray): Boolean = bytes.size > 1 || (bytes[0].toInt() and 0xff) > 1

private fun compareUnsigned(first: ByteArray, second: ByteArray): Int {
    if (first.size != second.size) return first.size.compareTo(second.size)
    for (index in first.indices) {
        val comparison = (first[index].toInt() and 0xff).compareTo(second[index].toInt() and 0xff)
        if (comparison != 0) return comparison
    }
    return 0
}
