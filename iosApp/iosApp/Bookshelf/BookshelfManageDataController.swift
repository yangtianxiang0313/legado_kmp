import Foundation
import shared

struct BookshelfManageSelection {
    private(set) var selectedURLs = Set<String>()

    func selected(in books: [Book]) -> [Book] { books.filter { selectedURLs.contains($0.bookUrl) } }

    mutating func toggle(_ url: String) {
        if !selectedURLs.insert(url).inserted { selectedURLs.remove(url) }
    }

    mutating func selectAll(_ books: [Book]) {
        if !books.isEmpty && selected(in: books).count == books.count {
            selectedURLs.removeAll()
        } else {
            selectedURLs.formUnion(books.map(\.bookUrl))
        }
    }

    mutating func invert(_ books: [Book]) { for book in books { toggle(book.bookUrl) } }

    mutating func selectInterval(_ books: [Book]) {
        let indexes = books.indices.filter { selectedURLs.contains(books[$0].bookUrl) }
        guard let first = indexes.first, let last = indexes.last else { return }
        selectedURLs.formUnion(books[first...last].map(\.bookUrl))
    }

    mutating func retainExisting(_ books: [Book]) { selectedURLs.formIntersection(books.map(\.bookUrl)) }

    mutating func replace(_ urls: Set<String>) { selectedURLs = urls }
}

enum BookshelfManageFilter {
    // BookExtensions.contains is a literal, case-sensitive match, not a SQL LIKE query.
    static func matches(_ book: Book, query: String) -> Bool {
        query.isEmpty
            || [book.name, book.author, book.originName, book.origin, book.kind ?? "", book.intro ?? ""]
                .contains { $0.range(of: query, options: .literal) != nil }
    }
}

@MainActor
final class BookshelfManageDataController {
    private(set) var groupID: Int64
    private(set) var groups: [BookGroup] = []
    private(set) var books: [Book] = []
    private(set) var selection = BookshelfManageSelection()
    private(set) var sort: Int32 = 0
    private(set) var openTitle = true
    private(set) var delaySeconds: Int32 = 0
    private(set) var isLoading = true
    private(set) var error: String?
    var onChange: (() -> Void)?
    var query = "" { didSet { if query != oldValue { onChange?() } } }
    var updatesSuspended = false {
        didSet { if oldValue && !updatesSuspended && needsReload { reload() } }
    }

    private var facade: BookshelfFacade?
    private var settings: SettingsFacade?
    private var subscriptions: [FlowSubscription] = []
    private var generation = UUID()
    private var loadGeneration = UUID()
    private var task: Task<Void, Never>?
    private var needsReload = false
    private var active = false

    init(groupID: Int64) { self.groupID = groupID == 0 ? -1 : groupID }

    deinit {
        task?.cancel()
        for subscription in subscriptions { subscription.cancel() }
    }

    var visibleBooks: [Book] { books.filter { BookshelfManageFilter.matches($0, query: query) } }
    var selectedBooks: [Book] { selection.selected(in: visibleBooks) }
    var groupName: String { groups.first { $0.groupId == groupID }?.groupName ?? "全部" }
    var canReorder: Bool { sort == 3 && !isLoading }

    func bind() {
        guard !active else { return }
        active = true
        let stamp = UUID()
        generation = stamp
        do {
            let facade = try SharedRuntime.bookshelfFacade().get()
            let settings = try SharedRuntime.settingsFacade().get()
            self.facade = facade
            self.settings = settings
            subscriptions.append(
                facade.watchManagedGroups(
                    onUpdate: { [weak self] groups in
                        DispatchQueue.main.async {
                            guard let self, self.active, self.generation == stamp else { return }
                            self.groups = groups
                            if !groups.contains(where: { $0.groupId == self.groupID }) { self.groupID = -1 }
                            self.reload()
                        }
                    },
                    onError: { [weak self] message in
                        DispatchQueue.main.async {
                            guard let self, self.active, self.generation == stamp else { return }
                            self.error = message
                            self.isLoading = false
                            self.onChange?()
                        }
                    }))
            subscriptions.append(
                facade.watchBooks(groupId: -1) { [weak self] all in
                    DispatchQueue.main.async {
                        guard let self, self.active, self.generation == stamp else { return }
                        self.selection.retainExisting(all)
                        self.reload()
                    }
                })
            subscriptions.append(
                settings.watchPreferences { [weak self] _ in
                    DispatchQueue.main.async {
                        guard let self, self.active, self.generation == stamp else { return }
                        self.reload()
                    }
                })
            subscriptions.append(
                settings.watchRuntimeConfig { [weak self] config in
                    DispatchQueue.main.async {
                        guard let self, self.active, self.generation == stamp else { return }
                        self.openTitle = config.openBookInfoByClickTitle
                        self.delaySeconds = config.batchChangeSourceDelay
                        self.onChange?()
                    }
                })
            reload()
        } catch {
            self.error = error.userFacingMessage
            isLoading = false
            onChange?()
        }
    }

    func unbind() {
        active = false
        generation = UUID()
        loadGeneration = UUID()
        task?.cancel()
        task = nil
        for subscription in subscriptions { subscription.cancel() }
        subscriptions.removeAll()
    }

    func selectGroup(_ id: Int64) {
        guard groups.contains(where: { $0.groupId == id }), groupID != id else { return }
        groupID = id
        books = []
        reload()
    }

    func reload() {
        guard active, let facade, let settings else { return }
        if updatesSuspended {
            needsReload = true
            return
        }
        needsReload = false
        task?.cancel()
        let stamp = UUID()
        loadGeneration = stamp
        let id = groupID
        isLoading = true
        error = nil
        onChange?()
        task = Task { @MainActor [weak self] in
            do {
                let sort: KotlinInt = try await SharedAsync.value { completion in
                    settings.getBookSortByGroupId(groupId: id, completionHandler: completion)
                }
                let books = try await facade.loadBooksForDisplayAsync(groupId: id, sortMode: sort)
                guard !Task.isCancelled, let self, self.active, self.loadGeneration == stamp, self.groupID == id else { return }
                self.sort = sort.int32Value
                self.books = books
                self.isLoading = false
                self.task = nil
                self.onChange?()
            } catch {
                guard !Task.isCancelled, let self, self.active, self.loadGeneration == stamp else { return }
                self.isLoading = false
                self.error = error.userFacingMessage
                self.task = nil
                self.onChange?()
            }
        }
    }

    func toggle(_ url: String) {
        guard visibleBooks.contains(where: { $0.bookUrl == url }) else { return }
        selection.toggle(url)
        onChange?()
    }

    func selectAll() {
        selection.selectAll(visibleBooks)
        onChange?()
    }
    func invert() {
        selection.invert(visibleBooks)
        onChange?()
    }
    func selectInterval() {
        selection.selectInterval(visibleBooks)
        onChange?()
    }

    func replaceSelection(_ urls: Set<String>) {
        selection.replace(urls)
        onChange?()
    }

    func previewOrder(_ visible: [Book]) {
        let ids = Set(visible.map(\.bookUrl))
        var iterator = visible.makeIterator()
        books = books.map { ids.contains($0.bookUrl) ? (iterator.next() ?? $0) : $0 }
    }

    func groupNames(for mask: Int64) -> String {
        groups.filter { $0.groupId > 0 && $0.groupId & mask != 0 }.map(\.groupName).joined(separator: ",")
    }
}
