package io.legado.kmp.shared.model

import kotlinx.serialization.Serializable

@Serializable
data class ReadRecordSnapshot(
    val records: List<ReadRecordShow>,
    val totalReadTime: Long,
    val enabled: Boolean,
)
