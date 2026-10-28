package io.legado.kmp.shared.analyze.parser

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull

internal object JsonPathFilterValues {
    private val decimalSyntax = Regex("[+-]?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)(?:[eE][+-]?[0-9]+)?")

    fun quote(value: String): String = JsonPrimitive(value).toString()

    fun jsonArgument(value: String): String = "legadojson(${quote(value)})"

    fun requireNumber(value: JsonElement?): JsonElement? {
        if (value is JsonPrimitive && !value.isString && value != JsonNull && value.booleanOrNull == null) {
            require(decimal(value.content) != null) { "Jayway cannot create a NumberNode from ${value.content}" }
        }
        return value
    }

    fun regex(pattern: String, flags: String): JsonPathRegexMatcher = JsonPathRegexSupport.compile(pattern, flags)

    fun quotedEnd(text: String, start: Int): Int? {
        val quote = text[start]
        var index = start + 1
        while (index < text.length) {
            when (text[index]) {
                '\\' -> index += 2
                quote -> return index + 1
                else -> index++
            }
        }
        return null
    }

    // ValueListNode uses the searched value's equals(), not the element's equals().
    // Jayway consequently has asymmetric string/number membership, but never bool/number coercion.
    fun matches(
        searched: JsonElement?,
        element: JsonElement?,
        literals: JsonPathFilterLiterals,
        numberTypes: JsonPathNumberTypes,
    ): Boolean {
        if (searched == null || element == null) return false
        if (literals.isLiteral(searched) || literals.isLiteral(element)) {
            return literals.isLiteral(searched) && literals.isLiteral(element) && searched == element
        }
        if (searched == JsonNull || element == JsonNull) return searched == element
        if (searched is JsonPrimitive && element is JsonPrimitive) {
            if (searched.isString) {
                return when {
                    element.isString -> searched.content == element.content
                    element.booleanOrNull != null -> false
                    else -> searched.content == numberString(element.content)
                }
            }
            searched.booleanOrNull?.let {
                return !element.isString && it == element.booleanOrNull
            }
            if (element.booleanOrNull != null) return false
            val left = decimal(searched.content) ?: return false
            return left == decimal(element.content)
        }
        // Nested JSON collections use Java collection equality rather than ValueNode coercion.
        return structuralEquals(searched, element, numberTypes, literals)
    }

    fun equals(
        left: JsonElement?,
        right: JsonElement?,
        literals: JsonPathFilterLiterals,
        numberTypes: JsonPathNumberTypes,
        strict: Boolean = false,
    ): Boolean {
        if (left == null || right == null) return false // UndefinedNode never equals another value.
        if (strict && category(left, literals) != category(right, literals)) return false
        if (literals.isJsonNode(left) && literals.isJsonNode(right)) {
            // JsonNode.equals(ctx) parses only the right operand, even when the left is a raw literal.
            val parsedRight = checkNotNull(literals.parse(right))
            return !literals.isLiteral(left) && structuralEquals(left, parsedRight, numberTypes, literals)
        }
        return matches(left, right, literals, numberTypes)
    }

    private fun category(value: JsonElement, literals: JsonPathFilterLiterals): Int =
        if (literals.isLiteral(value)) 1 else when (value) {
            JsonNull -> 0
            is JsonArray, is JsonObject -> 1 // Both are Jayway JsonNode, not scalar ValueNodes.
            is JsonPrimitive -> when {
                value.isString -> 2
                value.booleanOrNull != null -> 3
                else -> 4
            }
        }

    fun compare(left: JsonElement?, right: JsonElement?): Int? {
        if (left !is JsonPrimitive || right !is JsonPrimitive || left == JsonNull || right == JsonNull) return null
        if (left.isString || right.isString) {
            return if (left.isString && right.isString) left.content.compareTo(right.content) else null
        }
        if (left.booleanOrNull != null || right.booleanOrNull != null) return null
        val lhs = decimal(left.content) ?: return null
        val rhs = decimal(right.content) ?: return null
        if (lhs == rhs) return 0
        if (lhs.negative != rhs.negative) return if (lhs.negative) -1 else 1
        val magnitude = when {
            lhs.digits == "0" -> -1
            rhs.digits == "0" -> 1
            else -> {
                val lhsLength = lhs.digits.length.toLong() + lhs.power
                val rhsLength = rhs.digits.length.toLong() + rhs.power
                if (lhsLength != rhsLength) lhsLength.compareTo(rhsLength) else {
                    val width = maxOf(lhs.digits.length, rhs.digits.length)
                    lhs.digits.padEnd(width, '0').compareTo(rhs.digits.padEnd(width, '0'))
                }
            }
        }
        return if (lhs.negative) -magnitude else magnitude
    }

    // BigDecimal.toString(), including scale and scientific notation, without a floating-point round trip.
    fun numberString(value: String): String {
        if (!decimalSyntax.matches(value)) return value
        val exponentIndex = value.indexOfFirst { it == 'e' || it == 'E' }
        val mantissa = if (exponentIndex < 0) value else value.substring(0, exponentIndex)
        val exponent = if (exponentIndex < 0) 0L else {
            value.substring(exponentIndex + 1).toIntOrNull()?.toLong() ?: return value
        }
        val point = mantissa.indexOf('.')
        val fraction = if (point < 0) 0 else mantissa.length - point - 1
        val digits = mantissa.filter { it in '0'..'9' }.trimStart('0').ifEmpty { "0" }
        val negative = value.startsWith('-') && digits != "0"
        val scale = fraction - exponent
        val adjusted = digits.length - 1L - scale
        val sign = if (negative) "-" else ""
        return if (scale >= 0 && adjusted >= -6) {
            val split = digits.length.toLong() - scale
            when {
                scale == 0L -> sign + digits
                split > 0 -> sign + digits.substring(0, split.toInt()) + "." + digits.substring(split.toInt())
                else -> sign + "0." + "0".repeat((-split).toInt()) + digits
            }
        } else {
            val significand = if (digits.length == 1) digits else "${digits[0]}.${digits.substring(1)}"
            sign + significand + "E" + (if (adjusted >= 0) "+" else "") + adjusted
        }
    }

    private fun structuralEquals(
        left: JsonElement,
        right: JsonElement,
        numberTypes: JsonPathNumberTypes,
        literals: JsonPathFilterLiterals,
    ): Boolean = when {
        literals.isKeySet(left) || literals.isKeySet(right) ->
            literals.isKeySet(left) && literals.isKeySet(right) &&
                (left as JsonArray).toSet() == (right as JsonArray).toSet()
        left is JsonArray && right is JsonArray -> left.size == right.size &&
            left.indices.all { structuralEquals(left[it], right[it], numberTypes, literals) }
        left is JsonObject && right is JsonObject -> left.keys == right.keys &&
            left.all { (key, value) -> right[key]?.let { structuralEquals(value, it, numberTypes, literals) } == true }
        left is JsonPrimitive && right is JsonPrimitive -> when {
            left.isString || right.isString || left == JsonNull || right == JsonNull ||
                left.booleanOrNull != null || right.booleanOrNull != null -> left == right
            numberTypes.kind(left) != numberTypes.kind(right) -> false
            numberTypes.kind(left) == JsonPathNumberKind.DOUBLE ->
                JsonPathNumberSupport.doubleValue(left.content).toBits() ==
                    JsonPathNumberSupport.doubleValue(right.content).toBits()
            else -> numberTypes.string(left) == numberTypes.string(right)
        }
        else -> false
    }

    fun numberIntValue(value: JsonElement?): Int? {
        val primitive = value as? JsonPrimitive ?: return null
        if (primitive.isString || primitive == JsonNull || primitive.booleanOrNull != null) return null
        val number = decimal(primitive.content) ?: return null
        val integerLength = number.digits.length.toLong() + minOf(number.power, 0L)
        if (integerLength <= 0) return 0
        // BigDecimal.intValue() truncates fractions and retains the low 32 bits on overflow.
        var result = 0
        for (index in 0 until integerLength.toInt()) {
            result = result * 10 + (number.digits[index] - '0')
        }
        if (number.power >= 32) return 0
        repeat(maxOf(number.power, 0L).toInt()) { result *= 10 }
        return if (number.negative) -result else result
    }

    private data class Decimal(val negative: Boolean, val digits: String, val power: Long)

    private fun decimal(value: String): Decimal? {
        if (!decimalSyntax.matches(value)) return null
        val exponentIndex = value.indexOfFirst { it == 'e' || it == 'E' }
        val mantissa = if (exponentIndex < 0) value else value.substring(0, exponentIndex)
        val exponent = if (exponentIndex < 0) 0L else {
            value.substring(exponentIndex + 1).toIntOrNull()?.toLong() ?: return null
        }
        val point = mantissa.indexOf('.')
        val fractionLength = if (point < 0) 0 else mantissa.length - point - 1
        val digits = mantissa.filter { it in '0'..'9' }.trimStart('0')
        if (digits.isEmpty()) return Decimal(false, "0", 0)
        val trimmed = digits.trimEnd('0')
        return Decimal(value.startsWith('-'), trimmed, exponent - fractionLength + digits.length - trimmed.length)
    }
}
