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
 * Number-token classification adapted from JSONParserMemory/JSONParserBase in
 * https://github.com/netplex/json-smart-v2/tree/v2.6.0/json-smart/src/main/java/net/minidev/json/parser
 */

import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.JsonUnquotedLiteral

internal enum class JsonPathNumberKind { INTEGER, LONG, BIG_INTEGER, DOUBLE, BIG_DECIMAL }

internal data class JsonPathParsedNumber(val value: JsonPrimitive, val kind: JsonPathNumberKind)

@OptIn(ExperimentalSerializationApi::class)
internal object JsonPathNumberSupport {
    private val decimalSyntax = Regex("[+-]?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)(?:[eE][+-]?[0-9]+)?")

    // The reader owns token boundaries and booleans/null. A null result means a bare string.
    fun parseToken(text: String): JsonPathParsedNumber? {
        val token = text.trim { it.isJavaWhitespace() }
        if (token == "NaN") return JsonPathParsedNumber(JsonPrimitive(Double.NaN), JsonPathNumberKind.DOUBLE)
        val first = token.firstOrNull() ?: return null
        if (first != '-' && first !in '0'..'9') return null

        // Match JSONParserMemory.readNumber, including its fallback after an incomplete exponent.
        var index = 1
        while (index < token.length && token[index] in '0'..'9') index++
        var floating = false
        if (token.getOrNull(index) == '.') {
            floating = true
            index++
            while (index < token.length && token[index] in '0'..'9') index++
        }
        if (token.getOrNull(index) == 'e' || token.getOrNull(index) == 'E') {
            floating = true
            index++
            val exponentFirst = token.getOrNull(index)
            if (exponentFirst != '+' && exponentFirst != '-' &&
                (exponentFirst == null || exponentFirst !in '0'..'9')
            ) return null
            index++
            while (index < token.length && token[index] in '0'..'9') index++
        }
        if (index != token.length) return null

        if (!floating) {
            // JsonSmart's integer accumulator also treats a solitary '-' as zero.
            return JsonPathParsedNumber(JsonUnquotedLiteral(integerString(token)), integerKind(token))
        }
        require(decimalSyntax.matches(token)) { "Invalid JsonSmart number: $token" }
        if (token.length > 18) {
            val decimal = decimalParts(token)
            require(decimal.exponent in Int.MIN_VALUE.toLong()..Int.MAX_VALUE.toLong()) {
                "BigDecimal exponent out of range: $token"
            }
            require(decimal.scale in Int.MIN_VALUE.toLong()..Int.MAX_VALUE.toLong()) {
                "BigDecimal scale out of range: $token"
            }
            return JsonPathParsedNumber(
                JsonUnquotedLiteral(JsonPathFilterValues.numberString(token)),
                JsonPathNumberKind.BIG_DECIMAL,
            )
        }
        return JsonPathParsedNumber(JsonPrimitive(doubleValue(token)), JsonPathNumberKind.DOUBLE)
    }

    internal fun integerKind(text: String): JsonPathNumberKind {
        // JsonSmart checks the original width before accumulating, including leading zeros.
        val maxLength = if (text.startsWith('-')) 20 else 19
        if (text.length > maxLength) return JsonPathNumberKind.BIG_INTEGER
        val number = (if (text == "-") 0L else text.toLongOrNull()) ?: return JsonPathNumberKind.BIG_INTEGER
        return if (number in Int.MIN_VALUE.toLong()..Int.MAX_VALUE.toLong()) {
            JsonPathNumberKind.INTEGER
        } else {
            JsonPathNumberKind.LONG
        }
    }

    fun string(value: JsonPrimitive, kind: JsonPathNumberKind): String {
        require(!value.isString) { "Expected a numeric JsonPrimitive" }
        return when (kind) {
            JsonPathNumberKind.INTEGER, JsonPathNumberKind.LONG, JsonPathNumberKind.BIG_INTEGER ->
                integerString(value.content)
            JsonPathNumberKind.DOUBLE -> doubleString(doubleValue(value.content))
            JsonPathNumberKind.BIG_DECIMAL -> {
                require(decimalSyntax.matches(value.content)) { "Invalid BigDecimal: ${value.content}" }
                JsonPathFilterValues.numberString(value.content)
            }
        }
    }

    fun intValue(value: JsonPrimitive, kind: JsonPathNumberKind): Int {
        require(!value.isString) { "Expected a numeric JsonPrimitive" }
        return when (kind) {
            JsonPathNumberKind.INTEGER, JsonPathNumberKind.LONG, JsonPathNumberKind.BIG_INTEGER ->
                decimalIntValue(integerString(value.content))
            JsonPathNumberKind.BIG_DECIMAL -> decimalIntValue(value.content)
            JsonPathNumberKind.DOUBLE -> {
                val number = doubleValue(value.content)
                when {
                    number.isNaN() -> 0
                    number <= Int.MIN_VALUE.toDouble() -> Int.MIN_VALUE
                    number >= Int.MAX_VALUE.toDouble() -> Int.MAX_VALUE
                    else -> number.toInt()
                }
            }
        }
    }

    private fun integerString(text: String): String {
        val negative = text.startsWith('-')
        val unsigned = if (negative) text.substring(1) else text
        require(unsigned.all { it in '0'..'9' } && (unsigned.isNotEmpty() || negative)) {
            "Invalid JsonSmart integer: $text"
        }
        val digits = unsigned.trimStart('0').ifEmpty { "0" }
        return if (negative && digits != "0") "-$digits" else digits
    }

    fun doubleValue(text: String): Double = requireNotNull(text.toDoubleOrNull()) {
        "Invalid JsonSmart Double: $text"
    }

    private fun doubleString(number: Double): String {
        if (number.isNaN()) return "NaN"
        if (number == Double.POSITIVE_INFINITY) return "Infinity"
        if (number == Double.NEGATIVE_INFINITY) return "-Infinity"
        if (number == 0.0) return if (number.toBits() == Long.MIN_VALUE) "-0.0" else "0.0"

        // Normalize Java's layout, not its historical FloatingDecimal tie-breaking.
        // Native's shortest significand still differs at values such as 1e23.
        val decimal = decimalParts(number.toString())
        val digits = decimal.digits.trimEnd('0')
        val scale = decimal.scale - (decimal.digits.length - digits.length)
        val adjusted = digits.length - 1L - scale
        val sign = if (decimal.negative) "-" else ""
        val magnitude = if (number < 0.0) -number else number
        if (magnitude < 0.001 || magnitude >= 10_000_000.0) {
            val fraction = digits.substring(1).ifEmpty { "0" }
            return "$sign${digits[0]}.$fraction" + "E" + adjusted
        }
        val split = digits.length.toLong() - scale
        return sign + when {
            split <= 0 -> "0." + "0".repeat((-split).toInt()) + digits
            split >= digits.length -> digits + "0".repeat((split - digits.length).toInt()) + ".0"
            else -> digits.substring(0, split.toInt()) + "." + digits.substring(split.toInt())
        }
    }

    private data class DecimalParts(
        val negative: Boolean,
        val digits: String,
        val exponent: Long,
        val scale: Long,
    )

    private fun decimalParts(text: String): DecimalParts {
        require(decimalSyntax.matches(text)) { "Invalid decimal number: $text" }
        val exponentIndex = text.indexOfFirst { it == 'e' || it == 'E' }
        val mantissa = if (exponentIndex < 0) text else text.substring(0, exponentIndex)
        // A canonical BigDecimal exponent may exceed Int even when its original exponent and scale do not.
        val exponent = if (exponentIndex < 0) 0L else {
            requireNotNull(text.substring(exponentIndex + 1).toLongOrNull()) {
                "Decimal exponent out of range: $text"
            }
        }
        val point = mantissa.indexOf('.')
        val fractionLength = if (point < 0) 0 else mantissa.length - point - 1
        require(exponent >= fractionLength.toLong() - Long.MAX_VALUE) { "Decimal scale out of range: $text" }
        val digits = mantissa.filter { it in '0'..'9' }.trimStart('0').ifEmpty { "0" }
        return DecimalParts(text.startsWith('-') && digits != "0", digits, exponent, fractionLength - exponent)
    }

    private fun decimalIntValue(text: String): Int {
        val decimal = decimalParts(text)
        val power = -decimal.scale
        if (decimal.digits == "0" || power >= 32) return 0
        val end = decimal.digits.length.toLong() + minOf(power, 0L)
        if (end <= 0) return 0
        // 10^32 is divisible by 2^32; preceding digits cannot affect Number.intValue().
        var bits = 0u
        for (index in maxOf(0, end.toInt() - 32) until end.toInt()) {
            bits = bits * 10u + (decimal.digits[index] - '0').toUInt()
        }
        repeat(maxOf(power, 0L).toInt()) { bits *= 10u }
        return (if (decimal.negative) 0u - bits else bits).toInt()
    }

    private fun Char.isJavaWhitespace(): Boolean = this in '\t'..'\r' || this in '\u001C'..' ' ||
        this == '\u1680' || this in '\u2000'..'\u2006' || this in '\u2008'..'\u200A' ||
        this == '\u2028' || this == '\u2029' || this == '\u205F' || this == '\u3000'
}
