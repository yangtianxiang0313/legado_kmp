package io.legado.kmp.shared.model

import io.legado.kmp.shared.domain.localbook.LocalBookFileBinding

val Book.isTxtLocalBook: Boolean
    get() {
        if (!hasType(BookType.TEXT) && type != BookType.LEGACY_TEXT) return false
        if (!isLocal) return bookUrl.endsWith(".txt", ignoreCase = true)
        val format = LocalBookFileBinding.format(this)
        if (format in setOf("pdf", "umd", "mobi", "azw", "azw3")) return false
        if (format == "txt") return true
        return BookType.isLocalOrigin(origin) &&
            type != BookType.EPUB &&
            format != "epub"
    }
