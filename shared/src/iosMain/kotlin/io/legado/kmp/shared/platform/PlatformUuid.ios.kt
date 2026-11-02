package io.legado.kmp.shared.platform

import platform.Foundation.NSUUID

internal actual fun platformRandomUUID(): String = NSUUID().UUIDString.lowercase()
