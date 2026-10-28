package io.legado.kmp.shared.model

import kotlinx.datetime.Clock
import kotlinx.datetime.LocalDate
import kotlinx.datetime.TimeZone
import kotlinx.datetime.periodUntil
import kotlinx.datetime.todayIn

internal object ReadSimulationSchedule {
    fun count(
        config: ReadConfig?,
        realCount: Int,
        today: LocalDate = Clock.System.todayIn(TimeZone.currentSystemDefault()),
    ): Int {
        val maximum = realCount.coerceAtLeast(0)
        if (config == null || !config.readSimulating) return maximum
        val startDate = config.startDate ?: today
        // Android uses Period.between(...).days, not the total number of elapsed days.
        val daysPassed = startDate.periodUntil(today).days.toLong() + 1L
        val unlocked = (config.startChapter ?: 0).toLong() + daysPassed * config.dailyChapters.toLong()
        return unlocked.coerceIn(0L, maximum.toLong()).toInt()
    }
}
