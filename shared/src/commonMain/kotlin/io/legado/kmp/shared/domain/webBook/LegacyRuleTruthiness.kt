package io.legado.kmp.shared.domain.webBook

internal fun legacyRuleIsTrue(value: String?, nullIsTrue: Boolean = false): Boolean {
    // The legacy null sentinel is checked before trimming or case folding.
    if (value.isNullOrBlank() || value == "null") {
        return nullIsTrue
    }
    val trimmed = value.trim()
    return !trimmed.equals("false", ignoreCase = true) &&
        !trimmed.equals("no", ignoreCase = true) &&
        !trimmed.equals("not", ignoreCase = true) &&
        trimmed != "0"
}
