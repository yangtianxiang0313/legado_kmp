import UIKit
import shared

/// ReadBookActivity's selection / replaceActivity result and EffectiveReplacesDialog editor round trip.
@MainActor
final class ReaderReplaceRuleCoordinator {
    private struct ChapterIdentity: Equatable {
        let bookURL: String
        let index: Int
        let chapterURL: String?
    }

    private struct SelectionReload {
        let context: ChapterIdentity
        let position: Int
    }

    private weak var reader: ReaderContainerViewController?
    private weak var dialog: ReaderEffectiveReplaceRulesDialogViewController?
    private var requestID: UUID?
    private var listTask: Task<Void, Never>?
    private var changedBookURL: String?
    private var selectionReload: SelectionReload?

    init(reader: ReaderContainerViewController) { self.reader = reader }

    deinit { listTask?.cancel() }

    func openManagement() {
        guard let reader, canPresent(in: reader), let navigation = reader.navigationController else { return }
        reader.setMenuVisible(false)
        reader.stopAutoPage(showMessage: false)
        let bookURL = reader.bookURL
        let controller = AndroidReplicaReplaceRuleViewController().configuredForDrillDownPresentation()
        controller.onRulesChanged = { [weak self] in self?.rulesDidChange(bookURL: bookURL) }
        navigation.pushViewController(controller, animated: true)
    }

    func openSelection(text: String) {
        guard let reader, canPresent(in: reader), dialog == nil, listTask == nil else { return }
        reader.setMenuVisible(false)
        reader.stopAutoPage(showMessage: false)
        let context = identity(in: reader)
        let position = reader.currentCharacterOffset()
        let id = UUID()
        requestID = id
        listTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.requestID == id {
                    self.requestID = nil
                    self.listTask = nil
                }
            }
            do {
                let book = try await reader.screen.resolveCurrentBook()
                var sourceURL: String?
                if !book.isLocal, !book.origin.isEmpty {
                    let facade = try SharedRuntime.sourceManagementFacade().get()
                    let source = try await facade.getSourceAsync(sourceUrl: book.origin)
                    sourceURL = source?.bookSourceUrl
                }
                try Task.checkCancellation()
                guard self.requestID == id, book.bookUrl == context.bookURL,
                    self.identity(in: reader) == context, self.canPresent(in: reader),
                    reader.book?.origin == book.origin
                else { return }
                let facade = try SharedRuntime.replaceRuleFacade().get()
                let draft = ReplaceRuleEditorDraft.selection(text: text, bookName: book.name, sourceURL: sourceURL)
                let editor = ReplaceRuleEditorViewController(rule: nil, facade: facade, initialDraft: draft) {
                    [weak self] _ in
                    guard let self else { return }
                    self.rulesDidChange(
                        bookURL: context.bookURL, selection: SelectionReload(context: context, position: position))
                    self.resume()
                }
                let navigation = UINavigationController(rootViewController: editor)
                navigation.modalPresentationStyle = .fullScreen
                navigation.overrideUserInterfaceStyle = reader.readMenu.overflowInterfaceStyle
                reader.dismissTextSelectionMenu(clearSelection: true)
                reader.present(navigation, animated: true)
            } catch is CancellationError {
            } catch {
                guard self.requestID == id, self.identity(in: reader) == context, self.canPresent(in: reader) else {
                    return
                }
                reader.showToast(error.userFacingMessage)
            }
        }
    }

    func showEffectiveRules() {
        guard let reader, canPresent(in: reader), dialog == nil, listTask == nil else { return }
        let context = identity(in: reader)
        let id = UUID()
        requestID = id
        listTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.requestID == id {
                    self.requestID = nil
                    self.listTask = nil
                }
            }
            do {
                let rules = try await reader.screen.getEffectiveReplaceRules()
                try Task.checkCancellation()
                guard self.requestID == id, self.identity(in: reader) == context, self.canPresent(in: reader) else {
                    return
                }
                self.present(rules, in: reader, context: context)
            } catch is CancellationError {
            } catch {
                guard self.requestID == id, self.identity(in: reader) == context, self.canPresent(in: reader) else {
                    return
                }
                reader.showToast(error.userFacingMessage)
            }
        }
    }

    /// Only returning to this reader consumes changes. Cancelling an editor never reloads it.
    func resume() {
        guard let reader, dialog == nil, canPresent(in: reader), changedBookURL == reader.bookURL else { return }
        changedBookURL = nil
        let selection = selectionReload
        selectionReload = nil
        if let selection, selection.context == identity(in: reader) {
            reader.chapterLoadCoordinator.load(
                in: reader, index: selection.context.index, restorePosition: selection.position)
            return
        }
        // A changed reader context must not jump back to the selection's stale chapter / anchor.
        reader.chapterLoadCoordinator.load(
            in: reader, index: reader.chapterIndex, restorePosition: reader.currentCharacterOffset())
    }

    private func rulesDidChange(bookURL: String, selection: SelectionReload? = nil) {
        changedBookURL = bookURL
        selectionReload = selection
    }

    private func present(_ rules: [ReplaceRule], in reader: ReaderContainerViewController, context: ChapterIdentity) {
        reader.setMenuVisible(false)
        reader.stopAutoPage(showMessage: false)
        let controller = ReaderEffectiveReplaceRulesDialogViewController(
            rules: rules, showsChineseConversion: (reader.runtimeConfig?.reader.chineseMode ?? 0) > 0,
            onSelect: { [weak self] rule in self?.openEditor(rule, context: context) },
            onSelectChineseConversion: { [weak self] in self?.openChineseConversion(context: context) },
            onDismiss: { [weak self] in
                guard let self else { return }
                self.dialog = nil
                self.requestID = nil
                self.listTask?.cancel()
                self.listTask = nil
                self.resume()
            })
        controller.overrideUserInterfaceStyle = reader.readMenu.overflowInterfaceStyle
        dialog = controller
        reader.present(controller, animated: true)
    }

    private func openEditor(_ rule: ReplaceRule, context: ChapterIdentity) {
        guard let reader, let dialog, canEdit(in: dialog, reader: reader, context: context) else { return }
        let facade: ReplaceRuleFacade
        switch SharedRuntime.replaceRuleFacade() {
        case .success(let value): facade = value
        case .failure(let error):
            dialog.showTransientMessage(error.userFacingMessage)
            return
        }
        let editor = ReplaceRuleEditorViewController(rule: rule, facade: facade) { [weak self] _ in
            guard let self else { return }
            self.rulesDidChange(bookURL: context.bookURL)
            self.refreshRules(context: context)
        }
        let navigation = UINavigationController(rootViewController: editor)
        navigation.modalPresentationStyle = .fullScreen
        navigation.overrideUserInterfaceStyle = dialog.traitCollection.userInterfaceStyle
        dialog.present(navigation, animated: true)
    }

    private func refreshRules(context: ChapterIdentity) {
        guard let reader, let dialog, identity(in: reader) == context else { return }
        listTask?.cancel()
        let id = UUID()
        requestID = id
        dialog.setBusy(true)
        listTask = Task { [weak self, weak dialog] in
            guard let self, let dialog else { return }
            defer {
                if self.requestID == id {
                    self.requestID = nil
                    self.listTask = nil
                    dialog.setBusy(false)
                }
            }
            do {
                let rules = try await reader.screen.getEffectiveReplaceRules()
                try Task.checkCancellation()
                guard self.requestID == id, self.dialog === dialog, self.identity(in: reader) == context else { return }
                dialog.updateRules(rules, showsChineseConversion: (reader.runtimeConfig?.reader.chineseMode ?? 0) > 0)
            } catch is CancellationError {
            } catch {
                guard self.requestID == id, self.dialog === dialog, self.identity(in: reader) == context else { return }
                dialog.showTransientMessage(error.userFacingMessage)
            }
        }
    }

    private func openChineseConversion(context: ChapterIdentity) {
        guard let reader, let dialog, canEdit(in: dialog, reader: reader, context: context),
            reader.runtimeConfig?.reader != nil
        else { return }
        let choice = ReaderStyleChoice.chineseMode
        let picker = ReaderStyleChoiceDialogViewController(titleText: choice.titleText, items: choice.items) {
            [weak self, weak dialog] index in
            guard let self, let dialog, let reader = self.reader,
                self.canEdit(in: dialog, reader: reader, context: context),
                choice.items.indices.contains(index), let config = reader.runtimeConfig?.reader,
                config.chineseMode != Int32(index)
            else { return }
            dialog.setBusy(true)
            Task { [weak self, weak dialog] in
                guard let self, let dialog else { return }
                var refreshing = false
                defer { if !refreshing { dialog.setBusy(false) } }
                do {
                    try await reader.screen.setReaderRuntimeConfig(
                        config: config.androidCopy(chineseMode: Int32(index)))
                    self.rulesDidChange(bookURL: context.bookURL)
                    guard self.dialog === dialog, self.identity(in: reader) == context else { return }
                    refreshing = true
                    self.refreshRules(context: context)
                } catch {
                    guard self.dialog === dialog, self.identity(in: reader) == context else { return }
                    dialog.showTransientMessage(error.userFacingMessage)
                }
            }
        }
        picker.overrideUserInterfaceStyle = dialog.traitCollection.userInterfaceStyle
        dialog.present(picker, animated: true)
    }

    private func identity(in reader: ReaderContainerViewController) -> ChapterIdentity {
        ChapterIdentity(bookURL: reader.bookURL, index: reader.chapterIndex, chapterURL: reader.currentChapterURL)
    }

    private func canPresent(in reader: ReaderContainerViewController) -> Bool {
        reader.viewIfLoaded?.window != nil && reader.navigationController?.topViewController === reader
            && reader.presentedViewController == nil && !reader.isMovingFromParent && !reader.isBeingDismissed
            && reader.view.window?.windowScene?.activationState == .foregroundActive
    }

    private func canEdit(
        in dialog: ReaderEffectiveReplaceRulesDialogViewController, reader: ReaderContainerViewController,
        context: ChapterIdentity
    ) -> Bool {
        self.dialog === dialog && identity(in: reader) == context && reader.presentedViewController === dialog
            && dialog.presentingViewController != nil && dialog.presentedViewController == nil
            && !dialog.isBeingDismissed && !reader.isMovingFromParent && !reader.isBeingDismissed
            && dialog.viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive
    }
}
