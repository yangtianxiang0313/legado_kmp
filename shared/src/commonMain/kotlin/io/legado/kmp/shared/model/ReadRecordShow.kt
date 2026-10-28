package io.legado.kmp.shared.model

import kotlinx.serialization.Serializable

@Serializable
data class ReadRecordShow(
    val bookName: String,
    val readTime: Long,
    val lastRead: Long
) {
    companion object {
        fun from(
            book_name: String,
            read_time: Long?,
            last_read: Long?
        ): ReadRecordShow = ReadRecordShow(
            bookName = book_name,
            readTime = read_time ?: 0L,
            lastRead = last_read ?: 0L
        )
    }
}
