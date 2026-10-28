@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.legado.kmp.shared.source

import kotlinx.cinterop.addressOf
import kotlinx.cinterop.alloc
import kotlinx.cinterop.allocArrayOf
import kotlinx.cinterop.convert
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.ptr
import kotlinx.cinterop.readBytes
import kotlinx.cinterop.reinterpret
import kotlinx.cinterop.usePinned
import kotlinx.cinterop.value
import platform.CoreFoundation.CFDataCreate
import platform.CoreFoundation.CFDataGetBytePtr
import platform.CoreFoundation.CFDataGetLength
import platform.CoreFoundation.CFDataGetTypeID
import platform.CoreFoundation.CFDataRef
import platform.CoreFoundation.CFDictionaryCreate
import platform.CoreFoundation.CFDictionaryGetTypeID
import platform.CoreFoundation.CFDictionaryGetValue
import platform.CoreFoundation.CFDictionaryRef
import platform.CoreFoundation.CFGetTypeID
import platform.CoreFoundation.CFRelease
import platform.CoreFoundation.CFStringRef
import platform.CoreFoundation.CFStringCompare
import platform.CoreFoundation.CFStringGetTypeID
import platform.CoreFoundation.CFTypeRef
import platform.CoreFoundation.CFTypeRefVar
import platform.CoreFoundation.kCFBooleanFalse
import platform.CoreFoundation.kCFBooleanTrue
import platform.CoreFoundation.kCFCompareEqualTo
import platform.Foundation.CFBridgingRetain
import platform.Foundation.NSBundle
import platform.Security.SecItemAdd
import platform.Security.SecItemCopyMatching
import platform.Security.SecRandomCopyBytes
import platform.Security.errSecDuplicateItem
import platform.Security.errSecItemNotFound
import platform.Security.errSecSuccess
import platform.Security.kSecAttrAccessible
import platform.Security.kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
import platform.Security.kSecAttrAccount
import platform.Security.kSecAttrService
import platform.Security.kSecAttrSynchronizable
import platform.Security.kSecClass
import platform.Security.kSecClassGenericPassword
import platform.Security.kSecMatchLimit
import platform.Security.kSecMatchLimitOne
import platform.Security.kSecRandomDefault
import platform.Security.kSecReturnAttributes
import platform.Security.kSecReturnData
import platform.Security.kSecValueData

internal object IosSourceStateKeychain {
    private const val SECRET_SIZE = 64

    fun load(create: Boolean): ByteArray {
        readExisting()?.let { return it }
        check(create) { "Source credential key unavailable" }
        val candidate = randomBytes(SECRET_SIZE)
        try {
            val data = candidate.usePinned { pinned ->
                checkNotNull(CFDataCreate(null, pinned.addressOf(0).reinterpret(), candidate.size.convert()))
            }
            try {
                val status = withQuery(
                    kSecAttrAccessible to kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                    kSecValueData to data
                ) { SecItemAdd(it, null) }
                check(status == errSecSuccess || status == errSecDuplicateItem)
            } finally {
                CFRelease(data)
            }
            // Use the persisted winner, including a competing process/instance's key.
            // Never update/delete an existing key or encrypt with the losing candidate.
            return checkNotNull(readExisting())
        } finally {
            candidate.fill(0)
        }
    }

    fun randomBytes(size: Int): ByteArray {
        require(size > 0)
        val bytes = ByteArray(size)
        val status = bytes.usePinned { pinned ->
            SecRandomCopyBytes(kSecRandomDefault, size.convert(), pinned.addressOf(0))
        }
        if (status != errSecSuccess) {
            bytes.fill(0)
            error("Source credential randomness unavailable")
        }
        return bytes
    }

    private fun readExisting(): ByteArray? = withQuery(
        kSecReturnData to kCFBooleanTrue,
        kSecReturnAttributes to kCFBooleanTrue,
        kSecMatchLimit to kSecMatchLimitOne
    ) { query ->
        memScoped {
            val output = alloc<CFTypeRefVar>()
            output.value = null
            val status = SecItemCopyMatching(query, output.ptr)
            val result = output.value
            try {
                if (status == errSecItemNotFound) return@memScoped null
                check(status == errSecSuccess && result != null)
                check(CFGetTypeID(result) == CFDictionaryGetTypeID())
                val attributes: CFDictionaryRef = result.reinterpret()
                val accessibility = CFDictionaryGetValue(attributes, kSecAttrAccessible)
                check(accessibility != null && CFGetTypeID(accessibility) == CFStringGetTypeID())
                check(
                    CFStringCompare(
                        accessibility.reinterpret(),
                        kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                        0.convert(),
                    ) == kCFCompareEqualTo
                )
                val value = checkNotNull(CFDictionaryGetValue(attributes, kSecValueData))
                check(CFGetTypeID(value) == CFDataGetTypeID())
                val data: CFDataRef = value.reinterpret()
                check(CFDataGetLength(data) == SECRET_SIZE.toLong())
                checkNotNull(CFDataGetBytePtr(data)).readBytes(SECRET_SIZE)
            } finally {
                if (result != null) CFRelease(result)
            }
        }
    }

    private fun <T> withQuery(
        vararg extra: Pair<CFStringRef?, CFTypeRef?>,
        block: (CFDictionaryRef) -> T
    ): T = memScoped {
        val bundleId = checkNotNull(NSBundle.mainBundle.bundleIdentifier).also { check(it.isNotBlank()) }
        val service = checkNotNull(CFBridgingRetain("$bundleId.source-state"))
        try {
            val account = checkNotNull(CFBridgingRetain("aes256-cbc-hmac-sha256-v1"))
            try {
                val attributes: List<Pair<CFStringRef?, CFTypeRef?>> = listOf(
                    kSecClass to kSecClassGenericPassword,
                    kSecAttrService to service,
                    kSecAttrAccount to account,
                    kSecAttrSynchronizable to kCFBooleanFalse
                ) + extra
                // Values outlive this synchronous query, so the dictionary need not retain them.
                val keys = allocArrayOf(*attributes.map { it.first }.toTypedArray())
                val values = allocArrayOf(*attributes.map { it.second }.toTypedArray())
                val query = checkNotNull(
                    CFDictionaryCreate(null, keys.reinterpret(), values.reinterpret(), attributes.size.convert(), null, null)
                )
                try {
                    block(query)
                } finally {
                    CFRelease(query)
                }
            } finally {
                CFRelease(account)
            }
        } finally {
            CFRelease(service)
        }
    }
}
