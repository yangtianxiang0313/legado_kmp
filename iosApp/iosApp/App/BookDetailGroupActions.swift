import UIKit
import shared

@MainActor
final class BookDetailGroupActions {
    private weak var presenter: UIViewController?
    private weak var picker: AndroidReplicaBookDetailGroupPickerViewController?
    private let adapter: AndroidReplicaBookDetailAdapter
    private let currentBook: () -> Book?
    private let canPresent: () -> Bool
    private let onNameChange: (String) -> Void
    private let onBusyChange: (Bool) -> Void
    private let onCommitted: (Book) -> Void
    private var labelTask: Task<Void, Never>?
    private var labelID = UUID()
    private var labelKey: String?
    private var isCommitting = false

    init(
        presenter: UIViewController,
        adapter: AndroidReplicaBookDetailAdapter,
        currentBook: @escaping () -> Book?,
        canPresent: @escaping () -> Bool,
        onNameChange: @escaping (String) -> Void,
        onBusyChange: @escaping (Bool) -> Void,
        onCommitted: @escaping (Book) -> Void
    ) {
        self.presenter = presenter
        self.adapter = adapter
        self.currentBook = currentBook
        self.canPresent = canPresent
        self.onNameChange = onNameChange
        self.onBusyChange = onBusyChange
        self.onCommitted = onCommitted
    }

    deinit { labelTask?.cancel() }

    func refreshLabel(for book: Book, force: Bool = false) {
        let key = "\(book.bookUrl)|\(book.group)|\(book.isLocal)"
        guard force || key != labelKey else { return }
        labelTask?.cancel()
        labelKey = key
        let id = UUID()
        labelID = id
        let fallback = book.isLocal ? L10n.BookDetail.groupFallbackLocal : L10n.BookDetail.groupFallbackRemote
        onNameChange(fallback)
        labelTask = Task { [weak self, adapter] in
            do {
                let groups = try await adapter.loadGroups()
                guard let self, self.labelID == id, !Task.isCancelled,
                    self.currentBook()?.bookUrl == book.bookUrl, self.currentBook()?.group == book.group
                else { return }
                let names = groups.filter { $0.groupId & book.group != 0 }.map(\.groupName)
                self.onNameChange(names.isEmpty ? fallback : names.joined(separator: ","))
            } catch {
                guard let self, self.labelID == id, !Task.isCancelled else { return }
                // A failed lookup can be retried on the next appearance or when opening the picker.
                self.labelKey = nil
            }
        }
    }

    func presentPicker() {
        guard !isCommitting, canPresent(), let presenter, presenter.presentedViewController == nil,
            let book = currentBook()
        else { return }
        let expectedURL = book.bookUrl
        let controller = AndroidReplicaBookDetailGroupPickerViewController(
            groupID: book.group,
            loadGroups: { [adapter] in try await adapter.loadGroups() },
            saveGroup: { [adapter] id, draft in try await adapter.saveGroupDetails(groupID: id, draft: draft) },
            deleteGroup: { [adapter] id in try await adapter.deleteBookGroup(id) },
            reorderGroups: { [adapter] ids in try await adapter.reorderBookGroups(ids) },
            observeGroups: { [adapter] onUpdate in try adapter.observeSelectableGroups(onUpdate) },
            commit: { [weak self] groupID in
                guard let self, self.canPresent(), self.currentBook()?.bookUrl == expectedURL,
                    let presenter = self.presenter, presenter.presentedViewController === self.picker
                else { throw CancellationError() }
                self.isCommitting = true
                self.onBusyChange(true)
                defer {
                    self.isCommitting = false
                    self.onBusyChange(false)
                }
                let updated = try await self.adapter.updateGroup(groupID: groupID, expectedBookURL: expectedURL)
                // Publish an actual write even if the presenting scene has since left the foreground.
                self.onCommitted(updated)
                self.refreshLabel(for: updated, force: true)
            }
        )
        controller.onGroupsChanged = { [weak self] in self?.refreshAfterGroupMutation(expectedURL: expectedURL) }
        picker = controller
        presenter.present(controller, animated: true)
    }

    private func refreshAfterGroupMutation(expectedURL: String) {
        labelTask?.cancel()
        labelTask = Task { [weak self, adapter] in
            do {
                let updated = try await adapter.prepareBookEditor()
                guard let self, !Task.isCancelled, self.currentBook()?.bookUrl == expectedURL,
                    updated.bookUrl == expectedURL
                else { return }
                self.onCommitted(updated)
                self.refreshLabel(for: updated, force: true)
            } catch {}
        }
    }

    func cancelPreparation() {
        labelTask?.cancel()
        labelID = UUID()
        labelKey = nil
        guard !isCommitting else { return }
        let owned = picker
        picker = nil
        guard owned?.presentingViewController === presenter else { return }
        owned?.dismiss(animated: false)
    }
}
