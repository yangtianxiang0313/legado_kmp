package io.legado.kmp.shared.platform

internal expect fun platformHmac(data: ByteArray, algorithm: String, key: ByteArray): ByteArray
