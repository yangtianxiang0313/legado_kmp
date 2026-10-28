package io.legado.kmp.shared.scripting

import kotlinx.datetime.Instant
import kotlinx.datetime.TimeZone
import kotlinx.datetime.toLocalDateTime

internal const val DEFAULT_LEGACY_DATE_PATTERN = "yyyy/MM/dd HH:mm"

internal fun formatTimestamp(
    ts: Long,
    tz: TimeZone,
    pattern: String = DEFAULT_LEGACY_DATE_PATTERN,
): String {
    return try {
        val instant = Instant.fromEpochMilliseconds(ts)
        val dt = instant.toLocalDateTime(tz)
        buildString(pattern.length + 8) {
            var index = 0
            while (index < pattern.length) {
                when {
                    pattern.startsWith("yyyy", index) -> {
                        append(dt.year.toString().padStart(4, '0'))
                        index += 4
                    }
                    pattern.startsWith("yy", index) -> {
                        append((dt.year % 100).toString().padStart(2, '0'))
                        index += 2
                    }
                    pattern.startsWith("MM", index) -> {
                        append(dt.monthNumber.toString().padStart(2, '0'))
                        index += 2
                    }
                    pattern[index] == 'M' -> {
                        append(dt.monthNumber)
                        index += 1
                    }
                    pattern.startsWith("dd", index) -> {
                        append(dt.dayOfMonth.toString().padStart(2, '0'))
                        index += 2
                    }
                    pattern[index] == 'd' -> {
                        append(dt.dayOfMonth)
                        index += 1
                    }
                    pattern.startsWith("HH", index) -> {
                        append(dt.hour.toString().padStart(2, '0'))
                        index += 2
                    }
                    pattern[index] == 'H' -> {
                        append(dt.hour)
                        index += 1
                    }
                    pattern.startsWith("mm", index) -> {
                        append(dt.minute.toString().padStart(2, '0'))
                        index += 2
                    }
                    pattern[index] == 'm' -> {
                        append(dt.minute)
                        index += 1
                    }
                    pattern.startsWith("ss", index) -> {
                        append(dt.second.toString().padStart(2, '0'))
                        index += 2
                    }
                    pattern[index] == 's' -> {
                        append(dt.second)
                        index += 1
                    }
                    pattern.startsWith("SSS", index) -> {
                        append((dt.nanosecond / 1_000_000).toString().padStart(3, '0'))
                        index += 3
                    }
                    pattern[index] == '\'' -> {
                        val close = pattern.indexOf('\'', startIndex = index + 1)
                        if (close > index) {
                            append(pattern.substring(index + 1, close))
                            index = close + 1
                        } else {
                            index += 1
                        }
                    }
                    else -> {
                        append(pattern[index])
                        index += 1
                    }
                }
            }
        }
    } catch (_: Exception) {
        ""
    }
}
