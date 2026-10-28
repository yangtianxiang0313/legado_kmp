package io.legado.kmp.shared.analyze.parser

import io.legado.kmp.shared.analyze.AnalyzeResult
import io.legado.kmp.shared.analyze.analyzeResultFromJs
import io.legado.kmp.shared.analyze.parser.JsRuleScriptSupport.buildLegacyReturnScript
import io.legado.kmp.shared.analyze.parser.JsRuleScriptSupport.replaceLegacyCodeMatches
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.network.JsExecutor
import io.legado.kmp.shared.network.SharedCapabilityException
import io.legado.kmp.shared.source.SourceStateStore
import io.legado.kmp.shared.util.ChineseConverter
import io.legado.kmp.shared.util.md5Hex
import io.legado.kmp.shared.util.toNumChapter
import io.ktor.http.encodeURLQueryComponent

/**
 * JavaScript rule parser
 * Handles JS-based rules using quickjs-kt
 */
class JsRuleParser(
    private val jsExecutor: JsExecutor = JsExecutor.Default,
    private val source: BookSource? = null,
    private val sourceStateStore: SourceStateStore? = null
) {
    private data class LegacyPut(
        val key: String,
        val value: Any?
    )

    private data class PreparedScript(
        val script: String,
        val puts: List<LegacyPut>
    )

    private data class LegacyCallMatch(
        val startIndex: Int,
        val endIndex: Int,
        val arguments: String
    )


    // JS variable bindings
    private val bindings = mutableMapOf<String, Any?>()
    private val customBindings = mutableMapOf<String, Any?>()

    /**
     * Parse and evaluate a JS rule
     *
     * @param rule JavaScript code
     * @param content HTML/JSON content
     * @param baseUrl Base URL
     * @return AnalyzeResult with evaluated result
     */
    suspend fun evaluate(
        rule: String,
        content: String,
        baseUrl: String? = null,
        transientBindings: Map<String, Any?> = emptyMap()
    ): AnalyzeResult {
        if (rule.isBlank()) {
            return AnalyzeResult.StringVal("")
        }
        // Network helpers (java.ajax, java.post, java.head, java.ajaxAll, java.connect,
        // java.getResponse, java.get with 2 args) are fully implemented in LegacySourceJsRuntime.
        // When source != null, AnalyzeRule routes through LegacySourceJsRuntime (not JsRuleParser).
        // JsRuleParser is only used for source-less evaluation where network calls are unavailable,
        // so we no longer block them here — the missing host will produce empty results gracefully.

        return try {
            // Set up standard JS variables
            setupJsVariables(content, baseUrl, transientBindings)
            val prepared = prepareLegacyScript(rule, content, transientBindings)
            val executableScript = buildLegacyReturnScript(prepared.script) ?: prepared.script

            // Evaluate JS expression
            val execution = prepareJsRuleExecution(executableScript, bindings)
            val result = jsExecutor.execute(execution.script, execution.bindings)
            prepared.puts.forEach { put ->
                customBindings[put.key] = put.value
            }

            // Convert result to AnalyzeResult
            analyzeResultFromJs(result) { error ->
                val capability = error.exception as? SharedCapabilityException
                if (capability != null) {
                    throw capability
                }
                AnalyzeResult.StringVal("")
            }
        } catch (e: SharedCapabilityException) {
            throw e
        } catch (e: Exception) {
            AnalyzeResult.StringVal("")
        }
    }

    /**
     * Setup standard JavaScript variables
     */
    private fun setupJsVariables(
        content: String,
        baseUrl: String?,
        transientBindings: Map<String, Any?>
    ) {
        bindings.clear()

        // Content variables
        bindings["result"] = content
        bindings["body"] = content
        bindings["src"] = content

        // URL variables
        bindings["baseUrl"] = baseUrl ?: ""

        // Book source variables
        source?.let { src ->
            bindings["sourceUrl"] = src.bookSourceUrl
            bindings["sourceName"] = src.bookSourceName
            bindings["source"] = src.bookSourceUrl

            // Source headers
            src.header?.let {
                bindings["header"] = it
            }

            // Login info
            bindings["loginUrl"] = src.loginUrl
            bindings["loginUi"] = src.loginUi

            // Encoding
            bindings["charset"] = "UTF-8"
        }

        transientBindings.forEach { (key, value) ->
            bindings[key] = value
        }
        bindings.putAll(customBindings)
    }

    private suspend fun prepareLegacyScript(
        rule: String,
        content: String,
        transientBindings: Map<String, Any?>
    ): PreparedScript {
        val puts = mutableListOf<LegacyPut>()
        val effectiveBindings = linkedMapOf<String, Any?>().apply {
            putAll(bindings)
            putAll(customBindings)
            putAll(transientBindings)
        }
        val sourceKey = source?.bookSourceUrl
        if (!sourceKey.isNullOrBlank()) {
            sourceStateStore?.getLoginHeader(sourceKey)?.let {
                effectiveBindings["loginHeader"] = it
                customBindings["loginHeader"] = it
            }
            sourceStateStore?.getLoginInfo(sourceKey)?.let {
                effectiveBindings["loginInfo"] = it
                customBindings["loginInfo"] = it
            }
            sourceStateStore?.getSourceVariable(sourceKey)?.let {
                effectiveBindings["sourceVariable"] = it
                customBindings["sourceVariable"] = it
            }
        }
        var script = rule

        script = replaceLegacyResultPutCalls(script, content, effectiveBindings, puts, sourceKey)

        script = replaceLegacySourcePutLoginHeader(script, effectiveBindings, puts)
        script = replaceLegacySourceSetVariable(script, effectiveBindings, puts)
        script = replaceLegacyGenericPut(script, effectiveBindings, puts, sourceKey)

        script = replaceLegacyBookVariableGets(script, effectiveBindings)

        script = replaceLegacySimpleGetters(script, effectiveBindings)

        script = replaceLegacyGetCalls(script, effectiveBindings, sourceKey)

        script = replaceLegacyMd5Calls(script, effectiveBindings)

        script = replaceLegacyBase64Calls(script, effectiveBindings)

        script = replaceLegacyLogCalls(script)

        script = replaceLegacyToastCalls(script)

        script = replaceLegacyEncodeURICalls(script, effectiveBindings)

        script = replaceLegacyToNumChapterCalls(script, effectiveBindings)

        script = replaceLegacyT2sCalls(script, effectiveBindings)

        script = replaceLegacyS2tCalls(script, effectiveBindings)

        script = replaceLegacyHexDecodeCalls(script, effectiveBindings)

        script = replaceLegacySourceKeyProperty(script, effectiveBindings)

        return PreparedScript(
            script = script.trim().ifEmpty { "result" },
            puts = puts
        )
    }

    private fun resolveBookVariable(key: String, effectiveBindings: Map<String, Any?>): Any? {
        val book = effectiveBindings["book"] as? Map<*, *>
        val variableMap = book?.get("variable") as? Map<*, *>
        return variableMap?.get(key) ?: effectiveBindings[key]
    }

    private fun replaceLegacyBookVariableGets(
        script: String,
        effectiveBindings: Map<String, Any?>
    ): String {
        val matches = findLegacyFunctionCalls(
            script = script,
            qualifiedName = "book.getVariableMap().get"
        )
        if (matches.isEmpty()) return script

        val result = StringBuilder()
        var lastIndex = 0
        for (match in matches) {
            result.append(script, lastIndex, match.startIndex)
            val key = match.arguments.parseLegacyStringLiteral()
            if (key == null) {
                result.append(script, match.startIndex, match.endIndex)
            } else {
                result.append(toJsLiteral(resolveBookVariable(key, effectiveBindings)))
            }
            lastIndex = match.endIndex
        }
        result.append(script.substring(lastIndex))
        return result.toString()
    }

    private fun replaceLegacySimpleGetters(
        script: String,
        effectiveBindings: Map<String, Any?>
    ): String {
        return replaceLegacyCodeMatches(script, legacySimpleGetterPattern) { match ->
            toJsLiteral(
                resolveLegacyGetter(
                    target = match.groupValues[1],
                    getter = match.groupValues[2],
                    effectiveBindings = effectiveBindings
                )
            )
        }
    }

    private fun replaceLegacySourceKeyProperty(
        script: String,
        effectiveBindings: Map<String, Any?>
    ): String {
        return replaceLegacyCodeMatches(script, legacySourceKeyPropertyPattern) {
            toJsLiteral(effectiveBindings["sourceUrl"])
        }
    }

    private suspend fun replaceLegacySourcePutLoginHeader(
        script: String,
        effectiveBindings: MutableMap<String, Any?>,
        puts: MutableList<LegacyPut>
    ): String {
        val matches = findLegacyFunctionCalls(
            script = script,
            qualifiedName = "source.putLoginHeader",
            consumeStatementSemicolon = true
        )
        if (matches.isEmpty()) return script

        val result = StringBuilder()
        var lastIndex = 0
        for (match in matches) {
            result.append(script, lastIndex, match.startIndex)
            val expression = match.arguments.trim()
            val header = executeExpressionAsString(expression, effectiveBindings)
            val sourceKey = source?.bookSourceUrl
            if (!sourceKey.isNullOrBlank()) {
                sourceStateStore?.putLoginHeader(sourceKey, header)
            }
            effectiveBindings["loginHeader"] = header
            customBindings["loginHeader"] = header
            puts += LegacyPut(
                key = "loginHeader",
                value = header
            )
            lastIndex = match.endIndex
        }
        result.append(script.substring(lastIndex))
        return result.toString()
    }

    private suspend fun replaceLegacySourceSetVariable(
        script: String,
        effectiveBindings: MutableMap<String, Any?>,
        puts: MutableList<LegacyPut>
    ): String {
        val matches = findLegacyFunctionCalls(
            script = script,
            qualifiedName = "source.setVariable",
            consumeStatementSemicolon = true
        )
        if (matches.isEmpty()) return script

        val result = StringBuilder()
        var lastIndex = 0
        val sourceKey = source?.bookSourceUrl
        for (match in matches) {
            result.append(script, lastIndex, match.startIndex)
            val args = splitTopLevelArguments(match.arguments)
            val value = if (args.size >= 2) {
                val key = executeExpressionAsString(args[0], effectiveBindings)
                val entryValue = executeExpressionAsString(args[1], effectiveBindings)
                if (!sourceKey.isNullOrBlank() && key.isNotBlank()) {
                    sourceStateStore?.putSourceVariable(sourceKey, key, entryValue)
                }
                if (sourceKey.isNullOrBlank()) {
                    entryValue
                } else {
                    sourceStateStore?.getSourceVariable(sourceKey).orEmpty()
                }
            } else {
                val expression = args.firstOrNull().orEmpty()
                val variable = executeExpressionAsString(expression, effectiveBindings)
                if (!sourceKey.isNullOrBlank()) {
                    sourceStateStore?.setSourceVariable(sourceKey, variable)
                }
                variable
            }
            effectiveBindings["sourceVariable"] = value
            customBindings["sourceVariable"] = value
            puts += LegacyPut(
                key = "sourceVariable",
                value = value
            )
            lastIndex = match.endIndex
        }
        result.append(script.substring(lastIndex))
        return result.toString()
    }

    private suspend fun replaceLegacyGenericPut(
        script: String,
        effectiveBindings: MutableMap<String, Any?>,
        puts: MutableList<LegacyPut>,
        sourceKey: String?
    ): String {
        val matches = (findLegacyFunctionCalls(
            script = script,
            qualifiedName = "java.put",
            consumeStatementSemicolon = true
        ) + findLegacyFunctionCalls(
            script = script,
            qualifiedName = "source.put",
            consumeStatementSemicolon = true
        )).sortedBy { it.startIndex }
        if (matches.isEmpty()) return script

        val result = StringBuilder()
        var lastIndex = 0
        for (match in matches) {
            if (match.startIndex < lastIndex) {
                continue
            }
            result.append(script, lastIndex, match.startIndex)
            val args = splitTopLevelArguments(match.arguments)
            val key = args.firstOrNull()?.parseLegacyStringLiteral()
            if (key == null || args.size < 2) {
                result.append(script, match.startIndex, match.endIndex)
                lastIndex = match.endIndex
                continue
            }
            val expression = args[1].trim()
            val value = executeExpressionAsString(expression, effectiveBindings)
            if (!sourceKey.isNullOrBlank()) {
                sourceStateStore?.putStoredValue(sourceKey, key, value)
                puts += LegacyPut(
                    key = storedValueBindingKey(key),
                    value = value
                )
            }
            effectiveBindings[key] = value
            customBindings[key] = value
            puts += LegacyPut(
                key = key,
                value = value
            )
            lastIndex = match.endIndex
        }
        result.append(script.substring(lastIndex))
        return result.toString()
    }

    private suspend fun replaceLegacyResultPutCalls(
        script: String,
        content: String,
        effectiveBindings: MutableMap<String, Any?>,
        puts: MutableList<LegacyPut>,
        sourceKey: String?
    ): String {
        val matches = findLegacyFunctionCalls(
            script = script,
            qualifiedName = "java.put",
            consumeStatementSemicolon = true
        )
        if (matches.isEmpty()) return script

        val result = StringBuilder()
        var lastIndex = 0
        for (match in matches) {
            result.append(script, lastIndex, match.startIndex)
            val args = splitTopLevelArguments(match.arguments)
            val key = args.firstOrNull()?.parseLegacyStringLiteral()
            if (key == null || args.size != 2 || args[1].trim() != "result") {
                result.append(script, match.startIndex, match.endIndex)
                lastIndex = match.endIndex
                continue
            }
            effectiveBindings[key] = content
            if (!sourceKey.isNullOrBlank()) {
                sourceStateStore?.putStoredValue(sourceKey, key, content)
                puts += LegacyPut(
                    key = storedValueBindingKey(key),
                    value = content
                )
            }
            puts += LegacyPut(
                key = key,
                value = content
            )
            lastIndex = match.endIndex
        }
        result.append(script.substring(lastIndex))
        return result.toString()
    }

    private suspend fun replaceLegacyGetCalls(
        script: String,
        effectiveBindings: Map<String, Any?>,
        sourceKey: String?
    ): String {
        val matches = (findLegacyFunctionCalls(
            script = script,
            qualifiedName = "java.get"
        ) + findLegacyFunctionCalls(
            script = script,
            qualifiedName = "source.get"
        )).sortedBy { it.startIndex }
        if (matches.isEmpty()) return script

        val result = StringBuilder()
        var lastIndex = 0
        for (match in matches) {
            if (match.startIndex < lastIndex) {
                continue
            }
            result.append(script, lastIndex, match.startIndex)
            val key = match.arguments.parseLegacyStringLiteral()
            if (key == null) {
                result.append(script, match.startIndex, match.endIndex)
                lastIndex = match.endIndex
                continue
            }
            val stored = if (sourceKey.isNullOrBlank()) {
                null
            } else {
                sourceStateStore?.getStoredValue(sourceKey, key)
            }
            result.append(toJsLiteral(stored ?: effectiveBindings[key]))
            lastIndex = match.endIndex
        }
        result.append(script.substring(lastIndex))
        return result.toString()
    }

    private fun resolveLegacyGetter(
        target: String,
        getter: String,
        effectiveBindings: Map<String, Any?>
    ): Any? {
        return when (target) {
            "source" -> when (getter) {
                "LoginHeader" -> effectiveBindings["loginHeader"]
                "LoginInfo" -> effectiveBindings["loginInfo"]
                "Variable" -> effectiveBindings["sourceVariable"]
                "Key", "BookSourceUrl" -> effectiveBindings["sourceUrl"]
                "BookSourceComment" -> source?.bookSourceComment
                else -> null
            }

            "book" -> {
                val book = effectiveBindings["book"] as? Map<*, *>
                when (getter) {
                    "Name" -> book?.get("name") ?: effectiveBindings["bookName"]
                    "Author" -> book?.get("author") ?: effectiveBindings["bookAuthor"]
                    "CoverUrl" -> book?.get("coverUrl") ?: effectiveBindings["bookCoverUrl"]
                    "BookUrl" -> book?.get("bookUrl") ?: effectiveBindings["bookUrl"]
                    "TocUrl" -> book?.get("tocUrl") ?: effectiveBindings["bookTocUrl"]
                    "TotalChapterNum" -> book?.get("totalChapterNum") ?: effectiveBindings["bookTotalChapterNum"]
                    "Variable" -> book?.get("variable")
                    else -> null
                }
            }

            "chapter" -> {
                val chapter = effectiveBindings["chapter"] as? Map<*, *>
                when (getter) {
                    "Index" -> chapter?.get("index") ?: effectiveBindings["chapterIndex"]
                    "Title" -> chapter?.get("title") ?: effectiveBindings["chapterTitle"]
                    "Url" -> chapter?.get("url") ?: effectiveBindings["chapterUrl"]
                    else -> null
                }
            }

            else -> null
        }
    }

    private fun toJsLiteral(value: Any?): String {
        return when (value) {
            null -> "\"\""
            is Number, is Boolean -> value.toString()
            else -> "\"${value.toString().escapeJsString()}\""
        }
    }

    @OptIn(kotlin.io.encoding.ExperimentalEncodingApi::class)
    private suspend fun replaceLegacyBase64Calls(
        script: String,
        effectiveBindings: Map<String, Any?>
    ): String {
        var result = script

        // java.base64Decode(expr)
        result = replaceLegacyUnaryStringCalls(
            script = result,
            qualifiedName = "java.base64Decode",
            effectiveBindings = effectiveBindings
        ) { encoded ->
            try {
                kotlin.io.encoding.Base64.decode(encoded).decodeToString()
            } catch (_: Exception) {
                ""
            }
        }

        // java.base64Encode(expr)
        result = replaceLegacyUnaryStringCalls(
            script = result,
            qualifiedName = "java.base64Encode",
            effectiveBindings = effectiveBindings
        ) { plainText ->
            kotlin.io.encoding.Base64.encode(plainText.encodeToByteArray())
        }

        return result
    }

    private fun replaceLegacyLogCalls(script: String): String {
        val matches = findLegacyFunctionCalls(
            script = script,
            qualifiedName = "java.log",
            consumeStatementSemicolon = true
        )
        if (matches.isEmpty()) return script

        val result = StringBuilder()
        var lastIndex = 0
        for (match in matches) {
            result.append(script, lastIndex, match.startIndex)
            val expression = match.arguments.trim()
            result.append('(')
            result.append(expression)
            result.append(')')
            lastIndex = match.endIndex
        }
        result.append(script.substring(lastIndex))
        return result.toString()
    }

    private fun replaceLegacyToastCalls(script: String): String {
        val matches = listOf(
            "java.toast",
            "java.Toast",
            "java.longtoast",
            "java.longToast"
        ).flatMap { qualifiedName ->
            findLegacyFunctionCalls(
                script = script,
                qualifiedName = qualifiedName,
                consumeStatementSemicolon = true
            )
        }.sortedBy { it.startIndex }
        if (matches.isEmpty()) return script

        val result = StringBuilder()
        var lastIndex = 0
        for (match in matches) {
            if (match.startIndex < lastIndex) {
                continue
            }
            result.append(script, lastIndex, match.startIndex)
            lastIndex = match.endIndex
        }
        result.append(script.substring(lastIndex))
        return result.toString()
    }

    private suspend fun replaceLegacyEncodeURICalls(
        script: String,
        effectiveBindings: Map<String, Any?>
    ): String {
        return replaceLegacyUnaryStringCalls(
            script = script,
            qualifiedName = "java.encodeURI",
            effectiveBindings = effectiveBindings
        ) { value ->
            value.encodeURLQueryComponent()
        }
    }

    private suspend fun replaceLegacyToNumChapterCalls(
        script: String,
        effectiveBindings: Map<String, Any?>
    ): String {
        return replaceLegacyUnaryStringCalls(
            script = script,
            qualifiedName = "java.toNumChapter",
            effectiveBindings = effectiveBindings
        ) { value ->
            toNumChapter(value)
        }
    }

    private suspend fun replaceLegacyT2sCalls(
        script: String,
        effectiveBindings: Map<String, Any?>
    ): String {
        return replaceLegacyUnaryStringCalls(
            script = script,
            qualifiedName = "java.t2s",
            effectiveBindings = effectiveBindings
        ) { value ->
            ChineseConverter.t2s(value)
        }
    }

    private suspend fun replaceLegacyS2tCalls(
        script: String,
        effectiveBindings: Map<String, Any?>
    ): String {
        return replaceLegacyUnaryStringCalls(
            script = script,
            qualifiedName = "java.s2t",
            effectiveBindings = effectiveBindings
        ) { value ->
            ChineseConverter.s2t(value)
        }
    }

    private suspend fun replaceLegacyHexDecodeCalls(
        script: String,
        effectiveBindings: Map<String, Any?>
    ): String {
        return replaceLegacyUnaryStringCalls(
            script = script,
            qualifiedName = "java.hexDecodeToString",
            effectiveBindings = effectiveBindings
        ) { hexStr ->
            try {
                hexStr.chunked(2).map { it.toInt(16).toByte() }.toByteArray().decodeToString()
            } catch (_: Exception) { "" }
        }
    }

    private suspend fun replaceLegacyMd5Calls(
        script: String,
        effectiveBindings: Map<String, Any?>
    ): String {
        return replaceLegacyUnaryStringCalls(
            script = script,
            qualifiedName = "java.md5Encode",
            effectiveBindings = effectiveBindings
        ) { hashInput ->
            hashInput.md5Hex()
        }
    }

    private suspend fun replaceLegacyUnaryStringCalls(
        script: String,
        qualifiedName: String,
        effectiveBindings: Map<String, Any?>,
        transform: (String) -> String
    ): String {
        val matches = findLegacyFunctionCalls(
            script = script,
            qualifiedName = qualifiedName
        )
        if (matches.isEmpty()) return script

        val result = StringBuilder()
        var lastIndex = 0
        for (match in matches) {
            result.append(script, lastIndex, match.startIndex)
            val expression = match.arguments.trim()
            val value = executeExpressionAsString(expression, effectiveBindings)
            result.append(toJsLiteral(transform(value)))
            lastIndex = match.endIndex
        }
        result.append(script.substring(lastIndex))
        return result.toString()
    }

    private fun String.escapeJsString(): String {
        return this
            .replace("\\", "\\\\")
            .replace("\"", "\\\"")
            .replace("\n", "\\n")
            .replace("\r", "\\r")
            .replace("\t", "\\t")
    }

    private suspend fun executeExpressionAsString(
        expression: String,
        effectiveBindings: Map<String, Any?>
    ): String {
        val execution = prepareJsRuleExecution(expression, effectiveBindings)
        return jsExecutor.executeAsString(execution.script, execution.bindings, "")
    }

    private fun splitTopLevelArguments(text: String): List<String> {
        val result = mutableListOf<String>()
        var quote: Char? = null
        var escaped = false
        var depth = 0
        var start = 0
        text.forEachIndexed { index, char ->
            if (escaped) {
                escaped = false
                return@forEachIndexed
            }
            if (quote != null) {
                if (char == '\\') {
                    escaped = true
                } else if (char == quote) {
                    quote = null
                }
                return@forEachIndexed
            }
            when (char) {
                '\'', '"', '`' -> quote = char
                '(', '[', '{' -> depth++
                ')', ']', '}' -> if (depth > 0) depth--
                ',' -> if (depth == 0) {
                    result += text.substring(start, index).trim()
                    start = index + 1
                }
            }
        }
        result += text.substring(start).trim()
        return result
    }

    private fun findLegacyFunctionCalls(
        script: String,
        qualifiedName: String,
        consumeStatementSemicolon: Boolean = false
    ): List<LegacyCallMatch> {
        val result = mutableListOf<LegacyCallMatch>()
        var quote: Char? = null
        var escapeNext = false
        var inLineComment = false
        var inBlockComment = false
        var index = 0
        while (index < script.length) {
            val char = script[index]
            if (inLineComment) {
                if (char == '\n' || char == '\r') {
                    inLineComment = false
                }
                index++
                continue
            }
            if (inBlockComment) {
                if (char == '*' && index + 1 < script.length && script[index + 1] == '/') {
                    inBlockComment = false
                    index += 2
                } else {
                    index++
                }
                continue
            }
            if (quote != null) {
                if (escapeNext) {
                    escapeNext = false
                } else if (char == '\\') {
                    escapeNext = true
                } else if (char == quote) {
                    quote = null
                }
                index++
                continue
            }
            if (char == '/' && index + 1 < script.length) {
                when (script[index + 1]) {
                    '/' -> {
                        inLineComment = true
                        index += 2
                        continue
                    }
                    '*' -> {
                        inBlockComment = true
                        index += 2
                        continue
                    }
                }
            }
            if (char == '\'' || char == '"' || char == '`') {
                quote = char
                index++
                continue
            }
            if (isLegacyCalleeAt(script, index, qualifiedName)) {
                val openIndex = script.indexOfNextNonWhitespace(index + qualifiedName.length)
                if (openIndex >= 0 && script[openIndex] == '(') {
                    val closeIndex = findBalancedCallEnd(script, openIndex)
                    if (closeIndex >= 0) {
                        val endIndex = if (consumeStatementSemicolon) {
                            script.consumeTrailingSemicolon(closeIndex + 1)
                        } else {
                            closeIndex + 1
                        }
                        result += LegacyCallMatch(
                            startIndex = index,
                            endIndex = endIndex,
                            arguments = script.substring(openIndex + 1, closeIndex)
                        )
                        index = endIndex
                        continue
                    }
                }
            }
            index++
        }
        return result
    }

    private fun isLegacyCalleeAt(script: String, index: Int, qualifiedName: String): Boolean {
        if (!script.regionMatches(index, qualifiedName, 0, qualifiedName.length)) {
            return false
        }
        val before = script.getOrNull(index - 1)
        if (before != null && (before.isLetterOrDigit() || before == '_' || before == '$' || before == '.')) {
            return false
        }
        val after = script.getOrNull(index + qualifiedName.length)
        return after == null || after.isWhitespace() || after == '('
    }

    private fun String.indexOfNextNonWhitespace(startIndex: Int): Int {
        var index = startIndex
        while (index < length && this[index].isWhitespace()) {
            index++
        }
        return if (index < length) index else -1
    }

    private fun String.consumeTrailingSemicolon(startIndex: Int): Int {
        var index = startIndex
        while (index < length && this[index].isWhitespace() && this[index] != '\n' && this[index] != '\r') {
            index++
        }
        return if (index < length && this[index] == ';') index + 1 else startIndex
    }

    private fun findBalancedCallEnd(script: String, openIndex: Int): Int {
        var quote: Char? = null
        var escapeNext = false
        var depth = 1
        var index = openIndex + 1
        while (index < script.length) {
            val char = script[index]
            if (quote != null) {
                if (escapeNext) {
                    escapeNext = false
                } else if (char == '\\') {
                    escapeNext = true
                } else if (char == quote) {
                    quote = null
                }
                index++
                continue
            }
            when (char) {
                '\'', '"', '`' -> quote = char
                '(' -> depth++
                ')' -> {
                    depth--
                    if (depth == 0) {
                        return index
                    }
                }
            }
            index++
        }
        return -1
    }

    private fun String.parseLegacyStringLiteral(): String? {
        val trimmed = trim()
        if (trimmed.length < 2) return null
        val quote = trimmed.first()
        if ((quote != '\'' && quote != '"') || trimmed.last() != quote) return null
        val value = StringBuilder()
        var escaped = false
        for (index in 1 until trimmed.lastIndex) {
            val char = trimmed[index]
            if (escaped) {
                value.append(
                    when (char) {
                        'n' -> '\n'
                        'r' -> '\r'
                        't' -> '\t'
                        else -> char
                    }
                )
                escaped = false
            } else if (char == '\\') {
                escaped = true
            } else {
                value.append(char)
            }
        }
        if (escaped) {
            value.append('\\')
        }
        return value.toString()
    }

    /**
     * Set a custom variable
     *
     * @param name Variable name
     * @param value Variable value
     */
    fun setVariable(name: String, value: Any?) {
        customBindings[name] = value
    }

    /**
     * Set multiple variables
     *
     * @param vars Map of variable names to values
     */
    fun setVariables(vars: Map<String, Any?>) {
        customBindings.putAll(vars)
    }

    /**
     * Clear all custom variables
     */
    fun clearVariables() {
        customBindings.clear()
        bindings.clear()
    }

    /**
     * Get all current bindings
     */
    fun getBindings(): Map<String, Any?> {
        return bindings.toMap()
    }

    fun getCustomBindings(): Map<String, Any?> {
        return customBindings.toMap()
    }

    /**
     * Test if JS code is valid
     *
     * @param code JavaScript code
     * @return True if valid
     */
    suspend fun isValid(code: String): Boolean {
        return jsExecutor.isValid(code)
    }

    /**
     * Execute JS and get string result
     */
    suspend fun executeAsString(
        code: String,
        content: String,
        transientBindings: Map<String, Any?> = emptyMap(),
        defaultValue: String = ""
    ): String {
        val result = evaluate(code, content, transientBindings = transientBindings)
        return when (result) {
            is AnalyzeResult.StringVal -> result.value
            else -> defaultValue
        }
    }

    /**
     * Execute JS and get int result
     */
    suspend fun executeAsInt(
        code: String,
        content: String,
        transientBindings: Map<String, Any?> = emptyMap(),
        defaultValue: Int = 0
    ): Int {
        val result = evaluate(code, content, transientBindings = transientBindings)
        return when (result) {
            is AnalyzeResult.IntVal -> result.value
            is AnalyzeResult.StringVal -> result.value.toIntOrNull() ?: defaultValue
            else -> defaultValue
        }
    }

    /**
     * Execute JS and get boolean result
     */
    suspend fun executeAsBoolean(
        code: String,
        content: String,
        transientBindings: Map<String, Any?> = emptyMap(),
        defaultValue: Boolean = false
    ): Boolean {
        val result = evaluate(code, content, transientBindings = transientBindings)
        return when (result) {
            is AnalyzeResult.BoolVal -> result.value
            is AnalyzeResult.StringVal -> {
                val str = result.value
                str.equals("true", ignoreCase = true) ||
                        str.equals("1", ignoreCase = true)
            }
            else -> defaultValue
        }
    }

    companion object {
        private val legacySimpleGetterPattern =
            Regex("""(source|book|chapter)\.get([A-Z][A-Za-z0-9_]*)\(\)""")
        private val legacySourceKeyPropertyPattern =
            Regex("""source\.key(?!\w)""")

        private fun storedValueBindingKey(key: String): String = "stored:$key"

        /**
         * Helper to build JS variable map from book source
         */
        fun buildVariables(source: BookSource): Map<String, Any?> {
            val vars = mutableMapOf<String, Any?>()

            vars["sourceUrl"] = source.bookSourceUrl
            vars["sourceName"] = source.bookSourceName
            vars["header"] = source.header
            vars["loginUrl"] = source.loginUrl
            vars["charset"] = "UTF-8"

            return vars
        }
    }
}
