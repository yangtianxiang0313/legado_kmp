import Foundation
import shared

@MainActor
final class CacheScreenAdapter {
    private let bindings = ScreenBindingController(owner: "CacheScreen")
    private var facade: CacheFacade?
    private var settings: SettingsFacade?
    private var bookshelf: BookshelfFacade?
    private var groupTask: Task<Void, Never>?
    private var groupLoadID = UUID()
    private var bindingID = UUID()
    private var booksID = UUID()
    var onBooksChange: (([Book]) -> Void)?
    var onGroupsChange: (([BookGroup]) -> Void)?
    var onSortChange: (() -> Void)?
    var onGroupError: ((String) -> Void)?

    func bootstrap(groupID: Int64) throws {
        unbind()
        facade = try SharedRuntime.cacheFacade().get()
        settings = try SharedRuntime.settingsFacade().get()
        bookshelf = try SharedRuntime.bookshelfFacade().get()
        let id = bindingID
        if let facade {
            bindings.bind(
                facade.watchBookGroups { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.bindingID == id else { return }
                        self.loadGroups()
                    }
                })
        }
        if let settings {
            bindings.bind(
                settings.watchPreferences { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.bindingID == id else { return }
                        self.onSortChange?()
                    }
                })
        }
        selectGroup(groupID)
    }

    private func loadGroups() {
        guard let bookshelf else { return }
        groupTask?.cancel()
        let id = UUID()
        groupLoadID = id
        groupTask = Task { [weak self] in
            do {
                // The cache watch contains persisted rows only; the bookshelf loader also
                // supplies the core's actual system groups, including hidden/empty groups.
                let groups = try await bookshelf.loadGroupsAsync()
                guard let self, !Task.isCancelled, self.groupLoadID == id else { return }
                self.groupTask = nil
                self.onGroupsChange?(groups)
            } catch {
                guard let self, !Task.isCancelled, self.groupLoadID == id else { return }
                self.groupTask = nil
                self.onGroupError?(error.userFacingMessage)
            }
        }
    }

    func selectGroup(_ groupID: Int64) {
        guard let facade else { return }
        let id = UUID()
        booksID = id
        bindings.replaceBinding(
            key: "books",
            with: facade.watchBooks(groupId: KotlinLong(value: groupID)) { [weak self] books in
                Task { @MainActor in
                    guard let self, self.booksID == id else { return }
                    self.onBooksChange?(books)
                }
            })
    }

    func sortMode(groupID: Int64) async throws -> Int {
        guard let settings else { throw unavailable() }
        let value: KotlinInt = try await SharedAsync.value { completion in
            settings.getBookSortByGroupId(groupId: groupID, completionHandler: completion)
        }
        return Int(value.int32Value)
    }

    func cacheInfo(_ book: Book) async throws -> BookCacheInfo {
        guard let facade else { throw unavailable() }
        return try await facade.getBookCacheInfo(book: book)
    }

    func unbind() {
        groupLoadID = UUID()
        groupTask?.cancel()
        groupTask = nil
        bindingID = UUID()
        booksID = UUID()
        bindings.cancelAll()
        facade = nil
        settings = nil
        bookshelf = nil
    }

    private func unavailable() -> NSError {
        NSError(
            domain: "io.legado.cache", code: -1, userInfo: [NSLocalizedDescriptionKey: L10n.Common.unavailableTitle])
    }
}
