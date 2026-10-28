package io.legado.kmp.shared.platform

expect object SearchExecutionPolicy {
    fun effectiveSourceConcurrency(configuredThreadCount: Int): Int
}
