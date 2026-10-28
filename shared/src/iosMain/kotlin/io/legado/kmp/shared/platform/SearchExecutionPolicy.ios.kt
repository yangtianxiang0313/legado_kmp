package io.legado.kmp.shared.platform

actual object SearchExecutionPolicy {
    actual fun effectiveSourceConcurrency(configuredThreadCount: Int): Int {
        return configuredThreadCount.coerceIn(1, 4)
    }
}
