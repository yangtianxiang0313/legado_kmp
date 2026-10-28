package io.legado.kmp.shared.model

import kotlinx.serialization.Serializable

/**
 * Custom TXT table-of-contents rule.
 */
@Serializable
data class TxtTocRule(
    val id: Long = io.legado.kmp.shared.util.currentTimeMillis(),
    val name: String = "",
    val rule: String = "",
    val example: String? = null,
    val serialNumber: Int = -1,
    val enable: Boolean = true
) {
    companion object {
        fun from(
            id: Long,
            name: String,
            rule: String,
            example: String?,
            serial_number: Long,
            enable: Long
        ): TxtTocRule = TxtTocRule(
            id = id,
            name = name,
            rule = rule,
            example = example,
            serialNumber = serial_number.toInt(),
            enable = enable == 1L
        )
    }

    override fun equals(other: Any?): Boolean {
        return other is TxtTocRule && other.id == id
    }

    override fun hashCode(): Int = id.hashCode()
}

fun TxtTocRule.toInsertMap(): Map<String, Any?> = mapOf(
    "id" to id,
    "name" to name,
    "rule" to rule,
    "example" to example,
    "serial_number" to serialNumber.toLong(),
    "enable" to if (enable) 1L else 0L
)
