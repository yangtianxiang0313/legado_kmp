@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.legado.kmp.shared.util

import platform.Foundation.NSString
import platform.Foundation.NSLocale
import platform.Foundation.NSMakeRange
import platform.Foundation.NSOrderedAscending
import platform.Foundation.NSOrderedDescending
import platform.Foundation.compare

internal actual fun platformCnCompare(left: String, right: String): Int {
    val result = (left as NSString).compare(
        string = right,
        options = 0u,
        range = NSMakeRange(0u, left.length.toULong()),
        locale = NSLocale(localeIdentifier = "zh-Hans-CN"),
    )
    return when (result) {
        NSOrderedAscending -> -1
        NSOrderedDescending -> 1
        else -> 0
    }
}
