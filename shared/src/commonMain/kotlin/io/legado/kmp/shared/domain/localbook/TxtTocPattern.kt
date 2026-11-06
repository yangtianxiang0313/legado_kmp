package io.legado.kmp.shared.domain.localbook

internal data class TxtTocMatch(val range: IntRange, val value: String)

internal interface TxtTocPattern {
    val pattern: String

    /**
     * False discards this attempt's matches (timeout, invalid ranges or native matching failure).
     * Exceptions from cancellation checks and actions must propagate, never become a fallback.
     */
    fun forEachMatch(content: String, checkActive: () -> Unit, action: (TxtTocMatch) -> Unit): Boolean
}

/** Invalid expressions return null; unrelated failures must propagate. */
internal expect fun compileTxtTocPattern(pattern: String): TxtTocPattern?
