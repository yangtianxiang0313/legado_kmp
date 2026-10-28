package io.legado.kmp.shared.model

import kotlinx.serialization.Serializable

@Serializable
data class DictRule(
    val name: String = "",
    val urlRule: String = "",
    val showRule: String = "",
    val enabled: Boolean = true,
    val sortNumber: Int = 0,
)
