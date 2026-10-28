package io.legado.kmp.shared.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class FlexChildStyle(
    @SerialName("layout_flexGrow")
    val flexGrow: Float = 0F,
    @SerialName("layout_flexShrink")
    val flexShrink: Float = 1F,
    @SerialName("layout_alignSelf")
    val alignSelf: String = "auto",
    @SerialName("layout_flexBasisPercent")
    val flexBasisPercent: Float = -1F,
    @SerialName("layout_wrapBefore")
    val wrapBefore: Boolean = false
)
