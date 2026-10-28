import UIKit
import shared

enum BookshelfEmptyState {
    static let message = NSLocalizedString(
        "bookshelf.empty.android", value: "书架还空着，先去搜索书籍或从发现里添加吧！", comment: "")

    static func font(compatibleWith traits: UITraitCollection) -> UIFont {
        // fragment_books / fragment_bookshelf2 inherit AppCompat's 14sp default TextView appearance.
        ReaderAndroidDefaultFont.scaledFont(size: 14, textStyle: .subheadline, compatibleWith: traits)
    }
}

struct BookshelfGroupTabViewState {
    let groupId: Int64
    let title: String
    let isSelected: Bool
}

struct BookshelfViewState {
    let groupTabs: [BookshelfGroupTabViewState]
    let folderGroups: [BookGroup]
    let books: [Book]
    let layoutMode: BookshelfLayoutMode
    let bookGroupStyle: Int32
    let selectedGroupId: Int64
    let emptyMessage: String
    let debugValue: String?

    var isEmpty: Bool {
        folderGroups.isEmpty && books.isEmpty
    }

    var bookCountAccessibilityValue: String {
        "\(folderGroups.count + books.count)"
    }

    init(
        groups: [BookGroup],
        books: [Book],
        selectedGroupId: Int64,
        layoutMode: BookshelfLayoutMode,
        bookGroupStyle: Int32,
        emptyMessage: String,
        debugValue: String?
    ) {
        let visibleGroups = Self.visibleGroups(from: groups)
        self.groupTabs = visibleGroups.map { group in
            BookshelfGroupTabViewState(
                groupId: group.groupId,
                title: group.groupName,
                isSelected: group.groupId == selectedGroupId
            )
        }
        self.folderGroups =
            bookGroupStyle == 1 && selectedGroupId == BookshelfScreenAdapter.rootGroupId
            ? visibleGroups
            : []
        self.books = books
        self.layoutMode = layoutMode
        self.bookGroupStyle = bookGroupStyle
        self.selectedGroupId = selectedGroupId
        self.emptyMessage = emptyMessage
        self.debugValue = debugValue
    }

    private static func visibleGroups(from groups: [BookGroup]) -> [BookGroup] {
        groups.filter { $0.show }
    }
}
