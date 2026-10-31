@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.legado.kmp.shared.preferences

import platform.Foundation.*

/** Never delegates a read or mutation used by restore to NSUserDefaults' live search list. */
internal class IosBackupPreferencesMemoryDefaults(snapshot: Map<Any?, *>) : NSUserDefaults(suiteName = null) {
    private val values = snapshot.toMutableMap()
    private val touchedKeys = linkedSetOf<String>()
    val writtenKeys: Set<String> get() = touchedKeys.toSet()

    override fun objectForKey(defaultName: String): Any? = values[defaultName]

    override fun setObject(value: Any?, forKey: String) {
        touchedKeys.add(forKey)
        if (value == null) values.remove(forKey) else values[forKey] = value
    }

    override fun removeObjectForKey(defaultName: String) {
        setObject(null, defaultName)
    }

    override fun stringForKey(defaultName: String): String? = when (val value = objectForKey(defaultName)) {
        is String -> value
        is NSNumber -> value.stringValue
        else -> null
    }

    override fun integerForKey(defaultName: String): Long = when (val value = objectForKey(defaultName)) {
        is NSNumber -> value.integerValue
        is String -> (value as NSString).integerValue
        else -> 0L
    }

    override fun floatForKey(defaultName: String): Float = when (val value = objectForKey(defaultName)) {
        // The SDK explicitly excludes booleans from floating-point conversions.
        is NSNumber -> if (value.backupPreferenceNumberKind() == IosBackupPreferenceNumberKind.BOOLEAN) 0f else value.floatValue
        is String -> (value as NSString).floatValue
        else -> 0f
    }

    override fun doubleForKey(defaultName: String): Double = when (val value = objectForKey(defaultName)) {
        is NSNumber -> if (value.backupPreferenceNumberKind() == IosBackupPreferenceNumberKind.BOOLEAN) 0.0 else value.doubleValue
        is String -> (value as NSString).doubleValue
        else -> 0.0
    }

    override fun boolForKey(defaultName: String): Boolean = when (val value = objectForKey(defaultName)) {
        is NSNumber -> value.boolValue
        is String -> value == "YES" || value == "1"
        else -> false
    }

    override fun arrayForKey(defaultName: String): List<*>? = objectForKey(defaultName) as? List<*>

    override fun dictionaryForKey(defaultName: String): Map<Any?, *>? = objectForKey(defaultName) as? Map<Any?, *>

    override fun dataForKey(defaultName: String): NSData? = objectForKey(defaultName) as? NSData

    override fun stringArrayForKey(defaultName: String): List<*>? =
        arrayForKey(defaultName)?.takeIf { values -> values.all { it is String } }

    override fun setInteger(value: Long, forKey: String) {
        setObject(NSNumber(integer = value), forKey)
    }

    override fun setFloat(value: Float, forKey: String) {
        setObject(NSNumber(float = value), forKey)
    }

    override fun setDouble(value: Double, forKey: String) {
        setObject(NSNumber(double = value), forKey)
    }

    override fun setBool(value: Boolean, forKey: String) {
        setObject(NSNumber(bool = value), forKey)
    }

    override fun dictionaryRepresentation(): Map<Any?, *> = values.toMap()

    override fun synchronize(): Boolean = true
}
