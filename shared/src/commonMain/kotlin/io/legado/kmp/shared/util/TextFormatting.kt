package io.legado.kmp.shared.util

import kotlin.math.roundToInt

fun formatChineseWordCount(words: Int): String {
    return if (words > 10000) {
        "${(words / 1000.0).roundToInt() / 10.0}万字"
    } else {
        "${words}字"
    }
}
