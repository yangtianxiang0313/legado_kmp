package io.legado.kmp.shared.model

import kotlinx.serialization.Serializable

@Serializable
data class RssReadRecord(
    val record: String,
    val title: String? = null,
    val readTime: Long? = null,
    val read: Boolean = true
)
