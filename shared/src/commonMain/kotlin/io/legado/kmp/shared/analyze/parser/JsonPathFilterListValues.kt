package io.legado.kmp.shared.analyze.parser

/*
 * Copyright 2011 the original author or authors.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * List conversion and string unescaping adapted from Jayway JsonPath 2.10.0.
 */

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive

/** ValueListNode eagerly converts every element, unlike Java collection equality in JsonNode. */
internal object JsonPathFilterListValues {
    fun convert(value: JsonElement?, literals: JsonPathFilterLiterals): List<JsonElement?>? {
        if (!literals.isJsonNode(value)) return null
        val array = literals.parse(value) as? JsonArray ?: return null
        return array.map { element ->
            require(element is JsonPrimitive) { "Jayway cannot convert a nested collection to a list ValueNode" }
            if (element.isString) stringNode(element, literals) else {
                JsonPathFilterValues.requireNumber(element)
                element
            }
        }
    }

    private fun stringNode(value: JsonPrimitive, literals: JsonPathFilterLiterals): JsonElement? {
        val source = value.content
        val trimmed = source.trim { it <= ' ' }
        // PathNodes in a list retain object identity; none equals a separately constructed ValueNode.
        if ((trimmed.startsWith('$') || trimmed.startsWith('@')) && JsonPathBackend.isValidPath(trimmed)) return null
        if ((trimmed.startsWith('[') && trimmed.endsWith(']')) ||
            (trimmed.startsWith('{') && trimmed.endsWith('}'))
        ) {
            val json = try {
                JsonPathJsonReader.parse(trimmed)
                true
            } catch (_: Exception) {
                false
            }
            if (json) return literals.literal(trimmed, Any())
        }
        val unquoted = if (source.length > 1 &&
            ((source.first() == '\'' && source.last() == '\'') || (source.first() == '"' && source.last() == '"'))
        ) source.substring(1, source.lastIndex) else source
        return JsonPrimitive(unescape(unquoted))
    }

    // Jayway Utils.unescape (Apache-2.0): unknown escapes lose the slash, incomplete Unicode is dropped.
    // https://github.com/json-path/JsonPath/blob/json-path-2.10.0/json-path/src/main/java/com/jayway/jsonpath/internal/Utils.java
    private fun unescape(source: String): String = buildString {
        var index = 0
        while (index < source.length) {
            val char = source[index++]
            if (char != '\\' || index == source.length) {
                append(char)
                continue
            }
            when (val escaped = source[index++]) {
                'r' -> append('\r')
                'f' -> append('\u000C')
                't' -> append('\t')
                'n' -> append('\n')
                'b' -> append('\b')
                'u' -> {
                    if (source.length - index < 4) break
                    val code = source.substring(index, index + 4).toIntOrNull(16)
                    require(code != null) { "Invalid Jayway Unicode escape" }
                    append(code.toChar())
                    index += 4
                }
                else -> append(escaped)
            }
        }
    }
}
