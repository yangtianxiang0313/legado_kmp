import UIKit
import UniformTypeIdentifiers
import shared

/// BookSourceActivity's direct local / online / QR import routes share the real preview.
@MainActor
final class BookSourceImportCoordinator: NSObject, UIDocumentPickerDelegate {
    private weak var presenter: UIViewController?
    private let screen = SourceImportScreenAdapter()
    private let canPresent: () -> Bool
    private let onBusyChange: (Bool) -> Void
    private let onImported: () -> Void
    private var workflowID = UUID()
    private weak var input: BookSourceOnlineImportDialogViewController?
    private weak var preview: SourceImportPreviewViewController?
    private weak var picker: UIDocumentPickerViewController?
    private var isImporting = false
    private var result: SourceImportResult?

    init(
        presenter: UIViewController, canPresent: @escaping () -> Bool,
        onBusyChange: @escaping (Bool) -> Void, onImported: @escaping () -> Void
    ) {
        self.presenter = presenter
        self.canPresent = canPresent
        self.onBusyChange = onBusyChange
        self.onImported = onImported
    }

    static func importSource(for text: String) throws -> ImportSource {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(
                domain: "io.legado.kmp.ios", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "请输入导入内容"])
        }
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            return .url(trimmed)
        }
        return .payload(text)
    }

    func openOnline() {
        guard canStart(), let presenter else { return }
        do { try screen.bootstrap().get() } catch {
            presenter.showTransientMessage(error.userFacingMessage)
            return
        }
        workflowID = UUID()
        let id = workflowID
        let dialog = BookSourceOnlineImportDialogViewController(
            onSubmit: { [weak self] text in
                guard let self, self.workflowID == id, self.isHostAttached() else { throw CancellationError() }
                self.onBusyChange(true)
                defer { if self.workflowID == id { self.onBusyChange(false) } }
                let value = try await self.screen.preparePreview(source: Self.importSource(for: text))
                try Task.checkCancellation()
                guard self.workflowID == id, self.isHostAttached() else { throw CancellationError() }
                return value
            },
            onReady: { [weak self] value in self?.presentPreview(value, id: id) },
            onDismiss: { [weak self] in
                guard let self, self.workflowID == id else { return }
                self.input = nil
                self.onBusyChange(false)
            })
        input = dialog
        dialog.overrideUserInterfaceStyle = presenter.traitCollection.userInterfaceStyle
        presenter.present(dialog, animated: true)
    }

    func openFile() {
        guard canStart(), let presenter else { return }
        workflowID = UUID()
        let controller = UIDocumentPickerViewController(forOpeningContentTypes: [.json, .plainText])
        controller.allowsMultipleSelection = false
        controller.delegate = self
        picker = controller
        presenter.present(controller, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard picker === controller, let url = urls.first else { return }
        let id = workflowID
        afterDismissing(controller) { [weak self] in self?.prepareFile(url, id: id) }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        if picker === controller { picker = nil }
    }

    func openQR() {
        guard canStart(), let presenter, let navigation = presenter.navigationController else { return }
        workflowID = UUID()
        let id = workflowID
        let scanner = QRCodeScannerViewController()
        scanner.onQRCodeScanned = { [weak self, weak scanner, weak navigation] text in
            guard let self, let scanner, let navigation, self.workflowID == id,
                navigation.topViewController === scanner
            else { return }
            navigation.popViewController(animated: true)
            let finish: @MainActor @Sendable () -> Void = { [weak self] in
                guard let self, self.workflowID == id, self.isHostAttached() else { return }
                do { self.prepare(try Self.importSource(for: text), id: id) } catch {
                    self.presenter?.showTransientMessage(error.userFacingMessage)
                }
            }
            if let transition = navigation.transitionCoordinator {
                let registered = transition.animate(alongsideTransition: nil) { context in if !context.isCancelled { finish() } }
                if !registered { DispatchQueue.main.async(execute: finish) }
            } else {
                DispatchQueue.main.async(execute: finish)
            }
        }
        navigation.pushViewController(scanner, animated: true)
    }

    func cancelPresentation() {
        workflowID = UUID()
        input?.dismiss(animated: false)
        picker?.dismiss(animated: false)
        if !isImporting { preview?.cancelWorkflowPresentation() }
        input = nil
        picker = nil
        if !isImporting { preview = nil }
        if !isImporting { onBusyChange(false) }
    }

    private func prepareFile(_ url: URL, id: UUID) {
        presentPreparingPreview(id: id) { [screen] in
            let selection = try await Task.detached(priority: .userInitiated) {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard let payload = String(data: data, encoding: .utf8) else {
                    throw NSError(
                        domain: "io.legado.kmp.ios", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: L10n.Errors.sourceFileReadFailed])
                }
                return ImportFileSelection(displayName: url.lastPathComponent, payload: payload)
            }.value
            try Task.checkCancellation()
            try screen.bootstrap().get()
            return try await screen.preparePreview(source: .file(selection))
        }
    }

    private func prepare(_ source: ImportSource, id: UUID) {
        presentPreparingPreview(id: id) { [screen] in
            try screen.bootstrap().get()
            return try await screen.preparePreview(source: source)
        }
    }

    private func presentPreparingPreview(id: UUID, prepare: @escaping () async throws -> SourceImportPreview) {
        guard workflowID == id, isHostAttached(), presenter?.presentedViewController == nil, preview == nil else { return }
        let controller = SourceImportPreviewViewController { [weak self] in
            guard let self, self.workflowID == id else { throw CancellationError() }
            self.onBusyChange(true)
            defer { if self.workflowID == id { self.onBusyChange(false) } }
            let value = try await prepare()
            try Task.checkCancellation()
            guard self.workflowID == id else { throw CancellationError() }
            return value
        }
        presentPreview(controller, id: id)
    }

    private func presentPreview(_ value: SourceImportPreview, id: UUID) {
        presentPreview(SourceImportPreviewViewController(preview: value), id: id)
    }

    private func presentPreview(_ controller: SourceImportPreviewViewController, id: UUID) {
        guard workflowID == id, isHostAttached(), let presenter,
            presenter.presentedViewController == nil, preview == nil
        else { return }
        preview = controller
        result = nil
        controller.overrideUserInterfaceStyle = presenter.traitCollection.userInterfaceStyle
        controller.onConfirm = { [weak self] sources, options in
            guard let self, self.workflowID == id, self.isHostAttached(), !self.isImporting else {
                throw CancellationError()
            }
            self.isImporting = true
            self.onBusyChange(true)
            defer {
                self.isImporting = false
                self.onBusyChange(false)
            }
            // A completed import remains committed if presentation changes during the await.
            self.result = try await self.screen.importSelected(sources: sources, options: options)
        }
        controller.onImported = { [weak self] in
            guard let self, self.workflowID == id else { return }
            self.preview = nil
            self.onImported()
            if self.isHostAttached(), let result = self.result {
                presenter.showTransientMessage("导入完成：新增 \(result.addedCount)，更新 \(result.updatedCount)")
            }
            self.result = nil
        }
        controller.onCancel = { [weak self] in
            guard let self, self.workflowID == id else { return }
            self.preview = nil
            self.result = nil
            self.onBusyChange(false)
        }
        presenter.present(controller, animated: true)
    }

    private func afterDismissing(_ controller: UIViewController, completion: @escaping @MainActor @Sendable () -> Void) {
        picker = nil
        if controller.isBeingDismissed, let transition = controller.transitionCoordinator {
            let registered = transition.animate(alongsideTransition: nil) { context in if !context.isCancelled { completion() } }
            if !registered { DispatchQueue.main.async(execute: completion) }
        } else if controller.presentingViewController != nil {
            controller.dismiss(animated: true, completion: completion)
        } else {
            DispatchQueue.main.async(execute: completion)
        }
    }

    private func canStart() -> Bool {
        canPresent() && isHostAttached() && presenter?.presentedViewController == nil
            && preview == nil && !isImporting
    }

    private func isHostAttached() -> Bool {
        guard let presenter, !presenter.isMovingFromParent, !presenter.isBeingDismissed,
            UIApplication.shared.applicationState == .active,
            presenter.navigationController?.topViewController === presenter,
            presenter.viewIfLoaded?.window?.isKeyWindow == true,
            presenter.viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive
        else { return false }
        return true
    }
}
