import UIKit
import shared

@MainActor
final class BookshelfGroupEditingCoordinator {
    private weak var presenter: UIViewController?
    private let screen: BookshelfScreenAdapter
    private let onCommitted: () -> Void
    private weak var editor: BookGroupEditorViewController?
    private var preparation: Task<Void, Never>?
    private var preparationID: UUID?
    private var mutation: Task<Void, Never>?

    init(
        presenter: UIViewController, screen: BookshelfScreenAdapter, onCommitted: @escaping () -> Void
    ) {
        self.presenter = presenter
        self.screen = screen
        self.onCommitted = onCommitted
    }

    deinit { preparation?.cancel() }

    func cancelPreparation() {
        preparationID = nil
        preparation?.cancel()
        preparation = nil
    }

    func edit(groupID: Int64) {
        guard canPresent, preparation == nil, mutation == nil, editor == nil else { return }
        let id = UUID()
        preparationID = id
        preparation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.preparationID == id {
                    self.preparationID = nil
                    self.preparation = nil
                }
            }
            do {
                let groups = try await self.screen.loadGroups()
                try Task.checkCancellation()
                guard self.preparationID == id, self.canPresent,
                    let group = groups.first(where: { $0.groupId == groupID && $0.show }),
                    let presenter = self.presenter
                else { return }
                let controller = BookGroupEditorViewController(group: group)
                controller.onSave = { [weak self, weak controller] draft in
                    guard let controller else { return }
                    guard let self, self.canUse(controller), self.mutation == nil else {
                        controller.setBusy(false)
                        return
                    }
                    self.save(draft, groupID: groupID, editor: controller)
                }
                controller.onDelete = { [weak self, weak controller] in
                    guard let controller else { return }
                    guard let self, groupID > 0, self.canUse(controller), self.mutation == nil else {
                        controller.setBusy(false)
                        return
                    }
                    self.confirmDelete(groupID: groupID, editor: controller)
                }
                controller.onCancel = { [weak self, weak controller] in
                    guard let self, let controller, self.editor === controller, self.mutation == nil else {
                        return
                    }
                    self.close(controller)
                }
                self.editor = controller
                presenter.present(controller, animated: !UIAccessibility.isReduceMotionEnabled)
            } catch is CancellationError {
            } catch {
                if self.preparationID == id, self.canPresent {
                    self.presenter?.showTransientMessage(error.userFacingMessage)
                }
            }
        }
    }

    private var canPresent: Bool {
        guard let presenter else { return false }
        return presenter.isVisibleInNavigationStack && presenter.presentedViewController == nil
            && !presenter.isBeingDismissed && !presenter.isMovingFromParent
            && presenter.viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive
    }

    private func canUse(_ controller: BookGroupEditorViewController) -> Bool {
        guard let presenter else { return false }
        return editor === controller && presenter.presentedViewController === controller
            && presenter.isVisibleInNavigationStack && !presenter.isBeingDismissed
            && !controller.isBeingDismissed && !controller.isBeingPresented
            && controller.viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive
    }

    private func save(
        _ draft: BookGroupEditDraft, groupID: Int64, editor: BookGroupEditorViewController
    ) {
        // The submitted cover and write outlive a forced UI departure; success must still commit ownership.
        mutation = Task { @MainActor [self, editor] in
            defer { mutation = nil }
            do {
                try await screen.saveManagedGroup(groupId: groupID, draft: draft)
                editor.markCoverCommitted()
                onCommitted()
                if self.editor === editor { close(editor) }
            } catch {
                editor.showError(error.userFacingMessage)
            }
        }
    }

    private func confirmDelete(groupID: Int64, editor: BookGroupEditorViewController) {
        BookshelfGroupDeletionConfirmation.present(
            in: editor,
            isCurrent: { [weak self, weak editor] in
                guard let self, let editor else { return false }
                return self.canUse(editor) && self.mutation == nil && groupID > 0
            },
            onConfirm: { [weak self, weak editor] in
                guard let editor else { return }
                guard let self, self.canUse(editor), self.mutation == nil else {
                    editor.setBusy(false)
                    return
                }
                self.mutation = Task { @MainActor [self, editor] in
                    defer { self.mutation = nil }
                    do {
                        try await self.screen.deleteGroup(groupId: groupID)
                        self.onCommitted()
                        if self.editor === editor { self.close(editor) }
                    } catch {
                        editor.showError(error.userFacingMessage)
                        self.onCommitted()
                    }
                }
            })
    }

    private func close(_ controller: BookGroupEditorViewController) {
        guard editor === controller else { return }
        controller.onSave = nil
        controller.onDelete = nil
        controller.onCancel = nil
        controller.dismiss(animated: !UIAccessibility.isReduceMotionEnabled) {
            [weak self, weak controller] in
            if self?.editor === controller { self?.editor = nil }
        }
    }
}
