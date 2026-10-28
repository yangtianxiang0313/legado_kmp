package io.legado.kmp.shared.model

val Book.isTxtLocalBook: Boolean
    get() {
        if (!hasType(BookType.TEXT) && type != BookType.LEGACY_TEXT) return false
        if (bookUrl.substringAfterLast('.', "").lowercase() in setOf("pdf", "umd", "mobi", "azw", "azw3")) return false
        if (bookUrl.endsWith(".txt", ignoreCase = true)) return true
        return BookType.isLocalOrigin(origin) &&
            type != BookType.EPUB &&
            !bookUrl.endsWith(".epub", ignoreCase = true)
    }
