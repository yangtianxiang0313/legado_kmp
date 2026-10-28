import UIKit
import UniformTypeIdentifiers
import shared

@MainActor
final class ReaderPresetTransferCoordinator: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
    private struct Operation {
        let id = UUID()
        let expectedName: String
        let expectedIndex: Int32
        let queue: ReaderBackgroundTextWriteQueue
    }

    private weak var owner: AndroidReaderBackgroundTextSheetViewController?
    private var operation: Operation?
    private var commandID: UUID?
    private var commandTask: Task<Void, Never>?
    private var picker: UIDocumentPickerViewController?
    private var importMenu: ReaderBookChoiceDialogViewController?
    private var input: ReaderConfigURLDialogViewController?
    private var activity: UIActivityViewController?
    private var exportFile: ReaderPresetTransferTemporaryFile?
    private var download: ReaderPresetTransferDownload?
    private var pickerHandled = false
    private var activityHandled = false
    private var activityError: Error?

    init(owner: AndroidReaderBackgroundTextSheetViewController) {
        self.owner = owner
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(sceneDeactivated(_:)), name: UIScene.didEnterBackgroundNotification, object: nil)
    }

    func deactivate() {
        operation = nil
        commandTask?.cancel()
        download?.cancel()
        download = nil

        let menu = importMenu
        let picker = picker
        let input = input
        let activity = activity
        let file = exportFile
        menu?.onClose = nil
        picker?.delegate = nil
        picker?.presentationController?.delegate = nil
        input?.onDismiss = nil
        input?.canSubmit = { false }
        activity?.completionWithItemsHandler = nil
        activity?.presentationController?.delegate = nil
        importMenu = nil
        self.picker = nil
        self.input = nil
        self.activity = nil
        exportFile = nil
        pickerHandled = true
        activityHandled = true
        activityError = nil
        let controllers: [UIViewController?] = [menu, picker, input, activity]
        Task { @MainActor in
            for controller in controllers.compactMap({ $0 }) {
                _ = await Self.dismiss(controller, animated: false)
            }
            file?.remove()
        }
    }

    @objc private func sceneDeactivated(_ notification: Notification) {
        guard let scene = notification.object as? UIScene,
            scene === owner?.viewIfLoaded?.window?.windowScene
        else { return }
        deactivate()
    }

    func presentImportOptions(anchor _: UIView) {
        guard canBegin, let owner else { return }
        let captured = reserve(owner)
        let menu = ReaderBookChoiceDialogViewController(
            title: "导入",
            choices: [
                .init(title: "本地导入", accessibilityValue: "local"),
                .init(title: "网络导入", accessibilityValue: "network"),
            ],
            identifierPrefix: "reader.presetImport",
            onClose: { [weak self] in
                guard let self, self.operation?.id == captured.id, self.importMenu != nil else { return }
                self.importMenu = nil
                self.release(captured)
            },
            onSelect: { [weak self] index in
                guard let self, self.operation?.id == captured.id, self.importMenu != nil else { return }
                // ReaderBookChoice delivers selection only after the menu has detached.
                self.importMenu = nil
                guard self.isCurrent(captured), self.owner?.presentedViewController == nil else {
                    self.release(captured)
                    return
                }
                if index == 0 { self.selectFile(captured) } else { self.enterURL(captured) }
            })
        menu.overrideUserInterfaceStyle = owner.traitCollection.userInterfaceStyle
        importMenu = menu
        if !present(menu, for: captured) {
            menu.onClose = nil
            importMenu = nil
            release(captured)
        }
    }

    func export(anchor: UIView) {
        guard canBegin, let owner else { return }
        let captured = reserve(owner)
        runCommand(captured, exporting: true) { [self, weak anchor] in
            guard isCurrent(captured) else { return }
            let latest = try await ReaderAppearanceSnapshotRequest.read(facade: owner.facade).preferences
            guard isCurrent(captured), latest.readerPresetIndex == captured.expectedIndex,
                latest.readerPresetName == captured.expectedName
            else { return }
            // The legacy exporter prefers the selected slot, including duplicate names.
            guard let json = try owner.facade.exportAndroidReaderPresetJson(name: captured.expectedName) else {
                throw ReaderPresetTransferResources.error("找不到当前阅读配置")
            }
            let file = try await ReaderPresetTransferFiles.makeExport(json)
            var leased = false
            defer { if !leased { file.remove() } }
            guard isCurrent(captured), owner.presentedViewController == nil, let anchor,
                anchor.window === owner.viewIfLoaded?.window
            else { return }
            let share = UIActivityViewController(activityItems: [file.url], applicationActivities: nil)
            share.popoverPresentationController?.sourceView = anchor
            share.popoverPresentationController?.sourceRect = anchor.bounds
            share.completionWithItemsHandler = { [weak self, weak share, file] _, _, _, error in
                file.remove()
                Task { @MainActor in
                    guard let self, let share else { return }
                    self.finishSharing(share, captured: captured, error: error)
                }
            }
            activityHandled = false
            activityError = nil
            activity = share
            exportFile = file
            guard present(share, for: captured) else {
                share.completionWithItemsHandler = nil
                activity = nil
                exportFile = nil
                if isCurrent(captured) { throw ReaderPresetTransferResources.error("无法显示导出面板") }
                return
            }
            share.presentationController?.delegate = self
            leased = true
        }
    }

    private var canBegin: Bool {
        guard let owner, owner.canPresentBackgroundAction, !owner.isPerformingCommand,
            !owner.visualBinding.isSwitching, owner.presentedViewController == nil,
            operation == nil, commandID == nil, importMenu == nil, picker == nil, input == nil, activity == nil
        else { return false }
        return true
    }

    private func reserve(_ owner: AndroidReaderBackgroundTextSheetViewController) -> Operation {
        let captured = Operation(
            expectedName: owner.presetName, expectedIndex: owner.presetIndex, queue: owner.visualBinding.queue)
        operation = captured
        return captured
    }

    private func isCurrent(_ captured: Operation) -> Bool {
        guard operation?.id == captured.id, let owner, owner.canPresentBackgroundAction,
            !owner.visualBinding.isSwitching, owner.presetIndex == captured.expectedIndex,
            owner.presetName == captured.expectedName, owner.visualBinding.queue === captured.queue
        else { return false }
        return true
    }

    private func release(_ captured: Operation) {
        if operation?.id == captured.id { operation = nil }
    }

    private func present(_ controller: UIViewController, for captured: Operation) -> Bool {
        guard isCurrent(captured), let owner, owner.presentedViewController == nil else { return false }
        owner.present(controller, animated: true) { [weak self, weak controller] in
            guard let self, let controller, self.operation?.id == captured.id else { return }
            if !self.isCurrent(captured) || controller.presentingViewController == nil { self.deactivate() }
        }
        // UIKit may queue this behind a system picker's final dismissal after presentedViewController
        // has become nil. Retain the operation and file lease until the real completion above.
        return true
    }

    private func runCommand(
        _ captured: Operation, exporting: Bool, action: @escaping () async throws -> Void
    ) {
        guard isCurrent(captured), let owner, !owner.isPerformingCommand else {
            release(captured)
            return
        }
        owner.body.setTransferBusy(true, exporting: exporting)
        owner.runCommand(action)
        guard let task = owner.commandTask else {
            owner.body.setTransferBusy(false, exporting: exporting)
            release(captured)
            return
        }
        commandID = captured.id
        commandTask = task
        Task { @MainActor [self] in
            // Also release the reservation when the owner's pre-command flush fails.
            await task.value
            guard commandID == captured.id else { return }
            commandID = nil
            commandTask = nil
            download = nil
            owner.body.setTransferBusy(false, exporting: exporting)
            if activity == nil { release(captured) }
        }
    }

    private func selectFile(_ captured: Operation) {
        guard isCurrent(captured) else {
            release(captured)
            return
        }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.zip, .json, .plainText], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        pickerHandled = false
        self.picker = picker
        if present(picker, for: captured) {
            picker.presentationController?.delegate = self
        } else {
            picker.delegate = nil
            self.picker = nil
            release(captured)
        }
    }

    private func enterURL(_ captured: Operation) {
        guard isCurrent(captured), let owner else {
            release(captured)
            return
        }
        let dialog = ReaderConfigURLDialogViewController { [weak self] text in
            guard let self else { return }
            self.importConfig(captured, address: text)
        }
        dialog.canSubmit = { [weak self] in self?.isCurrent(captured) == true }
        dialog.onDismiss = { [weak self] in
            guard let self, self.operation?.id == captured.id else { return }
            self.input = nil
            // onDismiss precedes onSubmit; leave the identity gate alive until both return.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.commandID != captured.id else { return }
                self.release(captured)
            }
        }
        dialog.overrideUserInterfaceStyle = owner.traitCollection.userInterfaceStyle
        input = dialog
        if !present(dialog, for: captured) {
            dialog.onDismiss = nil
            dialog.canSubmit = { false }
            input = nil
            release(captured)
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        finishPicking(controller, url: urls.first)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finishPicking(controller, url: nil)
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        if let picker, presentationController.presentedViewController === picker {
            finishPicking(picker, url: nil)
        } else if let activity, presentationController.presentedViewController === activity, let captured = operation {
            finishSharing(activity, captured: captured)
        }
    }

    private func finishPicking(_ controller: UIDocumentPickerViewController, url: URL?) {
        guard picker === controller, !pickerHandled, let captured = operation else { return }
        pickerHandled = true
        Task { @MainActor [self] in
            let detached = await Self.dismiss(controller)
            guard picker === controller else { return }
            controller.delegate = nil
            controller.presentationController?.delegate = nil
            picker = nil
            guard detached, isCurrent(captured), let url else {
                release(captured)
                return
            }
            importConfig(captured, file: url)
        }
    }

    private func finishSharing(_ controller: UIActivityViewController, captured: Operation, error: Error? = nil) {
        guard activity === controller else { return }
        if let error { activityError = error }
        guard !activityHandled else { return }
        activityHandled = true
        Task { @MainActor [self] in
            let detached = await Self.dismiss(controller)
            guard activity === controller else { return }
            controller.completionWithItemsHandler = nil
            controller.presentationController?.delegate = nil
            activity = nil
            exportFile?.remove()
            exportFile = nil
            let mayReport = detached && isCurrent(captured)
            let error = activityError
            activityError = nil
            release(captured)
            if mayReport, let error { owner?.showActionError(error) }
        }
    }

    private func importConfig(_ captured: Operation, file: URL? = nil, address: String? = nil) {
        guard isCurrent(captured), let owner, owner.presentedViewController == nil else {
            release(captured)
            return
        }
        runCommand(captured, exporting: false) { [self] in
            guard isCurrent(captured) else { return }
            let data: Data
            if let file {
                data = try await ReaderPresetTransferFiles.read(file)
            } else {
                let value = address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard let url = URL(string: value) else {
                    throw ReaderPresetTransferResources.error("请输入有效的 HTTP 或 HTTPS 地址")
                }
                let request = ReaderPresetTransferDownload()
                download = request
                data = try await request.load(url)
            }
            guard isCurrent(captured) else { return }
            let prepared = try await ReaderPresetTransferFiles.prepare(data)
            do {
                try Task.checkCancellation()
                guard isCurrent(captured) else { throw CancellationError() }
                let _: ReaderPreset = try await SharedAsync.value {
                    owner.facade.replaceAndroidReaderPreset(
                        expectedName: captured.expectedName, jsonString: prepared.json,
                        expectedIndex: KotlinInt(int: captured.expectedIndex), completionHandler: $0)
                }
                // Once the shared write starts, settle its real result before releasing resources.
                prepared.commitResources()
            } catch {
                throw prepared.discardResources(after: error)
            }
        }
    }

    private static func dismiss(_ controller: UIViewController, animated: Bool = true) async -> Bool {
        if controller.isBeingPresented || controller.isBeingDismissed, let transition = controller.transitionCoordinator {
            await withCheckedContinuation { continuation in
                let registered = transition.animate(alongsideTransition: nil) { _ in continuation.resume() }
                if !registered { continuation.resume() }
            }
        }
        // Never ask the owner (or an unrelated presenter) to dismiss its current modal.
        if let presenter = controller.presentingViewController, presenter.presentedViewController === controller,
            !controller.isBeingPresented, !controller.isBeingDismissed
        {
            await withCheckedContinuation { continuation in
                controller.dismiss(animated: animated) { continuation.resume() }
            }
        }
        return controller.presentingViewController == nil && controller.viewIfLoaded?.window == nil
    }
}
