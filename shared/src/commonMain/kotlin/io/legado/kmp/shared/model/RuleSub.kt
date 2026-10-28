package io.legado.kmp.shared.model

import kotlinx.serialization.Serializable

@Serializable
data class RuleSub(
    val id: Long = io.legado.kmp.shared.util.currentTimeMillis(),
    val name: String = "",
    val url: String = "",
    val type: Int = 0,
    val customOrder: Int = 0,
    val autoUpdate: Boolean = false,
    val update: Long = io.legado.kmp.shared.util.currentTimeMillis(),
)
