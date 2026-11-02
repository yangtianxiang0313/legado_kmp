package io.legado.kmp.shared.util

import io.legado.kmp.shared.content.BookHelp

/**
 * Compare strings using the same intent as legado's String.cnCompare:
 * Simplified-Chinese collation for bookshelf/source display names.
 */
fun String.cnCompare(other: String): Int = platformCnCompare(this, other)

internal expect fun platformCnCompare(left: String, right: String): Int

/**
 * Match Legado JsExtensions.toNumChapter: convert only the first chapter match.
 * Reuse the number parser already used when matching chapters during source changes.
 */
fun toNumChapter(input: String): String {
    val match = chapterNumPattern.find(input) ?: return input
    val number = BookHelp.stringToInt(match.groupValues[2])
    return "${match.groupValues[1]}$number${match.groupValues[3]}"
}

private val chapterNumPattern = Regex("(第)(.+?)(章)")
