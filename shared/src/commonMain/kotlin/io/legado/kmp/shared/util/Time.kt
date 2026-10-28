package io.legado.kmp.shared.util

import kotlinx.datetime.Clock

fun currentTimeMillis(): Long = Clock.System.now().toEpochMilliseconds()
