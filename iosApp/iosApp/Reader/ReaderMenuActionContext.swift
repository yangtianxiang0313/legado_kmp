import UIKit

/// A menu describes the displayed book/chapter/page and its checkmarks, not whatever is current later.
@MainActor
struct ReaderMenuActionContext {
    private let bookURL: String
    private let origin: String?
    private let index: Int
    private let chapterURL: String?
    private let page: Int
    private let replace: Bool?
    private let replaceDefault: Bool?
    private let reSegment: Bool?
    private let delTag: Int64?
    private let sameTitleRemoved: Bool

    init(_ reader: ReaderContainerViewController) {
        bookURL = reader.bookURL
        origin = reader.book?.origin
        index = reader.readerActionChapterIndex
        chapterURL = reader.readerActionChapterURL
        page = reader.currentPageIndex
        replace = reader.book?.config.useReplaceRule?.boolValue
        replaceDefault = reader.runtimeConfig?.replaceRuleEnabledByDefault
        reSegment = reader.book?.config.reSegment
        delTag = reader.book?.config.delTag
        sameTitleRemoved = reader.currentChapterSameTitleRemoved
    }

    func matches(_ reader: ReaderContainerViewController) -> Bool {
        Self.canPresent(in: reader) && reader.bookURL == bookURL && reader.book?.origin == origin
            && reader.readerActionChapterIndex == index && reader.readerActionChapterURL == chapterURL
            && reader.currentPageIndex == page && reader.book?.config.useReplaceRule?.boolValue == replace
            && reader.runtimeConfig?.replaceRuleEnabledByDefault == replaceDefault
            && reader.book?.config.reSegment == reSegment && reader.book?.config.delTag == delTag
            && reader.currentChapterSameTitleRemoved == sameTitleRemoved
    }

    static func canPresent(in reader: ReaderContainerViewController) -> Bool {
        reader.isMenuVisible && reader.book != nil && reader.canPerformNavigationAction
    }
}
