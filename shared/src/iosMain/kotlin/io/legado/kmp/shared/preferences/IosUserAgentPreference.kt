package io.legado.kmp.shared.preferences

import platform.Foundation.NSUserDefaults

/** The shared key is authoritative, including an explicitly saved blank value. */
internal class IosUserAgentPreference(private val defaults: NSUserDefaults) {
    init {
        migrateLegacyPreferenceOnce()
    }

    fun read(): String = defaults.stringForKey(KEY_USER_AGENT)
        ?.takeIf { it.isNotBlank() } ?: AppRuntimeConfig.DEFAULT_USER_AGENT

    fun write(value: String) {
        if (value.isBlank()) {
            defaults.removeObjectForKey(KEY_USER_AGENT)
        } else {
            defaults.setObject(value, KEY_USER_AGENT)
        }
    }

    private fun migrateLegacyPreferenceOnce() {
        if (defaults.boolForKey(KEY_MIGRATED)) return
        if (defaults.objectForKey(KEY_USER_AGENT) == null) {
            defaults.stringForKey(KEY_LEGACY_USER_AGENT)?.let { legacyValue ->
                defaults.setObject(legacyValue, KEY_USER_AGENT)
            }
        }
        // Mark even when no legacy value exists; later writes to the old key have no effect.
        defaults.setBool(true, KEY_MIGRATED)
        defaults.synchronize()
    }

    private companion object {
        const val KEY_USER_AGENT = "user_agent"
        const val KEY_LEGACY_USER_AGENT = "customUserAgent"
        const val KEY_MIGRATED = "user_agent_legacy_migrated_v1"
    }
}
