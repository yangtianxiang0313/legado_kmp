package io.legado.kmp.shared.analyze.parser

internal interface JsonPathRegexMatcher {
    /** Matches the entire input, as Android Pattern.matcher(input).matches() does. */
    fun matches(input: String): Boolean
}

// The platform compiler applies Jayway flags and Android's ICU semantics.
internal expect fun compileJsonPathRegex(pattern: String, flags: String): JsonPathRegexMatcher

internal object JsonPathRegexSupport {
    private data class CacheKey(val pattern: String, val flags: String)

    private val guard = JsonPathCompilerGuard()
    private val compiledPatterns = LinkedHashMap<CacheKey, JsonPathRegexMatcher>()
    private const val MAX_COMPILED_PATTERNS = 32

    fun compile(pattern: String, flags: String): JsonPathRegexMatcher = guard.withLock {
        // FilterCompiler.endOfFlags accepts only these letters, before PatternFlag conversion.
        require(flags.all { it in "dimsxuU" }) { "Unsupported Jayway regex flags: $flags" }
        val key = CacheKey(pattern, flags)
        val matcher = compiledPatterns.remove(key) ?: compileJsonPathRegex(pattern, flags)
        if (compiledPatterns.size >= MAX_COMPILED_PATTERNS) {
            compiledPatterns.remove(compiledPatterns.keys.first())
        }
        compiledPatterns[key] = matcher
        matcher
    }
}
