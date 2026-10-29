package io.legado.kmp.shared.network

import io.legado.kmp.shared.model.BookSource
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

internal class ConcurrentRateLimiter(
    source: BookSource?,
    private val nowProvider: () -> Long = { currentTimeMillis() },
    private val waiter: suspend (Long) -> Unit = { delay(it) }
) {
    private val sourceKey = source?.bookSourceUrl?.takeIf { it.isNotBlank() }
    private val concurrentRate = source?.concurrentRate?.trim().orEmpty()

    suspend fun <T> withLimit(block: suspend () -> T): T {
        val record = acquireRecord()
        try {
            return block()
        } finally {
            withContext(NonCancellable) {
                releaseRecord(record)
            }
        }
    }

    private suspend fun acquireRecord(): ConcurrentRecord? {
        if (sourceKey == null || concurrentRate.isBlank() || concurrentRate == "0") {
            return null
        }
        while (true) {
            val decision = registryMutex.withLock {
                val now = nowProvider()
                val rateIndex = concurrentRate.indexOf('/')
                val existingRecord = concurrentRecordMap[sourceKey]
                if (existingRecord == null) {
                    val created = ConcurrentRecord(isConcurrent = rateIndex > 0, time = now, frequency = 1)
                    concurrentRecordMap[sourceKey] = created
                    return@withLock AcquireDecision(record = created, waitTimeMs = 0L)
                }
                val record = existingRecord
                val waitTime = if (!record.isConcurrent) {
                    val rateMs = concurrentRate.toIntOrNull() ?: 0
                    when {
                        rateMs <= 0 -> 0L
                        record.frequency > 0 -> rateMs.toLong()
                        now >= record.time + rateMs -> {
                            record.time = now
                            record.frequency = 1
                            0L
                        }
                        else -> (record.time + rateMs) - now
                    }
                } else {
                    val maxCount = concurrentRate.substringBefore('/').toIntOrNull() ?: 0
                    val windowMs = concurrentRate.substringAfter('/', "").toIntOrNull() ?: 0
                    when {
                        maxCount <= 0 || windowMs <= 0 -> 0L
                        now >= record.time + windowMs -> {
                            record.time = now
                            record.frequency = 1
                            0L
                        }
                        record.frequency > maxCount -> (record.time + windowMs) - now
                        else -> {
                            record.frequency += 1
                            0L
                        }
                    }
                }
                AcquireDecision(record = record, waitTimeMs = waitTime)
            }
            if (decision.waitTimeMs <= 0) {
                return decision.record
            }
            waiter(decision.waitTimeMs)
        }
    }

    private suspend fun releaseRecord(record: ConcurrentRecord?) {
        if (record == null || record.isConcurrent) return
        registryMutex.withLock {
            record.frequency -= 1
        }
    }

    internal data class ConcurrentRecord(
        val isConcurrent: Boolean,
        var time: Long,
        var frequency: Int
    )

    private data class AcquireDecision(
        val record: ConcurrentRecord,
        val waitTimeMs: Long
    )

    private companion object {
        private val registryMutex = Mutex()
        private val concurrentRecordMap = linkedMapOf<String, ConcurrentRecord>()
    }
}

internal expect fun currentTimeMillis(): Long
