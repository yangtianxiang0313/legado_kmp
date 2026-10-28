package io.legado.kmp.shared.facade

import io.legado.kmp.shared.model.Book

internal fun Book.toImageRuleVariables(): Map<String, Any?> = linkedMapOf(
    "book" to mapOf(
        "bookUrl" to bookUrl,
        "tocUrl" to tocUrl,
        "origin" to origin,
        "originName" to originName,
        "name" to name,
        "author" to author,
        "kind" to kind,
        "intro" to intro,
        "coverUrl" to displayCoverUrl,
        "latestChapterTitle" to latestChapterTitle,
        "totalChapterNum" to totalChapterNum,
        "variable" to variableMap,
    ),
    "key" to name,
    "searchKey" to name,
    "bookUrl" to bookUrl,
    "bookName" to name,
    "bookCoverUrl" to displayCoverUrl,
    "bookTotalChapterNum" to totalChapterNum,
    "author" to author,
)
