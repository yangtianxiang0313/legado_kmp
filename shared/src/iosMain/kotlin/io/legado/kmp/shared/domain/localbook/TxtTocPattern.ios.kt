@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.legado.kmp.shared.domain.localbook

import kotlinx.cinterop.pointed
import kotlinx.cinterop.useContents
import kotlinx.cinterop.value
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.TimeSource
import platform.Foundation.NSMakeRange
import platform.Foundation.NSMatchingInternalError
import platform.Foundation.NSMatchingReportCompletion
import platform.Foundation.NSMatchingReportProgress
import platform.Foundation.NSRegularExpression
import platform.Foundation.NSRegularExpressionAnchorsMatchLines
import platform.Foundation.enumerateMatchesInString

private val txtTocMatchTimeout = 500.milliseconds
private val builtInTocPatterns by lazy {
    DefaultTxtTocRules.all().map { it.rule }.filter { it.isNotBlank() }.toSet()
}

internal actual fun compileTxtTocPattern(pattern: String): TxtTocPattern? {
    val expression = NSRegularExpression.regularExpressionWithPattern(
        pattern = pattern,
        options = NSRegularExpressionAnchorsMatchLines,
        error = null,
    ) ?: return null
    return FoundationTxtTocPattern(pattern, expression)
}

/** Kotlin/Native lookbehind can rescan the entire prefix for each failed candidate. */
private class FoundationTxtTocPattern(
    override val pattern: String,
    private val expression: NSRegularExpression,
) : TxtTocPattern {
    // Exact built-ins have bounded grammar and keep their fast scan; cancellation is checked
    // at every match/window. Edited/custom patterns need progress callbacks to bound backtracking.
    private val needsProgress = pattern !in builtInTocPatterns

    override fun forEachMatch(content: String, checkActive: () -> Unit, action: (TxtTocMatch) -> Unit): Boolean {
        checkActive()
        var failure: Throwable? = null
        var complete = true
        val started = TimeSource.Monotonic.markNow()
        var actionTime = Duration.ZERO
        var progressReports = 0
        // One complete-string enumeration preserves lookaround/anchor context and UTF-16 offsets.
        expression.enumerateMatchesInString(
            string = content,
            options = if (needsProgress) NSMatchingReportProgress or NSMatchingReportCompletion else NSMatchingReportCompletion,
            range = NSMakeRange(0u, content.length.toULong()),
        ) { result, flags, stop ->
            if (failure == null && complete) {
                try {
                    // Progress can fire for every character; keep the native scan interruptible
                    // without consulting the clock and Job on every single callback.
                    if (result != null || flags and NSMatchingInternalError != 0uL || ++progressReports % 64 == 0) {
                        checkActive()
                        if (flags and NSMatchingInternalError != 0uL ||
                            needsProgress && started.elapsedNow() - actionTime >= txtTocMatchTimeout
                        ) {
                            complete = false
                        } else result?.range?.useContents {
                            if (length == 0uL || location > content.length.toULong() ||
                                length > content.length.toULong() - location
                            ) {
                                complete = false
                                return@useContents
                            }
                            val start = location.toInt()
                            val end = start + length.toInt()
                            val actionStarted = TimeSource.Monotonic.markNow()
                            action(TxtTocMatch(start until end, content.substring(start, end)))
                            // An action may read/split a chapter. Its I/O is not regex engine time.
                            actionTime += actionStarted.elapsedNow()
                        }
                    }
                } catch (error: Throwable) {
                    // Never unwind a Kotlin exception through the Objective-C enumeration callback.
                    failure = error
                }
            }
            if (failure != null || !complete) stop?.pointed?.value = true
        }
        failure?.let { throw it }
        checkActive()
        return complete && (!needsProgress || started.elapsedNow() - actionTime < txtTocMatchTimeout)
    }
}
