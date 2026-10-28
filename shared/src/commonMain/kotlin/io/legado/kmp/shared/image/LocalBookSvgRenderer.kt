package io.legado.kmp.shared.image

/**
 * Rasterizes sanitized, self-contained UTF-8 SVG from a local EPUB/MOBI resource to PNG.
 * Not a sanitizer or a renderer for remote images, HTML, or arbitrary book documents.
 * Throws on unsupported dimensions, unavailable rendering, timeout, or cancellation.
 */
internal expect suspend fun renderLocalBookSvg(bytes: ByteArray): ByteArray
