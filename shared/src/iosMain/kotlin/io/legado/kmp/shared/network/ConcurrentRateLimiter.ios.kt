@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.legado.kmp.shared.network

import platform.Foundation.*

internal actual fun currentTimeMillis(): Long = (NSDate().timeIntervalSince1970?.times(1000.0) ?: 0.0).toLong()
