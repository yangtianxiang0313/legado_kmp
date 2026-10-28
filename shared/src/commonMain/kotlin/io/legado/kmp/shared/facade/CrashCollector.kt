package io.legado.kmp.shared.facade

import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.datetime.Clock
import kotlinx.datetime.Instant
import kotlin.concurrent.Volatile

/**
 * Structured crash report entry.
 */
data class CrashReport(
    val timestamp: Instant,
    val facade: String,
    val method: String,
    val params: Map<String, String> = emptyMap(),
    val errorType: String,
    val message: String,
    val stackTrace: String,
    val context: Map<String, String> = emptyMap(),
) {
    fun toMarkdown(): String = buildString {
        appendLine("### $facade.$method")
        appendLine("- **Time**: $timestamp")
        appendLine("- **Error**: $errorType")
        appendLine("- **Message**: $message")
        if (params.isNotEmpty()) {
            appendLine("- **Params**: ${params.entries.joinToString { "${it.key}=${it.value}" }}")
        }
        if (context.isNotEmpty()) {
            appendLine("- **Context**: ${context.entries.joinToString { "${it.key}=${it.value}" }}")
        }
        appendLine("```")
        appendLine(stackTrace.take(2000))
        appendLine("```")
    }
}

/**
 * Singleton crash collector that captures, stores, and exports crash reports.
 *
 * Thread-safe via copy-on-write snapshots. Suitable for Kotlin/Native.
 */
object CrashCollector {
    @Volatile
    private var _reports: List<CrashReport> = emptyList()
    private val _crashFlow = MutableSharedFlow<CrashReport>(extraBufferCapacity = 64)

    /** Live stream of crash reports for real-time monitoring. */
    val crashFlow: SharedFlow<CrashReport> = _crashFlow.asSharedFlow()

    /** Maximum number of stored reports before oldest are evicted. */
    var maxReports: Int = 500

    val reportCount: Int get() = _reports.size

    fun record(
        facade: String,
        method: String,
        params: Map<String, String> = emptyMap(),
        error: Throwable,
        context: Map<String, String> = emptyMap(),
    ) {
        val report = CrashReport(
            timestamp = Clock.System.now(),
            facade = facade,
            method = method,
            params = params,
            errorType = error::class.simpleName ?: "Unknown",
            message = error.message ?: "no message",
            stackTrace = error.stackTraceToString(),
            context = context,
        )
        // Copy-on-write: safe for concurrent reads, eventual consistency for writes
        val current = _reports.toMutableList()
        current.add(report)
        while (current.size > maxReports) {
            current.removeAt(0)
        }
        _reports = current.toList()
        _crashFlow.tryEmit(report)
    }

    fun getReports(): List<CrashReport> = _reports

    fun clear() {
        _reports = emptyList()
    }

    /**
     * Export all crash reports as a Markdown document for debugging.
     */
    fun exportMarkdown(): String = buildString {
        val reports = getReports()
        appendLine("# Crash Report (${reports.size} entries)")
        appendLine()
        if (reports.isEmpty()) {
            appendLine("No crashes recorded.")
            return@buildString
        }

        // Summary by facade.method
        val grouped = reports.groupBy { "${it.facade}.${it.method}" }
        appendLine("## Summary")
        appendLine("| Facade.Method | Count | Last Error |")
        appendLine("|---|---|---|")
        for ((key, items) in grouped.entries.sortedByDescending { it.value.size }) {
            val last = items.last()
            appendLine("| $key | ${items.size} | ${last.errorType}: ${last.message.take(60)} |")
        }
        appendLine()

        // Detail
        appendLine("## Details")
        for (report in reports.takeLast(100)) {
            appendLine(report.toMarkdown())
            appendLine()
        }
    }

    /**
     * Export a concise JSON-like summary for programmatic consumption.
     */
    fun exportSummary(): List<Map<String, Any>> {
        return getReports().map { r ->
            mapOf(
                "timestamp" to r.timestamp.toString(),
                "facade" to r.facade,
                "method" to r.method,
                "errorType" to r.errorType,
                "message" to r.message,
            )
        }
    }
}

/**
 * Enhanced runRecoverable that also records crashes to CrashCollector.
 */
internal suspend inline fun <T> runRecoverableWithReport(
    facade: String,
    method: String,
    params: Map<String, String> = emptyMap(),
    crossinline block: suspend () -> T,
): T {
    return try {
        block()
    } catch (throwable: Throwable) {
        if (throwable is kotlin.coroutines.cancellation.CancellationException) {
            throw throwable
        }
        CrashCollector.record(facade, method, params, throwable)
        throw throwable.asRecoverableSharedException("$facade.$method")
    }
}
