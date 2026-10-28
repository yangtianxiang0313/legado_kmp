package io.legado.kmp.shared.util

/**
 * Compare strings using the same intent as legado's String.cnCompare:
 * Simplified-Chinese collation for bookshelf/source display names.
 */
fun String.cnCompare(other: String): Int = platformCnCompare(this, other)

internal expect fun platformCnCompare(left: String, right: String): Int

/**
 * Convert Chinese chapter number strings to Arabic numerals.
 * Ported from legado's StringUtils.stringToInt / toNumChapter.
 *
 * Example: "第一百二十三章" → "第123章"
 */
fun toNumChapter(input: String): String {
    return chapterNumPattern.replace(input) { match ->
        val prefix = match.groupValues[1]   // "第"
        val cnNum = match.groupValues[2]    // "一百二十三"
        val suffix = match.groupValues[3]   // "章" / "节" / "回" etc.
        val num = chineseToInt(cnNum)
        if (num >= 0) "$prefix${num}$suffix" else match.value
    }
}

private val chapterNumPattern = Regex("(第)([零〇一二三四五六七八九十百千万]+)(章|节|回|卷|集|话|篇)")

private val cnDigitMap = mapOf(
    '零' to 0, '〇' to 0,
    '一' to 1, '二' to 2, '三' to 3, '四' to 4, '五' to 5,
    '六' to 6, '七' to 7, '八' to 8, '九' to 9, '十' to 10,
    '百' to 100, '千' to 1000, '万' to 10000
)

internal fun chineseToInt(cn: String): Int {
    if (cn.isBlank()) return -1

    var result = 0
    var current = 0

    for (ch in cn) {
        val value = cnDigitMap[ch] ?: return -1
        when {
            value == 10000 -> {
                if (current == 0) current = 1
                result = (result + current) * value
                current = 0
            }
            value >= 10 -> {
                if (current == 0) current = 1
                current *= value
            }
            else -> {
                current = current * 10 + value
                // Handle case like "十三" where 十 was already processed
                // but we only reach here for digits 0-9
            }
        }
    }
    result += current

    // Special case: "十" alone should be 10, "十三" should be 13
    if (cn.length == 1 && cn[0] == '十') return 10
    if (cn.startsWith("十") && cn.length > 1) {
        // "十X" = 10 + X
        val rest = cn.substring(1)
        if (rest.all { cnDigitMap[it] != null && (cnDigitMap[it]!! < 10) }) {
            return 10 + chineseToInt(rest)
        }
    }

    return result
}
