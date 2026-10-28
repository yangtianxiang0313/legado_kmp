package io.legado.kmp.shared.facade

import io.legado.kmp.shared.model.ReplaceRule
import io.legado.kmp.shared.model.validTimeout
import kotlin.coroutines.CoroutineContext
import kotlin.time.TimeSource
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.longOrNull

internal class ForegroundWebRuleSupport(
    private val rules: ReplaceRuleFacade,
    private val json: Json,
) {
    // Android clients parse data a second time; this must remain a JSON string, not an array.
    suspend fun getRules(): JsonElement = JsonPrimitive(json.encodeToString(rules.getAllRules()))

    suspend fun saveRule(payload: JsonObject): JsonElement {
        var rule = json.decodeFromJsonElement<ReplaceRule>(payload)
        if (payload["order"] == null || rule.order == Int.MIN_VALUE) {
            val maxOrder = rules.getAllRules().maxOfOrNull { it.order } ?: 0
            require(maxOrder < Int.MAX_VALUE) { "替换规则排序已达到上限" }
            rule = rule.copy(order = maxOrder + 1)
        }
        currentCoroutineContext().ensureActive()
        rules.saveRule(rule)
        return JsonPrimitive("")
    }

    suspend fun deleteRule(payload: JsonObject): JsonElement {
        val id = (payload["id"] as? JsonPrimitive)?.longOrNull ?: error("缺少替换规则 id")
        rules.deleteRule(id)
        return JsonPrimitive("")
    }

    suspend fun testRule(payload: JsonObject): JsonElement {
        val encodedRule = when (val value = payload["rule"]) {
            is JsonObject -> value
            is JsonPrimitive -> {
                require(value.isString) { "替换规则格式不对" }
                json.parseToJsonElement(value.content) as? JsonObject ?: error("替换规则格式不对")
            }
            else -> error("缺少替换规则")
        }
        val rule = json.decodeFromJsonElement<ReplaceRule>(encodedRule)
        require(rule.pattern.isNotEmpty()) { "替换规则不能为空" }
        val text = payload.foregroundWebString("text") ?: error("缺少测试文本")
        currentCoroutineContext().ensureActive()
        // Preview deliberately ignores isEnabled and scope, and never saves the test rule.
        val content = if (rule.isRegex) {
            require(!rule.replacement.startsWith("@js:")) { "共享替换引擎尚不支持 @js: 替换测试" }
            val input = ForegroundWebRegexInput(text, currentCoroutineContext(), rule.validTimeout)
            Regex(rule.pattern).replace(input, rule.replacement)
        } else {
            text.replace(rule.pattern, rule.replacement)
        }
        currentCoroutineContext().ensureActive()
        return JsonPrimitive(content)
    }
}

/** Native regex reads through CharSequence, so backtracking can observe cancellation and deadlines. */
private class ForegroundWebRegexInput private constructor(
    private val text: CharSequence,
    private val check: () -> Unit,
) : CharSequence {
    constructor(text: String, context: CoroutineContext, timeoutMillis: Long) : this(
        text,
        kotlin.run {
            val started = TimeSource.Monotonic.markNow()
            val timeout = timeoutMillis.coerceIn(1L, 10_000L)
            val guard: () -> Unit = {
                context.ensureActive()
                require(started.elapsedNow().inWholeMilliseconds < timeout) { "替换规则执行超时" }
            }
            guard
        },
    )

    override val length: Int
        get() {
            check()
            return text.length
        }

    override fun get(index: Int): Char {
        check()
        return text[index]
    }

    override fun subSequence(startIndex: Int, endIndex: Int): CharSequence {
        check()
        return ForegroundWebRegexInput(text.subSequence(startIndex, endIndex), check)
    }

    override fun toString(): String {
        check()
        return text.toString()
    }
}
