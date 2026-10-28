package io.legado.kmp.shared.analyze.parser

/** Per traversal, never stored on a cached query or shared between function occurrences. */
internal class JsonPathScanTraversalBudget {
    private var remainingGrowth = 1_024
    private var depth = 0

    fun growth(added: Int) {
        if (added <= 0) return
        if (added > remainingGrowth) fail("1024 appended slots in live wildcard arrays")
        remainingGrowth -= added
    }

    fun <T> frame(block: () -> T): T {
        if (depth == 256) fail("256 nested traversal frames")
        depth++
        return try {
            block()
        } finally {
            depth--
        }
    }

    private fun fail(limit: String): Nothing = throw JsonPathFunctionSelectionLimitation(
        "Live JSONPath traversal exceeded $limit; cyclic/unbounded growth is not supported, and results were not truncated"
    )
}
