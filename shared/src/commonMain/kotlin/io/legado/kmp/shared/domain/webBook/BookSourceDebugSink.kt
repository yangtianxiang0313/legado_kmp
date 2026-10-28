package io.legado.kmp.shared.domain.webBook

enum class BookSourceDebugRawBucket {
    SEARCH,
    DETAIL,
    TOC,
    CONTENT,
}

interface BookSourceDebugSink {
    fun raw(bucket: BookSourceDebugRawBucket, text: String)

    fun log(state: Int = 1, message: String = "", showTime: Boolean = true) = Unit
}
