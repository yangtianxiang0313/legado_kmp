package io.legado.kmp.shared.scripting

private const val LEGACY_PRIMITIVE_EXPRESSION_MAX_LENGTH = 16 * 1024

/**
 * Conservative eligibility gate, not a replacement for the JavaScript engine.
 * More complex valid expressions return false and use the full runtime.
 * The caller guards jsLib/scalar input and evaluates the original script with QuickJS;
 * escape syntax errors remain engine errors, not a reason to retry another path.
 */
internal fun isLegacyPrimitiveExpression(script: String): Boolean {
    if (script.length !in 1..LEGACY_PRIMITIVE_EXPRESSION_MAX_LENGTH) return false

    var cursor = script.skipLegacyPrimitiveWhitespace(0)
    while (cursor < script.length) {
        cursor = when (script[cursor]) {
            '\'', '"' -> script.legacyPrimitiveLiteralEnd(cursor)
            'r' -> {
                if (!script.startsWith("result", cursor)) return false
                cursor + 6
            }
            else -> return false
        }
        if (cursor < 0) return false

        cursor = script.skipLegacyPrimitiveWhitespace(cursor)
        if (cursor == script.length) return true
        when (script[cursor]) {
            '+' -> cursor = script.skipLegacyPrimitiveWhitespace(cursor + 1)
            ';' -> return script.skipLegacyPrimitiveWhitespace(cursor + 1) == script.length
            else -> return false
        }
    }
    return false
}

private fun String.legacyPrimitiveLiteralEnd(start: Int): Int {
    val quote = this[start]
    var cursor = start + 1
    var escaped = false
    while (cursor < length) {
        val char = this[cursor++]
        if (char.isLegacyPrimitiveLineTerminator()) return -1
        if (escaped) {
            escaped = false
        } else {
            when (char) {
                '\\' -> escaped = true
                quote -> return cursor
            }
        }
    }
    return -1
}

private fun String.skipLegacyPrimitiveWhitespace(start: Int): Int {
    var cursor = start
    while (cursor < length && this[cursor].isLegacyPrimitiveWhitespace()) cursor++
    return cursor
}

private fun Char.isLegacyPrimitiveLineTerminator(): Boolean =
    this == '\n' || this == '\r' || this == '\u2028' || this == '\u2029'

// Explicit ECMAScript whitespace, used only outside literals, not Kotlin's broader set.
private fun Char.isLegacyPrimitiveWhitespace(): Boolean = when (this) {
    '\t', '\u000B', '\u000C', ' ', '\u00A0', '\u1680',
    in '\u2000'..'\u200A', '\u202F', '\u205F', '\u3000', '\uFEFF' -> true
    else -> isLegacyPrimitiveLineTerminator()
}
