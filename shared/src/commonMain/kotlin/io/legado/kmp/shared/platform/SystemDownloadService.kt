package io.legado.kmp.shared.platform

import io.legado.kmp.shared.domain.runtime.DownloadService

internal expect fun createSystemDownloadService(): DownloadService

expect fun handleSystemDownloadEvents(identifier: String, completion: () -> Unit): Boolean
