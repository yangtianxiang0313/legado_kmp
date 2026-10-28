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
 * Adapted from JSONParserBase, JSONParserMemory and JSONParserString in
 * json-smart 2.6.0, with MODE_PERMISSIVE and without ACCEPT_INCOMPLETE.
 * Source: https://github.com/netplex/json-smart-v2/tree/v2.6.0/json-smart/src/main/java/net/minidev/json/parser
 */

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** The String-input branches used by Jayway's default JsonSmart provider. */
internal object JsonPathJsonReader {
    fun parse(
        source: String,
        onNumber: (JsonPrimitive, JsonPathNumberKind) -> Unit = { _, _ -> }
    ): JsonElement = Reader(source, onNumber).readDocument()

    fun parseComplete(source: String): JsonElement = Reader(source) { _, _ -> }.readDocument(requireComplete = true)

    private const val EOI = '\u001a'
    private const val MAX_STOP = 126
    private const val MAX_DEPTH = 400

    private enum class Stop {
        ROOT,
        ARRAY,
        KEY,
        VALUE;

        fun contains(char: Char): Boolean = char == EOI || when (this) {
            ROOT -> false
            ARRAY -> char == ',' || char == ']'
            KEY -> char == ':'
            VALUE -> char == ',' || char == '}'
        }
    }

    private class Reader(
        private val source: String,
        private val onNumber: (JsonPrimitive, JsonPathNumberKind) -> Unit
    ) {
        private var position = -1
        private var current = EOI
        private var depth = 0

        fun readDocument(requireComplete: Boolean = false): JsonElement {
            // Jayway rejects an empty source, but whitespace may become an empty root token.
            if (source.isEmpty()) unexpectedEof(0)
            read()
            skipValueSpace()
            // MODE_PERMISSIVE deliberately does not inspect data after the first root value.
            val result = readValue(Stop.ROOT)
            if (requireComplete) {
                skipSpace()
                if (current != EOI) unexpectedChar()
            }
            return result
        }

        private fun readValue(stop: Stop): JsonElement {
            skipValueSpace()
            return when (current) {
                ':', '}', ']' -> unexpectedChar()
                '{' -> readObject()
                '[' -> readArray()
                '"', '\'' -> JsonPrimitive(readString())
                'n' -> readKeyword(stop, "null", JsonNull)
                't' -> readKeyword(stop, "true", JsonPrimitive(true))
                'f' -> readKeyword(stop, "false", JsonPrimitive(false))
                'N' -> {
                    val token = readBare(stop)
                    if (token == "NaN") numberOrString(token) else JsonPrimitive(token)
                }
                EOI -> {
                    // readFirst has no EOI case; readMain rejects it inside containers.
                    if (stop != Stop.ROOT) unexpectedEof()
                    JsonPrimitive(readBare(stop))
                }
                '-', in '0'..'9' -> readNumber(stop)
                else -> JsonPrimitive(readBare(stop))
            }
        }

        private fun readKeyword(stop: Stop, keyword: String, value: JsonElement): JsonElement {
            val token = readBare(stop)
            return if (token == keyword) value else JsonPrimitive(token)
        }

        private fun readObject(): JsonObject {
            enterContainer()
            val values = linkedMapOf<String, JsonElement>()
            read()
            while (true) {
                when (current) {
                    ' ', '\r', '\n', '\t', ',' -> read()
                    ':', ']', '[', '{' -> unexpectedChar()
                    '}' -> {
                        leaveContainer()
                        return JsonObject(values)
                    }
                    else -> {
                        val key = if (current == '"' || current == '\'') {
                            readString()
                        } else {
                            readBare(Stop.KEY)
                        }
                        skipSpace()
                        if (current != ':') {
                            if (current == EOI) unexpectedEof()
                            unexpectedChar()
                        }
                        readNoEnd()
                        values[key] = readValue(Stop.VALUE)
                        skipSpace()
                        when (current) {
                            '}' -> {
                                leaveContainer()
                                return JsonObject(values)
                            }
                            EOI -> unexpectedEof()
                            ',' -> read()
                            else -> unexpectedChar()
                        }
                    }
                }
            }
        }

        private fun readArray(): JsonArray {
            enterContainer()
            val values = mutableListOf<JsonElement>()
            read()
            while (true) {
                when (current) {
                    ' ', '\r', '\n', '\t', ',' -> read()
                    ']' -> {
                        leaveContainer()
                        return JsonArray(values)
                    }
                    ':', '}' -> unexpectedChar()
                    EOI -> unexpectedEof()
                    // JsonSmart also accepts adjacent array values without a comma.
                    else -> values.add(readValue(Stop.ARRAY))
                }
            }
        }

        private fun enterContainer() {
            if (depth >= MAX_DEPTH) {
                throw IllegalArgumentException("JSON nesting exceeds $MAX_DEPTH at position $position")
            }
            depth++
        }

        private fun leaveContainer() {
            depth--
            read()
        }

        private fun readNumber(stop: Stop): JsonElement {
            val start = position
            read()
            skipDigits()
            if (current != '.' && current != 'E' && current != 'e') {
                return finishNumber(start, stop)
            }
            if (current == '.') {
                read()
                skipDigits()
            }
            if (current != 'E' && current != 'e') return finishNumber(start, stop)
            read()
            if (current == '+' || current == '-' || current in '0'..'9') {
                read()
                skipDigits()
                return finishNumber(start, stop)
            }
            // An exponent without its first sign/digit is a bare string ("2e", not "2e+").
            skipBare(stop)
            return JsonPrimitive(extractTrim(start, position))
        }

        private fun finishNumber(start: Int, stop: Stop): JsonElement {
            skipSpace()
            // The original ASCII stop-table guard is significant: >= 126 ends a number,
            // whereas a non-stopping ASCII suffix turns the whole token into a string.
            if (current.code < MAX_STOP && !stop.contains(current)) {
                skipBare(stop)
                return JsonPrimitive(extractTrim(start, position))
            }
            return numberOrString(extractTrim(start, position))
        }

        private fun numberOrString(token: String): JsonPrimitive {
            val number = JsonPathNumberSupport.parseToken(token) ?: return JsonPrimitive(token)
            onNumber(number.value, number.kind)
            return number.value
        }

        private fun readBare(stop: Stop): String {
            val start = position
            skipBare(stop)
            return extractTrim(start, position)
        }

        private fun skipBare(stop: Stop) {
            while (!stop.contains(current)) read()
        }

        private fun extractTrim(start: Int, end: Int): String {
            var first = start
            var last = end
            // JSONParserString retains one character when a non-empty token is all whitespace.
            while (first < last - 1 && isJavaWhitespace(source[first])) first++
            while (last - 1 > first && isJavaWhitespace(source[last - 1])) last--
            return source.substring(first, last)
        }

        private fun readString(): String {
            val quote = current
            val end = source.indexOf(quote, position + 1)
            if (end == -1) unexpectedEof(source.length)
            val plain = source.substring(position + 1, end)
            if ('\\' !in plain) {
                // IGNORE_CONTROL_CHAR bypasses all checks in the memory fast path:
                // raw controls, DEL and even an embedded EOI remain in the substring.
                position = end
                read()
                return plain
            }
            return readEscapedString(quote)
        }

        private fun readEscapedString(quote: Char): String {
            val result = StringBuilder()
            while (true) {
                read()
                when (current) {
                    EOI -> unexpectedEof()
                    '"', '\'' -> {
                        if (current == quote) {
                            read()
                            return result.toString()
                        }
                        result.append(current)
                    }
                    '\\' -> {
                        read()
                        when (current) {
                            't' -> result.append('\t')
                            'n' -> result.append('\n')
                            'r' -> result.append('\r')
                            'f' -> result.append('\u000c')
                            'b' -> result.append('\b')
                            '\\', '/', '\'', '"' -> result.append(current)
                            'u' -> result.append(readHex(4))
                            'x' -> result.append(readHex(2))
                            // No default append: both the slash and an unknown escape vanish.
                            else -> Unit
                        }
                    }
                    // Unlike the fast path, readString2 drops raw controls and DEL.
                    in '\u0000'..'\u001f', '\u007f' -> Unit
                    else -> result.append(current)
                }
            }
        }

        private fun readHex(count: Int): Char {
            var value = 0
            repeat(count) {
                read()
                val digit = when (current) {
                    in '0'..'9' -> current - '0'
                    in 'A'..'F' -> current - 'A' + 10
                    in 'a'..'f' -> current - 'a' + 10
                    EOI -> unexpectedEof()
                    else -> throw IllegalArgumentException("Invalid hex escape at position $position")
                }
                value = value * 16 + digit
            }
            return value.toChar()
        }

        private fun skipDigits() {
            while (current in '0'..'9') read()
        }

        private fun skipValueSpace() {
            while (current == ' ' || current == '\r' || current == '\n' || current == '\t') read()
        }

        private fun skipSpace() {
            while (current <= ' ' && current != EOI) read()
        }

        private fun read() {
            position++
            current = if (position >= source.length) EOI else source[position]
        }

        private fun readNoEnd() {
            read()
            if (position >= source.length) unexpectedEof()
        }

        private fun unexpectedEof(at: Int = position): Nothing =
            throw IllegalArgumentException("Unexpected end of JSON input at position $at")

        private fun unexpectedChar(): Nothing =
            throw IllegalArgumentException(
                "Unexpected JSON character U+${current.code.toString(16).padStart(4, '0')} at position $position"
            )
    }

    // Character.isWhitespace(char), excluding NBSP, FIGURE SPACE and NARROW NO-BREAK SPACE.
    // Kotlin's Char.isWhitespace also accepts those non-breaking space characters.
    private fun isJavaWhitespace(char: Char): Boolean = when (char) {
        in '\u0009'..'\u000d', in '\u001c'..'\u0020', '\u1680',
        in '\u2000'..'\u2006', in '\u2008'..'\u200a', '\u2028', '\u2029',
        '\u205f', '\u3000' -> true
        else -> false
    }
}
