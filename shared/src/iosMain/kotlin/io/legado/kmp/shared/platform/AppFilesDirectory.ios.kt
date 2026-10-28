@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.legado.kmp.shared.platform

import platform.Foundation.NSApplicationSupportDirectory
import platform.Foundation.NSFileManager
import platform.Foundation.NSUserDomainMask

actual class AppFilesDirectory {
    actual fun path(): String {
        val directory = NSFileManager.defaultManager.URLForDirectory(
            directory = NSApplicationSupportDirectory,
            inDomain = NSUserDomainMask,
            appropriateForURL = null,
            create = true,
            error = null
        ) ?: error("Unable to resolve iOS Application Support directory")
        return requireNotNull(directory.path) { "Unable to resolve iOS Application Support directory path" }
    }
}
