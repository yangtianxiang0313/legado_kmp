package io.legado.kmp.shared.analyze.parser

/*
 * Copyright 2011-2025 JSON-SMART authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * Default JSON serialization and escaping adapted from JSONValue, JSONStyle,
 * JStylerObj.Escape4Web, JSONArray and reader/JsonWriter in json-smart 2.6.0.
 * Source: https://github.com/netplex/json-smart-v2/tree/v2.6.0/json-smart/src/main/java/net/minidev/json
 */

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** Java Map.toString differs from JSONArray.toString, which uses default JSONStyle. */
internal object JsonPathValueStrings {
    fun javaString(
        value: JsonElement,
        numbers: JsonPathNumberTypes,
        isKeySet: (JsonElement) -> Boolean = { false },
    ): String = when (value) {
        JsonNull -> "null"
        is JsonPrimitive -> numbers.string(value)
        is JsonObject -> value.entries.joinToString(", ", "{", "}") { (key, item) ->
            "$key=${javaString(item, numbers, isKeySet)}"
        }
        is JsonArray -> if (isKeySet(value)) {
            value.joinToString(", ", "[", "]") { javaString(it, numbers, isKeySet) }
        } else json(value, numbers)
    }

    /** JSONValue's default NO_COMPRESS style: quoted keys/strings, retained nulls, no spaces. */
    fun json(value: JsonElement, numbers: JsonPathNumberTypes): String = when (value) {
        JsonNull -> "null"
        is JsonPrimitive -> if (value.isString) quote(value.content) else {
            // The 2.6.0 Double/Float writers null infinities only; NaN remains a bare token.
            when (val text = numbers.string(value)) {
                "Infinity", "-Infinity" -> "null"
                else -> text
            }
        }
        is JsonArray -> value.joinToString(",", "[", "]") { json(it, numbers) }
        is JsonObject -> value.entries.joinToString(",", "{", "}") { (key, item) ->
            "${quote(key)}:${json(item, numbers)}"
        }
    }

    private const val HEX = "0123456789ABCDEF"

    private fun quote(value: String): String = buildString {
        append('"')
        // Escape4Web operates on UTF-16 chars, leaving all other code units unchanged.
        for (char in value) {
            when (char) {
                '"' -> append("\\\"")
                '\\' -> append("\\\\")
                '/' -> append("\\/")
                '\b' -> append("\\b")
                '\u000c' -> append("\\f")
                '\n' -> append("\\n")
                '\r' -> append("\\r")
                '\t' -> append("\\t")
                in '\u0000'..'\u001f', in '\u007f'..'\u009f', in '\u2000'..'\u20ff' -> {
                    append("\\u")
                    append(HEX[(char.code ushr 12) and 0x0f])
                    append(HEX[(char.code ushr 8) and 0x0f])
                    append(HEX[(char.code ushr 4) and 0x0f])
                    append(HEX[char.code and 0x0f])
                }
                else -> append(char)
            }
        }
        append('"')
    }
}
