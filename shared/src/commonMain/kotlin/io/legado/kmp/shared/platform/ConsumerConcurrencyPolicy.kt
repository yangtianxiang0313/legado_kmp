package io.legado.kmp.shared.platform

/** Logical in-flight work, independent of platform executor threads or HTTP connection reuse. */
object ConsumerConcurrencyPolicy {
    fun configuredLimit(configured: Int): Int = configured.coerceIn(1, 999)

    fun workerCount(configured: Int, workCount: Int): Int =
        configuredLimit(configured).coerceAtMost(workCount.coerceAtLeast(0))
}
