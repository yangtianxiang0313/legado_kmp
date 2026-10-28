package io.legado.kmp.shared.model.rule

/**
 * Book list rule interface
 * Common rules for search and explore results
 */
interface BookListRule {
    var bookList: String?
    var name: String?
    var author: String?
    var intro: String?
    var kind: String?
    var lastChapter: String?
    var updateTime: String?
    var bookUrl: String?
    var coverUrl: String?
    var wordCount: String?
}
