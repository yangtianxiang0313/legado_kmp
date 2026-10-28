package io.legado.kmp.shared.model

import kotlinx.serialization.Serializable

@Serializable
data class KeyboardAssist(
    val type: Int = 0,
    val key: String = "",
    val value: String = "",
    val serialNo: Int = 0,
)
