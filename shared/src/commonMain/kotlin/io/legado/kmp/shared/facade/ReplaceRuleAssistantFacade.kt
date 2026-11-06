package io.legado.kmp.shared.facade

import kotlin.coroutines.cancellation.CancellationException
import kotlin.time.TimeSource
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

data class RuleAssistantMatch(val start: Int, val length: Int)

data class RuleAssistantPreview(
    val pattern: String,
    val replacement: String,
    val isRegex: Boolean,
    val output: String,
    val matches: List<RuleAssistantMatch>,
    val protectedMatchCount: Int,
    val requiresDeletionConfirmation: Boolean,
)

/** A draft-only API: no repository, scope mutation, or enabled-rule side effects. */
class ReplaceRuleAssistantFacade {
    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun preview(
        operation: String,
        text: String,
        replacement: String,
        sample: String,
        protectedText: String,
    ): RuleAssistantPreview = runRecoverable("ReplaceRuleAssistant.preview") {
        withContext(Dispatchers.Default) {
            require(sample.isNotBlank()) { "请填写样例正文" }
            require(sample.length <= 16_000 && protectedText.length <= 8_000) { "预览样例过长，请缩短后重试" }
            require(text.length <= 512 && replacement.length <= 512) { "匹配文字或替换文字不能超过 512 个字符" }
            require(operation == "replaceLiteral" || replacement.isEmpty()) { "删除或合并空行时不能指定替换文字" }
            val pattern = when (operation) {
                "replaceLiteral" -> {
                    require(text.isNotBlank()) { "请填写需要替换的非空白文字" }
                    require(text != replacement) { "原文字与替换文字相同" }
                    text
                }
                "removeContainingLines", "removePrefixedLines" -> {
                    require(text.isNotBlank() && text.none { it == '\r' || it == '\n' }) { "请填写非空的单行匹配文字" }
                    val prefix = if (operation == "removeContainingLines") "[^\\r\\n]*" else "[\\t ]*"
                    "(?m)^$prefix${Regex.escape(text)}[^\\r\\n]*(?:\\r\\n|[\\r\\n]|$)"
                }
                "collapseBlankLines" -> {
                    require(text.isEmpty()) { "合并空行不需要匹配文字" }
                    val newline = "(?:\\r\\n|\\r(?!\\n)|\\n)"
                    "$newline(?:[\\t ]*$newline){2,}"
                }
                else -> error("暂不支持这类处理，请选择常用模板")
            }
            val isRegex = operation != "replaceLiteral"
            val outputReplacement = if (operation == "collapseBlankLines") "\n\n" else replacement
            val context = currentCoroutineContext()
            val started = TimeSource.Monotonic.markNow()
            val check = {
                context.ensureActive()
                require(started.elapsedNow().inWholeMilliseconds < 1_000) { "规则预览超时，请缩短样例后重试" }
            }
            val regex = if (isRegex) Regex(pattern) else null

            fun matches(input: String): List<RuleAssistantMatch> {
                val found = mutableListOf<RuleAssistantMatch>()
                if (regex != null) {
                    for (match in regex.findAll(AssistantRegexInput(input, check))) {
                        check()
                        require(match.value.isNotEmpty()) { "不支持匹配空字符串的规则" }
                        found += RuleAssistantMatch(match.range.first, match.value.length)
                        require(found.size <= 500) { "样例命中过多，请缩短样例" }
                    }
                } else {
                    var offset = 0
                    while (offset <= input.length - pattern.length) {
                        check()
                        val index = input.indexOf(pattern, offset)
                        if (index < 0) break
                        found += RuleAssistantMatch(index, pattern.length)
                        require(found.size <= 500) { "样例命中过多，请缩短样例" }
                        offset = index + pattern.length
                    }
                }
                return found
            }

            val sampleMatches = matches(sample)
            val protectedMatches = if (protectedText.isEmpty()) emptyList() else matches(protectedText)
            // A protected fragment can be lost with its containing line without matching on its own.
            val protectedMatchCount = maxOf(
                protectedMatches.size,
                protectedSampleMatchCount(sample, protectedText, sampleMatches, check),
            )
            check()
            // These are the same Kotlin replacement semantics used by ReplaceRule.applyTo.
            val output = regex?.replace(AssistantRegexInput(sample, check), outputReplacement)
                ?: sample.replace(pattern, outputReplacement)
            check()
            require(output.length <= 32_000) { "替换结果过长，请缩短样例或替换文字" }
            RuleAssistantPreview(
                pattern = pattern,
                replacement = outputReplacement,
                isRegex = isRegex,
                output = output,
                matches = sampleMatches,
                protectedMatchCount = protectedMatchCount,
                requiresDeletionConfirmation = output.isBlank() || output.length * 2 < sample.length,
            )
        }
    }
}

private fun protectedSampleMatchCount(
    sample: String,
    protectedText: String,
    matches: List<RuleAssistantMatch>,
    check: () -> Unit,
): Int {
    if (protectedText.isEmpty() || matches.isEmpty() || protectedText.length > sample.length) return 0
    check()
    var occurrence = sample.indexOf(protectedText)
    var count = 0
    for (match in matches) {
        check()
        while (occurrence >= 0 && occurrence + protectedText.length <= match.start) {
            check()
            occurrence = sample.indexOf(protectedText, occurrence + 1)
        }
        if (occurrence < 0) break
        if (occurrence < match.start + match.length) count++
    }
    return count
}

private class AssistantRegexInput(
    private val text: CharSequence,
    private val check: () -> Unit,
) : CharSequence {
    override val length: Int get() { check(); return text.length }

    override fun get(index: Int): Char { check(); return text[index] }

    override fun subSequence(startIndex: Int, endIndex: Int): CharSequence {
        check()
        return AssistantRegexInput(text.subSequence(startIndex, endIndex), check)
    }

    override fun toString(): String { check(); return text.toString() }
}
