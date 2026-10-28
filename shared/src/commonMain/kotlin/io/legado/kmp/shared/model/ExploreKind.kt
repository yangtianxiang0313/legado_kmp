package io.legado.kmp.shared.model

import kotlinx.serialization.Serializable

@Serializable
data class ExploreKind(
    val title: String = "",
    val url: String? = null,
    val style: FlexChildStyle? = null
)
