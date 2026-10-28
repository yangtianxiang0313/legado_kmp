package io.legado.kmp.shared.analyze.parser

internal expect class JsonPathCompilerGuard() {
    fun <T> withLock(block: () -> T): T
}
