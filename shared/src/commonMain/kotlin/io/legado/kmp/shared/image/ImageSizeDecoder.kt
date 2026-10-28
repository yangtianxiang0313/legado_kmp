package io.legado.kmp.shared.image

/**
 * Platform abstraction for decoding image dimensions without fully decoding pixel data.
 *
 * On Android: uses BitmapFactory.Options(inJustDecodeBounds = true)
 * On iOS: uses CGImageSource / UIImage to read dimensions
 *
 * This is an interface rather than expect/actual because it's injected via DI.
 */
interface ImageSizeDecoder {

    /**
     * Decode image dimensions from raw bytes.
     * Returns null if the format is unrecognized or the data is corrupt.
     *
     * Implementations should handle:
     * - Standard bitmap formats (JPEG, PNG, GIF, WEBP, BMP)
     * - SVG (parse width/height from root element)
     */
    fun decodeSize(data: ByteArray): ImageSize?

    /**
     * Decode image dimensions from a file path.
     * Returns null if the file doesn't exist or format is unrecognized.
     */
    suspend fun decodeSizeFromPath(path: String): ImageSize?
}
