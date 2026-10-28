package io.legado.kmp.shared.model

import kotlinx.serialization.Serializable

@Serializable
data class Cache(
    val key: String = "",
    val value: String? = null,
    val deadline: Long = 0L
) {
    val isPersistent: Boolean
        get() = deadline == 0L

    fun isValid(now: Long = io.legado.kmp.shared.util.currentTimeMillis()): Boolean {
        return deadline == 0L || deadline > now
    }

    companion object {
        fun from(
            key: String,
            value: String?,
            deadline: Long
        ): Cache = Cache(
            key = key,
            value = value,
            deadline = deadline
        )
    }
}

fun Cache.toInsertMap(): Map<String, Any?> = mapOf(
    "key" to key,
    "value" to value,
    "deadline" to deadline
)
