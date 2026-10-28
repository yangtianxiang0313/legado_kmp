package io.legado.kmp.shared.domain.webBook

import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.network.SharedCapabilityException

internal class WebBookParseException(
    val stage: String,
    override val message: String,
    override val cause: Throwable? = null
) : IllegalStateException(message, cause)

internal fun BookSource.displayName(): String {
    return bookSourceName.ifBlank { bookSourceUrl }
}

internal fun webBookParseFailure(
    stage: String,
    source: BookSource,
    baseUrl: String,
    detail: String,
    rule: String? = null,
    cause: Throwable? = null
): WebBookParseException {
    val message = buildString {
        append("WebBook ")
        append(stage)
        append(" failed")
        append(" [")
        append(source.displayName())
        append("] ")
        append(detail)
        append(" @ ")
        append(baseUrl)
        rule?.takeIf { it.isNotBlank() }?.let {
            append(" | rule=")
            append(it)
        }
        cause?.message?.takeIf { it.isNotBlank() }?.let {
            append(" | cause=")
            append(it)
        }
    }
    return WebBookParseException(
        stage = stage,
        message = message,
        cause = cause
    )
}

internal fun Throwable.sharedCapabilityOrNull(): SharedCapabilityException? {
    var current: Throwable? = this
    while (current != null) {
        if (current is SharedCapabilityException) {
            return current
        }
        current = current.cause
    }
    return null
}

internal fun Throwable.rethrowIfSharedCapability() {
    sharedCapabilityOrNull()?.let { throw it }
}
