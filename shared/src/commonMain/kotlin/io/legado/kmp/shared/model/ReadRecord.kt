package io.legado.kmp.shared.model

import kotlinx.serialization.Serializable

@Serializable
data class ReadRecord(
    val deviceId: String = "",
    val bookName: String = "",
    val readTime: Long = 0L,
    val lastRead: Long = io.legado.kmp.shared.util.currentTimeMillis()
) {
    companion object {
        fun from(
            device_id: String,
            book_name: String,
            read_time: Long,
            last_read: Long
        ): ReadRecord = ReadRecord(
            deviceId = device_id,
            bookName = book_name,
            readTime = read_time,
            lastRead = last_read
        )
    }
}

fun ReadRecord.toInsertMap(): Map<String, Any?> = mapOf(
    "device_id" to deviceId,
    "book_name" to bookName,
    "read_time" to readTime,
    "last_read" to lastRead
)
