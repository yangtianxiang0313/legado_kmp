package io.legado.kmp.shared.network

import io.legado.kmp.shared.source.IosSourceStateCipher
import platform.Foundation.NSRecursiveLock
import platform.Foundation.NSUserDefaults

private object SourceNetworkStorage {
    val lock = NSRecursiveLock()
    private val defaults = NSUserDefaults.standardUserDefaults
    private const val KEY = "source-network-policy.encrypted.v1"
    private val cipher = IosSourceStateCipher()
    private var cachedEnvelope: String? = null
    private var cachedDocument: String? = null

    fun read(): String? {
        val envelope = defaults.stringForKey(KEY) ?: return null
        if (envelope != cachedEnvelope) {
            cachedDocument = cipher.decrypt(envelope)
            cachedEnvelope = envelope
        }
        return cachedDocument
    }

    fun update(operation: (String?) -> String) {
        val document = operation(read())
        require(document.length <= 1_048_576) { "Too many source network settings" }
        val envelope = cipher.encrypt(document)
        defaults.setObject(envelope, forKey = KEY)
        cachedEnvelope = envelope
        cachedDocument = document
    }
}

internal actual fun readSourceNetworkDocument(): String? {
    SourceNetworkStorage.lock.lock()
    return try { SourceNetworkStorage.read() } finally { SourceNetworkStorage.lock.unlock() }
}

internal actual fun updateSourceNetworkDocument(update: (String?) -> String) {
    SourceNetworkStorage.lock.lock()
    try { SourceNetworkStorage.update(update) } finally { SourceNetworkStorage.lock.unlock() }
}
