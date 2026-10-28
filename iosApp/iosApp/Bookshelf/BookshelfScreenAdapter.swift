import Foundation
import shared

final class BookshelfScreenAdapter {
    static let rootGroupId: Int64 = -100
    static let allGroupId: Int64 = -1
    private static let simplifiedChineseLocale = Locale(identifier: "zh-Hans-CN")

    private let bindings = ScreenBindingController(owner: "BookshelfScreen")
    private var facade: BookshelfFacade?
    private var remoteBookFacade: RemoteBookFacade?
    private var logFacade: LogFacade?
    private var settingsFacade: SettingsFacade?
    private var selectedGroupId: Int64 = -1
    private var currentPreferences: AppUiPreferences?
    private var currentRuntimeConfig: AppRuntimeConfig?
    private var currentGroups: [BookGroup] = []
    private var hasReceivedGroups = false
    private var hasBooksBinding = false
    private var boundBooksSortMode: Int32?
    private var lastGroupsSignature: String?
    private var lastBooksSignature: [[String?]]?
    private var lastLayoutMode: BookshelfLayoutMode?
    private var bindingGeneration = UUID()
    private var booksGeneration = UUID()
    private var hasResolvedInitialGroup = false
    private var lastSelectedVisibleGroupId: Int64?
    private var selectionPersistenceTask: Task<Void, Never>?

    var currentSelectedGroupId: Int64 { selectedGroupId }
    var visibleGroupIDs: [Int64] { currentGroups.map(\.groupId) }

    var canRefreshSelectedGroup: Bool {
        currentGroups.first { $0.groupId == selectedGroupId }?.enableRefresh ?? true
    }

    var onLayoutModeChange: ((BookshelfLayoutMode) -> Void)?
    var onPreferencesChange: ((AppUiPreferences) -> Void)?
    var onRuntimeConfigChange: ((AppRuntimeConfig) -> Void)?
    var onGroupsChange: (([BookGroup], Int64) -> Void)?
    var onBooksChange: (([Book]) -> Void)?

    func bootstrap() -> Result<Void, SharedRuntimeError> {
        unbind()
        let generation = bindingGeneration
        hasBooksBinding = false
        boundBooksSortMode = nil
        hasResolvedInitialGroup = false
        lastSelectedVisibleGroupId = nil
        hasReceivedGroups = false
        currentPreferences = nil
        currentGroups = []
        lastGroupsSignature = nil
        lastBooksSignature = nil
        lastLayoutMode = nil

        switch (
            SharedRuntime.bookshelfFacade(), SharedRuntime.settingsFacade(),
            SharedRuntime.remoteBookFacade(),
            SharedRuntime.logFacade()
        ) {
        case (
            .success(let facade), .success(let settingsFacade), .success(let remoteBookFacade),
            .success(let logFacade)
        ):
            self.facade = facade
            self.remoteBookFacade = remoteBookFacade
            self.logFacade = logFacade
            self.settingsFacade = settingsFacade
            bindings.bind(
                settingsFacade.watchPreferences { [weak self] preferences in
                    DispatchQueue.main.async {
                        guard let self, self.bindingGeneration == generation else { return }
                        let previousGroupStyle = self.currentPreferences?.bookGroupStyle
                        self.currentPreferences = preferences
                        self.onPreferencesChange?(preferences)
                        self.handleLayoutMode(preferences.bookshelfLayoutMode)
                        self.handlePreferenceDrivenSelection(previousGroupStyle: previousGroupStyle)
                    }
                })
            bindings.bind(
                settingsFacade.watchRuntimeConfig { [weak self] runtimeConfig in
                    DispatchQueue.main.async {
                        guard let self, self.bindingGeneration == generation else { return }
                        self.currentRuntimeConfig = runtimeConfig
                        self.onRuntimeConfigChange?(runtimeConfig)
                    }
                })
            bindings.bind(
                facade.watchGroups { [weak self] groups in
                    DispatchQueue.main.async {
                        guard let self, self.bindingGeneration == generation else { return }
                        self.handleGroups(groups)
                    }
                })
            return .success(())
        case (.failure(let error), _, _, _), (_, .failure(let error), _, _),
            (_, _, .failure(let error), _),
            (_, _, _, .failure(let error)):
            return .failure(error)
        }
    }

    func selectGroup(_ groupId: Int64) {
        let groupId = Self.normalizedGroupId(groupId)
        guard isSelectableGroup(groupId) else { return }
        hasResolvedInitialGroup = true
        guard selectedGroupId != groupId else { return }
        selectedGroupId = groupId
        if groupId != Self.rootGroupId {
            lastSelectedVisibleGroupId = groupId
        }
        persistSelectedGroup()
        notifyGroupsChange()
        bindBooks()
    }

    func unbind() {
        bindingGeneration = UUID()
        booksGeneration = UUID()
        hasBooksBinding = false
        boundBooksSortMode = nil
        bindings.cancelAll()
        facade = nil
        settingsFacade = nil
        remoteBookFacade = nil
        logFacade = nil
    }

    func loadBooks(groupId: Int64) async throws -> [Book] {
        guard let facade, let settingsFacade else {
            throw NSError(
                domain: "io.legado.kmp.ios",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Bookshelf.unavailable]
            )
        }
        let groupId = Self.normalizedGroupId(groupId)
        let sortMode: KotlinInt = try await SharedAsync.value { completion in
            settingsFacade.getBookSortByGroupId(groupId: groupId, completionHandler: completion)
        }
        return try await facade.loadBooksForDisplayAsync(
            groupId: groupId,
            sortMode: sortMode
        )
    }

    func reloadBooks() async throws -> [Book] {
        try await loadBooks(groupId: selectedGroupId)
    }

    func updateToc(groupId: Int64? = nil) async throws -> BookshelfBatchUpdateResult {
        guard let facade else {
            throw NSError(
                domain: "io.legado.kmp.ios", code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Bookshelf.unavailable]
            )
        }
        return try await facade.updateTocAsync(groupId: groupId ?? selectedGroupId)
    }

    func addBookByUrl(_ url: String) async throws -> Book {
        guard let facade else {
            throw NSError(
                domain: "io.legado.kmp.ios", code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Bookshelf.unavailable]
            )
        }
        return try await facade.addBookByUrlAsync(
            bookUrl: url, groupId: selectedGroupId > 0 ? selectedGroupId : 0)
    }

    func importBookshelf(_ payload: String) async throws -> BookshelfImportResult {
        guard let facade else {
            throw NSError(
                domain: "io.legado.kmp.ios", code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Bookshelf.unavailable]
            )
        }
        return try await facade.importBookshelfAsync(
            payload: payload, groupId: selectedGroupId > 0 ? selectedGroupId : 0)
    }

    func importBookshelfFromUrl(_ url: String) async throws -> BookshelfImportResult {
        guard let facade else {
            throw NSError(
                domain: "io.legado.kmp.ios", code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Bookshelf.unavailable]
            )
        }
        return try await facade.importBookshelfFromUrlAsync(
            url: url, groupId: selectedGroupId > 0 ? selectedGroupId : 0)
    }

    func importBookshelfFile(_ path: String) async throws -> BookshelfImportResult {
        guard let facade else {
            throw NSError(
                domain: "io.legado.kmp.ios", code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Bookshelf.unavailable]
            )
        }
        return try await facade.importBookshelfFileAsync(
            path: path, groupId: selectedGroupId > 0 ? selectedGroupId : 0)
    }

    func exportBookshelf() async throws -> String {
        guard let facade else {
            throw NSError(
                domain: "io.legado.kmp.ios", code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Bookshelf.unavailable]
            )
        }
        return try await facade.exportBookshelfAsync(groupId: selectedGroupId)
    }

    func importLocalBook(_ path: String) async throws -> Book {
        guard let facade else {
            throw NSError(
                domain: "io.legado.kmp.ios", code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Bookshelf.unavailable]
            )
        }
        // App updates can relocate the sandbox while persisted book identifiers stay unchanged.
        if let storageKey = localBookStorageKey(path) {
            let existingBooks = try await facade.loadBooksAsync(groupId: Self.allGroupId)
            if let existing = existingBooks.first(where: {
                $0.isLocal && localBookStorageKey($0.bookUrl) == storageKey
            }) {
                return existing
            }
        }
        return try await facade.importLocalBookAsync(
            path: path, groupId: selectedGroupId > 0 ? selectedGroupId : 0)
    }

    private func localBookStorageKey(_ path: String) -> String? {
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard
            let index = components.indices.first(where: {
                components[$0] == "Library"
                    && components.dropFirst($0 + 1).prefix(2).elementsEqual([
                        "Application Support", "LocalBooks",
                    ])
            }), index + 3 < components.count
        else { return nil }
        return components.dropFirst(index + 2).joined(separator: "/")
    }

    func loadRemoteBooks(path: String? = nil) async throws -> [RemoteBook] {
        guard let remoteBookFacade else {
            throw NSError(
                domain: "io.legado.kmp.ios", code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Bookshelf.remoteUnavailable])
        }
        return try await remoteBookFacade.listAsync(path: path)
    }

    func downloadAndImportRemoteBook(_ remoteBook: RemoteBook) async throws -> Book {
        guard let remoteBookFacade else {
            throw NSError(
                domain: "io.legado.kmp.ios", code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Bookshelf.remoteUnavailable])
        }
        return try await remoteBookFacade.downloadAndImportAsync(
            remoteBook: remoteBook, groupId: selectedGroupId > 0 ? selectedGroupId : 0)
    }

    func uploadRemoteBook(path: String) async throws -> RemoteBook {
        guard let remoteBookFacade else {
            throw NSError(
                domain: "io.legado.kmp.ios", code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Bookshelf.remoteUnavailable])
        }
        return try await remoteBookFacade.uploadLocalBookAsync(path: path)
    }

    func deleteRemoteBook(_ remoteBook: RemoteBook) async throws {
        guard let remoteBookFacade else {
            throw NSError(
                domain: "io.legado.kmp.ios", code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Bookshelf.remoteUnavailable])
        }
        try await remoteBookFacade.deleteAsync(remoteBook: remoteBook)
    }

    func loadLogEntries() async throws -> [AppLogEntry] {
        guard let logFacade else {
            throw NSError(
                domain: "io.legado.kmp.ios", code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Bookshelf.logUnavailable])
        }
        return try await logFacade.loadEntriesAsync()
    }

    func exportLogs() async throws -> String {
        guard let logFacade else {
            throw NSError(
                domain: "io.legado.kmp.ios", code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Bookshelf.logUnavailable])
        }
        return try await logFacade.exportMarkdownAsync()
    }

    func clearLogs() async throws {
        guard let logFacade else {
            throw NSError(
                domain: "io.legado.kmp.ios", code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Bookshelf.logUnavailable])
        }
        try await logFacade.clearAsync()
    }

    func addBooksToGroup(bookUrls: [String], groupId: Int64) async throws
        -> BookshelfBatchUpdateResult
    {
        guard let facade else {
            throw NSError(
                domain: "io.legado.kmp.ios", code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Bookshelf.unavailable]
            )
        }
        return try await facade.addBooksToGroupAsync(bookUrls: bookUrls, groupId: groupId)
    }

    func moveBooks(bookUrls: [String], to groupId: Int64) async throws -> BookshelfBatchUpdateResult {
        guard let facade else {
            throw NSError(
                domain: "io.legado.kmp.ios", code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Bookshelf.unavailable]
            )
        }
        return try await facade.updateBookGroupAsync(bookUrls: bookUrls, groupId: groupId)
    }

    func removeBooks(bookUrls: [String]) async throws -> BookshelfBatchUpdateResult {
        guard let facade else {
            throw NSError(
                domain: "io.legado.kmp.ios", code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Bookshelf.unavailable]
            )
        }
        return try await facade.removeBooksAsync(bookUrls: bookUrls)
    }

    func removeBooksAndLocalFiles(bookUrls: [String]) async throws -> BookshelfBatchUpdateResult {
        guard let facade else {
            throw NSError(
                domain: "io.legado.kmp.ios", code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Bookshelf.unavailable]
            )
        }
        return try await facade.removeBooksAndLocalFilesAsync(bookUrls: bookUrls)
    }

    func clearCache(bookUrls: [String]) async throws -> BookshelfBatchUpdateResult {
        guard let facade else {
            throw NSError(
                domain: "io.legado.kmp.ios", code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Bookshelf.unavailable]
            )
        }
        return try await facade.clearCacheAsync(bookUrls: bookUrls)
    }

    func loadEnabledBookSources() async throws -> [BookSource] {
        guard let facade else {
            throw NSError(
                domain: "io.legado.kmp.ios", code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Bookshelf.unavailable]
            )
        }
        return try await facade.loadEnabledBookSourcesAsync()
    }

    func changeSource(
        bookUrls: [String],
        sourceUrl: String,
        delayMillis: Int64,
        onProgress: @escaping (Int32, Int32) -> Void
    ) async throws -> BookshelfBatchChangeSourceResult {
        guard let facade else {
            throw NSError(
                domain: "io.legado.kmp.ios", code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Bookshelf.unavailable]
            )
        }
        return try await facade.changeSourceAsync(
            bookUrls: bookUrls,
            sourceUrl: sourceUrl,
            delayMillis: delayMillis,
            onProgress: { current, total in
                onProgress(current.int32Value, total.int32Value)
            }
        )
    }

    func loadGroups() async throws -> [BookGroup] {
        guard let facade else {
            throw NSError(
                domain: "io.legado.kmp.ios", code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Bookshelf.unavailable]
            )
        }
        return try await facade.loadGroupsAsync()
    }

    func saveGroup(
        groupId: Int64, name: String, show: Bool, order: Int32? = nil, enableRefresh: Bool = true,
        bookSort: Int32 = 0
    ) async throws -> BookGroup {
        guard let facade else {
            throw NSError(
                domain: "io.legado.kmp.ios", code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Bookshelf.unavailable]
            )
        }
        let kotlinOrder = order.map(KotlinInt.init(int:))
        return try await facade.saveGroupAsync(
            groupId: groupId, name: name, show: show, order: kotlinOrder, enableRefresh: enableRefresh,
            bookSort: bookSort)
    }

    func saveManagedGroup(groupId: Int64, draft: BookGroupEditDraft) async throws {
        guard let facade else {
            throw NSError(
                domain: "io.legado.kmp.ios", code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Bookshelf.unavailable])
        }
        _ = try await facade.saveManagedGroupDetailsAsync(
            groupId: groupId, name: draft.name, cover: draft.cover,
            enableRefresh: draft.enableRefresh, bookSort: draft.bookSort)
    }

    @discardableResult
    func applyBookshelfSortSnapshot(_ sort: Int32) -> AppUiPreferences? {
        guard let currentPreferences else { return nil }
        let updated = AppUiPreferences(
            themeMode: currentPreferences.themeMode,
            bookshelfLayoutMode: currentPreferences.bookshelfLayoutMode,
            bookshelfSort: sort,
            bookGroupStyle: currentPreferences.bookGroupStyle,
            showUnread: currentPreferences.showUnread,
            showLastUpdateTime: currentPreferences.showLastUpdateTime,
            showWaitUpCount: currentPreferences.showWaitUpCount,
            showBookshelfFastScroller: currentPreferences.showBookshelfFastScroller,
            saveTabPosition: currentPreferences.saveTabPosition,
            themePresetName: currentPreferences.themePresetName,
            readerPresetName: currentPreferences.readerPresetName,
            readerStyle: currentPreferences.readerStyle,
            readerPreset: currentPreferences.readerPreset,
            readerPresetIndex: currentPreferences.readerPresetIndex
        )
        self.currentPreferences = updated
        onPreferencesChange?(updated)
        return updated
    }

    func updateBooksCanUpdate(bookUrls: [String], canUpdate: Bool) async throws
        -> BookshelfBatchUpdateResult
    {
        guard let facade else {
            throw NSError(
                domain: "io.legado.kmp.ios", code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Bookshelf.unavailable]
            )
        }
        return try await facade.updateBooksCanUpdateAsync(bookUrls: bookUrls, canUpdate: canUpdate)
    }

    func updateBookOrder(bookUrl: String, newOrder: Int32) async throws {
        guard let facade else {
            throw NSError(
                domain: "io.legado.kmp.ios", code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Bookshelf.unavailable]
            )
        }
        try await facade.updateBookOrderAsync(bookUrl: bookUrl, newOrder: newOrder)
    }

    func exportUsedSources(groupId: Int64? = nil) async throws -> String {
        guard let facade else {
            throw NSError(
                domain: "io.legado.kmp.ios", code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Bookshelf.unavailable]
            )
        }
        return try await facade.exportUsedSourcesAsync(groupId: groupId ?? selectedGroupId)
    }

    func deleteGroup(groupId: Int64) async throws {
        guard let facade else {
            throw NSError(
                domain: "io.legado.kmp.ios", code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Bookshelf.unavailable]
            )
        }
        try await facade.deleteGroupAsync(groupId: groupId)
    }

    func setOpenBookInfoByClickTitle(_ enabled: Bool) async throws {
        guard let settingsFacade else {
            throw NSError(
                domain: "io.legado.kmp.ios", code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Bookshelf.unavailable]
            )
        }
        try await settingsFacade.setOpenBookInfoByClickTitleAsync(enabled: enabled)
    }

    func setBookshelfLayoutMode(_ mode: BookshelfLayoutMode) async throws {
        guard let settingsFacade else {
            throw NSError(
                domain: "io.legado.kmp.ios", code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Bookshelf.unavailable]
            )
        }
        try await settingsFacade.setBookshelfLayoutModeAsync(mode: mode)
    }

    @MainActor
    func applyLayoutDraft(_ draft: BookshelfLayoutDraft) async throws {
        let modes: [BookshelfLayoutMode] = [.list, .grid3, .grid4, .grid5, .grid6]
        guard modes.indices.contains(draft.layoutIndex), (0...5).contains(draft.sortIndex),
            (0...1).contains(draft.groupStyleIndex),
            let settingsFacade, let saved = currentPreferences
        else {
            throw NSError(
                domain: "io.legado.kmp.ios", code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Bookshelf.unavailable])
        }
        if saved.showUnread != draft.showUnread {
            try await settingsFacade.setShowUnreadAsync(enabled: draft.showUnread)
        }
        if saved.showLastUpdateTime != draft.showLastUpdateTime {
            try await settingsFacade.setShowLastUpdateTimeAsync(enabled: draft.showLastUpdateTime)
        }
        if saved.showWaitUpCount != draft.showWaitUpCount {
            try await settingsFacade.setShowWaitUpCountAsync(enabled: draft.showWaitUpCount)
        }
        if saved.showBookshelfFastScroller != draft.showBookshelfFastScroller {
            try await settingsFacade.setShowBookshelfFastScrollerAsync(enabled: draft.showBookshelfFastScroller)
        }
        if Int(saved.bookshelfSort) != draft.sortIndex {
            try await settingsFacade.setBookshelfSortAsync(sort: Int32(draft.sortIndex))
        }
        if saved.bookshelfLayoutMode != modes[draft.layoutIndex] {
            try await settingsFacade.setBookshelfLayoutModeAsync(mode: modes[draft.layoutIndex])
        }
        if Int(saved.bookGroupStyle) != draft.groupStyleIndex {
            try await settingsFacade.setBookGroupStyleAsync(style: Int32(draft.groupStyleIndex))
        }
    }

    func setBookshelfSort(_ sort: Int32) async throws {
        guard let settingsFacade else {
            throw NSError(
                domain: "io.legado.kmp.ios", code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Bookshelf.unavailable]
            )
        }
        try await settingsFacade.setBookshelfSortAsync(sort: sort)
    }

    func setBookGroupStyle(_ style: Int32) async throws {
        guard let settingsFacade else {
            throw NSError(
                domain: "io.legado.kmp.ios", code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Bookshelf.unavailable]
            )
        }
        try await settingsFacade.setBookGroupStyleAsync(style: style)
    }

    func setShowUnread(_ enabled: Bool) async throws {
        guard let settingsFacade else {
            throw NSError(
                domain: "io.legado.kmp.ios", code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Bookshelf.unavailable]
            )
        }
        try await settingsFacade.setShowUnreadAsync(enabled: enabled)
    }

    func setShowLastUpdateTime(_ enabled: Bool) async throws {
        guard let settingsFacade else {
            throw NSError(
                domain: "io.legado.kmp.ios", code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Bookshelf.unavailable]
            )
        }
        try await settingsFacade.setShowLastUpdateTimeAsync(enabled: enabled)
    }

    func setShowWaitUpCount(_ enabled: Bool) async throws {
        guard let settingsFacade else {
            throw NSError(
                domain: "io.legado.kmp.ios", code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Bookshelf.unavailable]
            )
        }
        try await settingsFacade.setShowWaitUpCountAsync(enabled: enabled)
    }

    func setShowBookshelfFastScroller(_ enabled: Bool) async throws {
        guard let settingsFacade else {
            throw NSError(
                domain: "io.legado.kmp.ios", code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Bookshelf.unavailable]
            )
        }
        try await settingsFacade.setShowBookshelfFastScrollerAsync(enabled: enabled)
    }

    func setBatchChangeSourceDelay(_ delay: Int32) async throws {
        guard let settingsFacade else {
            throw NSError(
                domain: "io.legado.kmp.ios", code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Bookshelf.unavailable]
            )
        }
        try await settingsFacade.setBatchChangeSourceDelayAsync(delay: delay)
    }

    func currentOpenBookInfoByClickTitle() -> Bool {
        currentRuntimeConfig?.openBookInfoByClickTitle ?? true
    }

    func currentBatchChangeSourceDelay() -> Int32 {
        currentRuntimeConfig?.batchChangeSourceDelay ?? 0
    }

    private func handleLayoutMode(_ mode: BookshelfLayoutMode) {
        guard lastLayoutMode != mode else { return }
        lastLayoutMode = mode
        onLayoutModeChange?(mode)
    }

    private func handleGroups(_ groups: [BookGroup]) {
        let previousGroupId = selectedGroupId
        let previousIndex = currentGroups.firstIndex { $0.groupId == previousGroupId }
        let wasResolved = hasResolvedInitialGroup
        currentGroups = Self.visibleGroups(from: groups)
        hasReceivedGroups = true
        resolveGroupSelection(fallbackIndex: previousIndex)
        if wasResolved, previousGroupId == selectedGroupId,
            let index = currentGroups.firstIndex(where: { $0.groupId == selectedGroupId }),
            previousIndex != index
        {
            persistSelectedGroup()
        }
    }

    private func notifyGroupsChange() {
        let signature =
            currentGroups.map {
                "\($0.groupId)#\($0.order)#\($0.groupName)#\($0.cover ?? "")#\($0.show)#\($0.enableRefresh)#\($0.bookSort)"
            }.joined(separator: "|") + "@\(selectedGroupId):\(currentBookGroupStyleValue())"
        guard signature != lastGroupsSignature else { return }
        lastGroupsSignature = signature
        onGroupsChange?(currentGroups, selectedGroupId)
    }

    private static func normalizedGroupId(_ groupId: Int64) -> Int64 {
        groupId == 0 ? allGroupId : groupId
    }

    private static func isDisplayGroupId(_ groupId: Int64) -> Bool {
        switch normalizedGroupId(groupId) {
        case allGroupId, -2, -3, -4, -5, -11:
            return true
        case let id where id > 0:
            return id & (id - 1) == 0
        default:
            return false
        }
    }

    private static func visibleGroups(from groups: [BookGroup]) -> [BookGroup] {
        let sorted = groups.filter { $0.show && isDisplayGroupId($0.groupId) }.sorted {
            if $0.order != $1.order { return $0.order < $1.order }
            let leftId = normalizedGroupId($0.groupId)
            let rightId = normalizedGroupId($1.groupId)
            if leftId != rightId { return leftId < rightId }
            return $0.groupId < $1.groupId
        }
        var seen: Set<Int64> = []
        return sorted.compactMap { group in
            let groupId = normalizedGroupId(group.groupId)
            guard seen.insert(groupId).inserted else { return nil }
            guard groupId != group.groupId else { return group }
            return BookGroup(
                groupId: groupId,
                groupName: group.groupName,
                cover: group.cover,
                order: group.order,
                enableRefresh: group.enableRefresh,
                show: group.show,
                bookSort: group.bookSort
            )
        }
    }

    private func isSelectableGroup(_ groupId: Int64) -> Bool {
        if groupId == Self.rootGroupId {
            return currentBookGroupStyleValue() == 1
        }
        return currentGroups.contains { $0.groupId == groupId }
    }

    private func fallbackGroupId(at index: Int) -> Int64 {
        guard !currentGroups.isEmpty else {
            // Keep the nonoptional ID as a sentinel, without exposing a hidden tab's books.
            return currentBookGroupStyleValue() == 1 ? Self.rootGroupId : Self.allGroupId
        }
        return currentGroups[min(max(index, 0), currentGroups.count - 1)].groupId
    }

    private func bindBooks() {
        guard let facade else { return }
        booksGeneration = UUID()
        guard isSelectableGroup(selectedGroupId) else {
            hasBooksBinding = false
            boundBooksSortMode = nil
            bindings.unbind(key: "books")
            handleBooks([])
            return
        }
        hasBooksBinding = true
        boundBooksSortMode = displaySortMode(for: selectedGroupId)
        let generation = booksGeneration
        let groupId = selectedGroupId
        lastBooksSignature = nil
        bindings.replaceBinding(
            key: "books",
            with: facade.watchBooks(groupId: selectedGroupId) { [weak self] books in
                DispatchQueue.main.async {
                    guard let self, self.booksGeneration == generation, self.selectedGroupId == groupId else {
                        return
                    }
                    self.handleBooks(books)
                }
            })
    }

    private func handleBooks(_ books: [Book]) {
        let sorted = sortForDisplay(books)
        let signature: [[String?]] = sorted.map { book in
            [
                book.bookUrl, book.name, book.author, book.origin, book.originName,
                book.coverUrl, book.customCoverUrl, book.durChapterTitle, book.latestChapterTitle,
                book.variable,
                String(book.order), String(book.durChapterIndex), String(book.durChapterPos),
                String(book.durChapterTime),
                String(book.latestChapterTime), String(book.totalChapterNum), String(book.lastCheckCount),
                String(book.type), String(book.canUpdate),
            ]
        }
        guard lastBooksSignature != signature else { return }
        lastBooksSignature = signature
        onBooksChange?(sorted)
    }

    private func sortForDisplay(_ books: [Book]) -> [Book] {
        switch displaySortMode(for: selectedGroupId) {
        case 1:
            return books.sorted { $0.latestChapterTime > $1.latestChapterTime }
        case 2:
            return books.sorted { Self.cnCompare($0.name, $1.name) == .orderedAscending }
        case 3:
            return books.sorted { $0.order < $1.order }
        case 4:
            return books.sorted {
                max($0.latestChapterTime, $0.durChapterTime) > max($1.latestChapterTime, $1.durChapterTime)
            }
        case 5:
            return books.sorted { Self.cnCompare($0.author, $1.author) == .orderedAscending }
        default:
            return books.sorted { $0.durChapterTime > $1.durChapterTime }
        }
    }

    private func displaySortMode(for groupId: Int64) -> Int32 {
        let groupId = Self.normalizedGroupId(groupId)
        if let group = currentGroups.first(where: { $0.groupId == groupId }), group.bookSort >= 0 {
            return group.bookSort
        }
        return currentBookshelfSortValue() ?? 0
    }

    private static func cnCompare(_ left: String, _ right: String) -> ComparisonResult {
        left.compare(
            right,
            options: [],
            range: nil,
            locale: simplifiedChineseLocale
        )
    }

    private func preferencesIndex() -> Int {
        Int(currentPreferences?.saveTabPosition ?? 0)
    }

    func currentBookshelfSortValue() -> Int32? {
        currentPreferences?.bookshelfSort
    }

    func currentBookGroupStyleValue() -> Int32 {
        currentPreferences?.bookGroupStyle ?? 0
    }

    private func handlePreferenceDrivenSelection(previousGroupStyle: Int32?) {
        let enteringFolderStyle =
            previousGroupStyle != nil && previousGroupStyle != 1 && currentBookGroupStyleValue() == 1
        resolveGroupSelection(enteringFolderStyle: enteringFolderStyle)
    }

    private func resolveGroupSelection(fallbackIndex: Int? = nil, enteringFolderStyle: Bool = false) {
        guard currentPreferences != nil, hasReceivedGroups || currentBookGroupStyleValue() == 1 else {
            return
        }
        let wasResolved = hasResolvedInitialGroup
        let previousGroupId = selectedGroupId
        if !hasResolvedInitialGroup {
            hasResolvedInitialGroup = true
            selectedGroupId =
                currentBookGroupStyleValue() == 1
                ? Self.rootGroupId
                : fallbackGroupId(at: preferencesIndex())
        } else if enteringFolderStyle {
            selectedGroupId = Self.rootGroupId
        } else if !isSelectableGroup(selectedGroupId) {
            if currentBookGroupStyleValue() == 1 {
                selectedGroupId = Self.rootGroupId
            } else if selectedGroupId == Self.rootGroupId,
                let lastSelectedVisibleGroupId, isSelectableGroup(lastSelectedVisibleGroupId)
            {
                selectedGroupId = lastSelectedVisibleGroupId
            } else {
                selectedGroupId = fallbackGroupId(at: fallbackIndex ?? preferencesIndex())
            }
        }
        if currentGroups.contains(where: { $0.groupId == selectedGroupId }) {
            lastSelectedVisibleGroupId = selectedGroupId
        }
        if wasResolved, selectedGroupId != previousGroupId {
            persistSelectedGroup()
        }
        notifyGroupsChange()
        if !hasBooksBinding || selectedGroupId != previousGroupId
            || boundBooksSortMode != displaySortMode(for: selectedGroupId)
        {
            bindBooks()
        }
    }

    private func persistSelectedGroup() {
        guard let settingsFacade,
            let index = currentGroups.firstIndex(where: { $0.groupId == selectedGroupId })
        else { return }
        let previousTask = selectionPersistenceTask
        // Wait for the actual shared write; cancelling a Swift task cannot undo it.
        selectionPersistenceTask = Task { @MainActor in
            await previousTask?.value
            do {
                try await settingsFacade.setSaveTabPositionAsync(position: Int32(index))
            } catch {
                SharedRuntime.log("persist bookshelf selected group failed: \(error.localizedDescription)")
            }
        }
    }
}
