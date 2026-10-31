@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class, kotlinx.cinterop.BetaInteropApi::class)

package io.legado.kmp.shared.preferences

import kotlinx.cinterop.reinterpret
import kotlinx.cinterop.UByteVar
import kotlinx.cinterop.get
import kotlinx.cinterop.alloc
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.ptr
import kotlinx.cinterop.value
import platform.CoreFoundation.CFBooleanGetTypeID
import platform.CoreFoundation.CFGetTypeID
import platform.CoreFoundation.CFNumberIsFloatType
import platform.CoreFoundation.CFRelease
import platform.Foundation.*

internal object IosBackupPreferencesTransaction {
    fun prepare(
        defaults: NSUserDefaults,
        data: PreferencesBackupData,
        ignoredKeys: Set<String>,
    ): PreparedBackupPreferencesRestore {
        val before = defaults.persistentDomainForName(bundleDomain()).orEmpty()
        val memory = IosBackupPreferencesMemoryDefaults(defaults.dictionaryRepresentation())
        IosBackupPreferencesRestore.restore(memory, data, ignoredKeys)
        val keys = memory.writtenKeys.sorted()
        return PreparedBackupPreferencesRestore(
            before = IosBackupPreferencesPatch.encode(before, keys),
            after = IosBackupPreferencesPatch.encode(memory.dictionaryRepresentation(), keys),
        )
    }

    fun apply(defaults: NSUserDefaults, payload: String) {
        // Fully validate the durable plan before the first live mutation.
        val patch = IosBackupPreferencesPatch.decode(payload)
        val domainName = bundleDomain()
        val merged = defaults.persistentDomainForName(domainName).orEmpty().toMutableMap()
        patch.removed.forEach { merged.remove(it) }
        patch.values.forEach { (key, value) -> merged[key] = value }
        defaults.setPersistentDomain(merged, domainName)
        check(defaults.synchronize()) { "Backup preferences could not be synchronized" }
        val actual = defaults.persistentDomainForName(domainName).orEmpty()
        check(patch.removed.none { actual.containsKey(it) } &&
            patch.values.all { (key, value) -> sameBackupPreferenceValue(value, actual[key]) }) {
            "Backup preferences did not match the persisted restore plan"
        }
    }

    private fun bundleDomain(): String = checkNotNull(NSBundle.mainBundle.bundleIdentifier)
        .also { check(it.isNotBlank()) { "Missing preferences bundle domain" } }
}

private data class IosBackupPreferencesPatch(val values: Map<String, Any>, val removed: Set<String>) {
    companion object {
        private const val MAX_PAYLOAD_BYTES = 8 * 1024 * 1024
        private const val VERSION = "legado.ios.backup-preferences.v1"

        fun encode(snapshot: Map<Any?, *>, keys: List<String>): String {
            val values = keys.mapNotNull { key -> snapshot[key]?.let { listOf(key, it) } }
            val removed = keys.filter { snapshot[it] == null }
            // Arrays preserve duplicate entries for validation; NSDictionary decoding could hide them.
            // Binary plist encoding uses object identity across passes. Lazy Kotlin collection bridges
            // can recycle temporary wrappers; retain an entirely native container graph first.
            val root = nativeBackupPreferenceValue(listOf(VERSION, values, removed))
            require(NSPropertyListSerialization.propertyList(root, NSPropertyListBinaryFormat_v1_0)) {
                "Backup preferences contain a non-property-list value"
            }
            val bytes = requireNotNull(NSPropertyListSerialization.dataWithPropertyList(
                root, NSPropertyListBinaryFormat_v1_0, 0uL, null,
            )) { "Backup preferences could not be encoded" }
            require(bytes.length <= MAX_PAYLOAD_BYTES.toULong()) { "Backup preferences patch exceeds 8 MiB" }
            val payload = bytes.base64EncodedStringWithOptions(0uL)
            require(payload.length <= MAX_PAYLOAD_BYTES) { "Backup preferences patch exceeds 8 MiB" }
            // Preparation must not produce a journal entry that cannot later be applied.
            decode(payload)
            return payload
        }

        fun decode(payload: String): IosBackupPreferencesPatch {
            require(payload.isNotEmpty() && payload.length <= MAX_PAYLOAD_BYTES) {
                "Invalid backup preferences patch size"
            }
            val bytes = requireNotNull(NSData.create(base64EncodedString = payload, options = 0uL)) {
                "Invalid backup preferences patch encoding"
            }
            require(bytes.length <= MAX_PAYLOAD_BYTES.toULong()) { "Backup preferences patch exceeds 8 MiB" }
            val header = bytes.bytes?.reinterpret<UByteVar>()
            require(bytes.length >= 8uL && header != null &&
                "bplist00".indices.all { header[it].toInt() == "bplist00"[it].code }) {
                "Invalid backup preferences patch format"
            }
            val root = memScoped {
                val format = alloc<NSPropertyListFormatVar>()
                val decoded = NSPropertyListSerialization.propertyListWithData(bytes, 0uL, format.ptr, null)
                require(decoded != null && format.value == NSPropertyListBinaryFormat_v1_0) {
                    "Invalid backup preferences binary property list"
                }
                decoded as? List<*>
            }
            require(root != null && root.size == 3 && root[0] == VERSION) {
                "Invalid backup preferences patch version or structure"
            }
            val entries = requireNotNull(root[1] as? List<*>) { "Invalid backup preferences values" }
            val deletions = requireNotNull(root[2] as? List<*>) { "Invalid backup preferences deletions" }
            val values = linkedMapOf<String, Any>()
            entries.forEach { entry ->
                require(entry is List<*> && entry.size == 2) { "Invalid backup preferences entry" }
                val key = requireNotNull(entry[0] as? String) { "Invalid backup preferences key" }
                val value = requireNotNull(entry[1]) { "Invalid backup preferences value" }
                require(!values.containsKey(key)) { "Duplicate backup preferences key" }
                validateBackupPreferenceValue(value)
                values[key] = value
            }
            val removed = linkedSetOf<String>()
            deletions.forEach { entry ->
                val key = requireNotNull(entry as? String) { "Invalid backup preferences deletion key" }
                require(removed.add(key) && !values.containsKey(key)) { "Duplicate or overlapping backup preferences key" }
            }
            return IosBackupPreferencesPatch(values, removed)
        }
    }
}

private fun nativeBackupPreferenceValue(value: Any): Any = when (value) {
    is String -> NSString.create(string = value)
    is NSNumber, is NSData, is NSDate -> value
    is List<*> -> NSMutableArray().apply {
        value.forEach { addObject(nativeBackupPreferenceValue(requireNotNull(it))) }
    }
    is Map<*, *> -> NSMutableDictionary().apply {
        value.forEach { (key, child) ->
            require(key is String) { "Invalid backup preferences dictionary key" }
            setObject(nativeBackupPreferenceValue(requireNotNull(child)), forKey = NSString.create(string = key))
        }
    }
    else -> throw IllegalArgumentException("Invalid backup preferences property-list type")
}

private fun validateBackupPreferenceValue(value: Any?, depth: Int = 0) {
    require(depth < 128) { "Backup preferences value is nested too deeply" }
    when (value) {
        is String, is NSNumber, is NSData, is NSDate -> Unit
        is List<*> -> value.forEach { validateBackupPreferenceValue(it, depth + 1) }
        is Map<*, *> -> value.forEach { (key, child) ->
            require(key is String) { "Invalid backup preferences dictionary key" }
            validateBackupPreferenceValue(child, depth + 1)
        }
        else -> throw IllegalArgumentException("Invalid backup preferences property-list type")
    }
}

private fun sameBackupPreferenceValue(expected: Any?, actual: Any?): Boolean = when {
    expected is NSNumber && actual is NSNumber -> {
        val kind = expected.backupPreferenceNumberKind()
        kind == actual.backupPreferenceNumberKind() && when (kind) {
            IosBackupPreferenceNumberKind.REAL -> expected.doubleValue.toBits() == actual.doubleValue.toBits()
            else -> expected == actual
        }
    }
    expected is String && actual is String -> expected == actual
    expected is NSData && actual is NSData -> expected == actual
    expected is NSDate && actual is NSDate -> expected == actual
    expected is List<*> && actual is List<*> -> expected.size == actual.size &&
        expected.indices.all { sameBackupPreferenceValue(expected[it], actual[it]) }
    expected is Map<*, *> && actual is Map<*, *> -> expected.keys == actual.keys &&
        expected.all { (key, value) -> sameBackupPreferenceValue(value, actual[key]) }
    else -> false
}

internal enum class IosBackupPreferenceNumberKind { BOOLEAN, INTEGER, REAL }

internal fun NSNumber.backupPreferenceNumberKind(): IosBackupPreferenceNumberKind {
    val reference = checkNotNull(CFBridgingRetain(this))
    return try {
        when {
            CFGetTypeID(reference) == CFBooleanGetTypeID() -> IosBackupPreferenceNumberKind.BOOLEAN
            CFNumberIsFloatType(reference.reinterpret()) -> IosBackupPreferenceNumberKind.REAL
            else -> IosBackupPreferenceNumberKind.INTEGER
        }
    } finally {
        CFRelease(reference)
    }
}
