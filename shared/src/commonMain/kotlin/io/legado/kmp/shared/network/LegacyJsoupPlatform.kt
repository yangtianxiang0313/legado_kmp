package io.legado.kmp.shared.network

/** Whether the platform response channel already contains decoded entity bytes. */
internal expect fun legacyJsoupPlatformDecodesContentEncoding(encoding: String): Boolean

internal expect fun legacyJsoupPlatformSupportsCharset(name: String): Boolean
internal expect fun legacyJsoupPlatformEncode(text: String, charset: String, check: () -> Unit): ByteArray
internal expect fun legacyJsoupPlatformDecode(bytes: ByteArray, charset: String, check: () -> Unit): String
