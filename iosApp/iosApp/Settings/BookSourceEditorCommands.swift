import UIKit
import shared

struct BookSourceEditorCommandContext: Equatable {
    let sourceURL: String
    let draftRevision: Int
    let session: UUID
    let scene: ObjectIdentifier
    let window: ObjectIdentifier
}

/// Owns read-only import sessions and the state-store dialog, never the editor draft or source save.
@MainActor
final class BookSourceEditorCommands: NSObject, UIAdaptivePresentationControllerDelegate {
    private weak var presenter: UIViewController?
    private let screen: BookSourceEditingProviding
    private let accepts: (BookSourceEditorCommandContext, UIViewController?) -> Bool
    private let onDraft: ([String: Any]) -> Void
    private let onPresentationChange: () -> Void
    private let importer = SourceImportScreenAdapter()
    private var readTask: Task<Void, Never>?
    private var requestID: UUID?
    private weak var ownedModal: UIViewController?
    private var ownedContext: BookSourceEditorCommandContext?
    private(set) var isBusy = false

    init(
        presenter: UIViewController, screen: BookSourceEditingProviding,
        accepts: @escaping (BookSourceEditorCommandContext, UIViewController?) -> Bool,
        onDraft: @escaping ([String: Any]) -> Void, onPresentationChange: @escaping () -> Void
    ) {
        self.presenter = presenter
        self.screen = screen
        self.accepts = accepts
        self.onDraft = onDraft
        self.onPresentationChange = onPresentationChange
        super.init()
    }

    deinit { readTask?.cancel() }

    func owns(_ modal: UIViewController?) -> Bool { modal != nil && modal === ownedModal }

    func invalidate() {
        requestID = nil
        readTask?.cancel()
        readTask = nil
        isBusy = false
        // A dialog write already authorized by Save is intentionally not cancelled.
        ownedContext = nil
        onPresentationChange()
    }

    func refreshPresentation() {
        if let modal = ownedModal, modal.presentingViewController == nil, !modal.isBeingPresented {
            ownedModal = nil
            ownedContext = nil
            onPresentationChange()
        }
    }

    func importDraft(_ text: String, context: BookSourceEditorCommandContext) {
        guard accepts(context, nil), !isBusy else { return }
        let id = startRead()
        readTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try self.importer.bootstrap().get()
                let preview = try await self.importer.prepareEditorDrafts(payload: text)
                guard self.requestID == id, !Task.isCancelled, self.accepts(context, nil) else {
                    self.finishRead(id)
                    return
                }
                self.finishRead(id)
                self.presentDraftPicker(preview, context: context)
            } catch {
                let current = self.requestID == id && !Task.isCancelled && self.accepts(context, nil)
                self.finishRead(id)
                if current { self.presenter?.presentError(error) }
            }
        }
    }

    func scanDraft(context: BookSourceEditorCommandContext) {
        guard accepts(context, nil), let presenter else { return }
        let scanner = QRCodeScannerViewController()
        let navigation = BookSourceEditorScannerNavigationController(rootViewController: scanner)
        navigation.modalPresentationStyle = .overFullScreen
        navigation.onDismiss = { [weak self, weak navigation] in self?.release(navigation) }
        scanner.onQRCodeScanned = { [weak self, weak navigation, weak scanner] text in
            guard let self, let navigation, let scanner,
                navigation.topViewController === scanner, navigation.presentedViewController == nil,
                self.acceptsOwned(context, modal: navigation)
            else { return }
            // Continue only after the scanner has actually detached from this exact editor session.
            navigation.dismiss(animated: true) { [weak self] in
                guard let self, navigation.presentingViewController == nil else { return }
                self.release(navigation)
                if self.accepts(context, nil) { self.importDraft(text, context: context) }
            }
        }
        own(navigation, context: context)
        presenter.present(navigation, animated: true)
    }

    func editVariable(source: BookSource, context: BookSourceEditorCommandContext) {
        guard context.sourceURL == source.bookSourceUrl, accepts(context, nil), !isBusy else { return }
        let id = startRead()
        readTask = Task { @MainActor [weak self, screen] in
            guard let self else { return }
            do {
                let value = try await screen.getSourceVariable(sourceUrl: source.bookSourceUrl)
                guard self.requestID == id, !Task.isCancelled, self.accepts(context, nil) else {
                    self.finishRead(id)
                    return
                }
                self.finishRead(id)
                let fallback = "源变量可在js中通过source.getVariable()获取"
                let comment =
                    source.variableComment.flatMap {
                        $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 + "\n" + fallback
                    } ?? fallback
                let editor = BookDetailVariableDialogViewController(
                    title: BookSourceEditorMenuAction.sourceVariable.title, variable: value, comment: comment
                ) { [weak self, screen] variable in
                    guard let self, let modal = self.ownedModal, self.acceptsOwned(context, modal: modal) else {
                        throw CancellationError()
                    }
                    // No cancellation or navigation checks after the user-authorized write starts.
                    try await screen.setSourceVariable(sourceUrl: source.bookSourceUrl, value: variable)
                }
                editor.canSave = { [weak self, weak editor] in
                    guard let self, let editor else { return false }
                    return self.acceptsOwned(context, modal: editor)
                }
                editor.onDismiss = { [weak self, weak editor] in self?.release(editor) }
                self.own(editor, context: context)
                self.presenter?.present(editor, animated: true)
            } catch {
                let current = self.requestID == id && !Task.isCancelled && self.accepts(context, nil)
                self.finishRead(id)
                if current { self.presenter?.presentError(error) }
            }
        }
    }

    func editReview(text: String, context: BookSourceEditorCommandContext, onSave: @escaping (String) -> Void) {
        guard accepts(context, nil), let presenter else { return }
        let editor = BookSourceEditorReviewCommand(text: text, onSave: onSave)
        let navigation = UINavigationController(rootViewController: editor)
        navigation.modalPresentationStyle = .overFullScreen
        editor.canSave = { [weak self, weak navigation, weak editor] in
            guard let self, let navigation, let editor, navigation.topViewController === editor else { return false }
            return self.acceptsOwned(context, modal: navigation)
        }
        own(navigation, context: context)
        presenter.present(navigation, animated: true)
    }

    func showRuleHelp(context: BookSourceEditorCommandContext) {
        guard accepts(context, nil), let presenter else { return }
        let viewer = BookSourceDebugRawViewController(helpHTML: BookSourceEditorRuleHelp.html)
        viewer.isContentCurrent = { [weak self, weak viewer] in
            guard let self, let viewer else { return false }
            return self.acceptsOwned(context, modal: viewer)
        }
        viewer.onClose = { [weak self, weak viewer] in self?.release(viewer) }
        viewer.overrideUserInterfaceStyle = presenter.traitCollection.userInterfaceStyle
        own(viewer, context: context)
        presenter.present(viewer, animated: true)
    }

    private func presentDraftPicker(_ preview: SourceEditorImportPreview, context: BookSourceEditorCommandContext) {
        guard accepts(context, nil), let presenter else { return }
        let picker = BookSourceEditorDraftPickerViewController(preview: preview)
        let navigation = UINavigationController(rootViewController: picker)
        navigation.modalPresentationStyle = .overFullScreen
        picker.canSelect = { [weak self, weak navigation, weak picker] in
            guard let self, let navigation, let picker, navigation.topViewController === picker else { return false }
            return self.acceptsOwned(context, modal: navigation)
        }
        picker.onSelect = { [weak self, weak navigation] payload in
            guard let self, let navigation, self.acceptsOwned(context, modal: navigation) else { return }
            navigation.dismiss(animated: true) { [weak self] in
                guard let self, navigation.presentingViewController == nil else { return }
                self.release(navigation)
                guard self.accepts(context, nil) else { return }
                do { self.onDraft(try BookSourceEditorDraft.decodePayload(payload)) } catch { self.presenter?.presentError(error) }
            }
        }
        picker.onCancel = { [weak self, weak navigation] in
            guard let navigation else { return }
            navigation.dismiss(animated: true) { [weak self] in self?.release(navigation) }
        }
        own(navigation, context: context)
        presenter.present(navigation, animated: true)
    }

    private func startRead() -> UUID {
        readTask?.cancel()
        let id = UUID()
        requestID = id
        isBusy = true
        onPresentationChange()
        return id
    }

    private func finishRead(_ id: UUID) {
        guard requestID == id else { return }
        requestID = nil
        readTask = nil
        isBusy = false
        onPresentationChange()
    }

    private func acceptsOwned(_ context: BookSourceEditorCommandContext, modal: UIViewController) -> Bool {
        ownedContext == context && modal === ownedModal && !modal.isBeingDismissed && !modal.isBeingPresented
            && modal.presentedViewController == nil && accepts(context, modal)
    }

    private func own(_ modal: UIViewController, context: BookSourceEditorCommandContext) {
        ownedModal = modal
        ownedContext = context
        modal.presentationController?.delegate = self
        onPresentationChange()
    }

    private func release(_ modal: UIViewController?) {
        guard let modal, modal === ownedModal else { return }
        ownedModal = nil
        ownedContext = nil
        onPresentationChange()
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        release(presentationController.presentedViewController)
    }
}

private final class BookSourceEditorScannerNavigationController: UINavigationController {
    var onDismiss: (() -> Void)?

    override func popViewController(animated: Bool) -> UIViewController? {
        guard viewControllers.count == 1 else { return super.popViewController(animated: animated) }
        dismiss(animated: animated)
        return nil
    }

    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        super.dismiss(animated: flag) { [weak self] in
            if self?.presentingViewController == nil {
                self?.onDismiss?()
                self?.onDismiss = nil
            }
            completion?()
        }
    }
}
