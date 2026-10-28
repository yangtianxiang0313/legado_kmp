import UIKit
import UniformTypeIdentifiers

@MainActor
final class ReaderImageExportCoordinator: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
    private enum Storage {
        static let folderBookmarkKey = "io.legado.reader.image-export.folder-bookmark.v1"
    }

    private weak var presenter: UIViewController?
    private let onMessage: (String) -> Void
    private let defaults = UserDefaults.standard
    private var request: ReaderImageExportRequest?
    private var pendingImage: ReaderImageExportFiles.Image?
    private var picker: UIDocumentPickerViewController?
    private var dismissingPicker: UIDocumentPickerViewController?
    private var task: Task<Void, Never>?
    private var visibilityTask: Task<Void, Never>?

    var ownsPresentation: Bool { picker != nil || dismissingPicker != nil }

    init(presenter: UIViewController, onMessage: @escaping (String) -> Void) {
        self.presenter = presenter
        self.onMessage = onMessage
        super.init()
    }

    deinit {
        request?.cancel()
        task?.cancel()
        visibilityTask?.cancel()
        if let picker {
            Task { @MainActor in picker.dismiss(animated: false) }
        }
    }

    /// Keep the shared image bytes intact. The source URL contributes only a sanitized filename stem.
    func save(imageData: Data, sourceURL: URL) {
        guard let request = beginRequest() else { return }
        let bookmark = defaults.data(forKey: Storage.folderBookmarkKey)
        task = Task { @MainActor [weak self] in
            do {
                let image = try await ReaderImageExportFiles.prepare(data: imageData, sourceURL: sourceURL, request: request)
                let folder = try await ReaderImageExportFiles.resolve(bookmark: bookmark, request: request)
                guard let self, self.canDeliver(request) else { return }
                self.task = nil
                if let folder {
                    self.defaults.set(folder.bookmark, forKey: Storage.folderBookmarkKey)
                    self.write(image, folder: folder.url, request: request)
                } else {
                    if bookmark != nil { self.defaults.removeObject(forKey: Storage.folderBookmarkKey) }
                    self.pendingImage = image
                    self.presentFolderPicker(request: request)
                }
            } catch {
                self?.fail(error, request: request)
            }
        }
    }

    /// Select and persist a Files directory without saving any image.
    func selectFolder() {
        guard let request = beginRequest() else { return }
        presentFolderPicker(request: request)
    }

    /// Call when leaving the reader or invalidating an upstream shared-image request, not for this picker's presentation.
    func suspend() {
        request?.cancel()
        request = nil
        pendingImage = nil
        task?.cancel()
        task = nil
        visibilityTask?.cancel()
        visibilityTask = nil
        if let picker { dismissOwnedPicker(picker, animated: false) {} }
    }

    private func beginRequest() -> ReaderImageExportRequest? {
        // Ignore reentrant taps while preparing, picking, dismissing or writing; never stack Files pickers.
        guard request == nil, picker == nil, dismissingPicker == nil,
            presenterIsCurrent(allowOwnedPicker: false)
        else { return nil }
        let request = ReaderImageExportRequest()
        self.request = request
        watchVisibility(request: request)
        return request
    }

    private func presentFolderPicker(request: ReaderImageExportRequest) {
        guard canDeliver(request), let presenter, presenter.presentedViewController == nil,
            picker == nil, dismissingPicker == nil
        else {
            finish(request)
            return
        }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        picker.modalPresentationStyle = .formSheet
        self.picker = picker
        picker.presentationController?.delegate = self
        presenter.present(picker, animated: true) { [weak self, weak picker] in
            guard let self, let picker, self.picker === picker, self.canDeliver(request) else { return }
            picker.presentationController?.delegate = self
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard picker === controller, let request, canDeliver(request) else { return }
        let image = pendingImage
        pendingImage = nil
        dismissOwnedPicker(controller, animated: true) { [weak self] in
            guard let self, self.canDeliver(request) else { return }
            guard urls.count == 1, let folder = urls.first else {
                self.finish(request)
                return
            }
            self.remember(folder: folder, image: image, request: request)
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        guard picker === controller, let request else { return }
        request.cancel()
        pendingImage = nil
        dismissOwnedPicker(controller, animated: true) { [weak self] in self?.finish(request) }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard picker === presentationController.presentedViewController else { return }
        picker?.delegate = nil
        picker = nil
        guard let request else { return }
        request.cancel()
        finish(request)
    }

    private func remember(folder: URL, image: ReaderImageExportFiles.Image?, request: ReaderImageExportRequest) {
        task = Task { @MainActor [weak self] in
            do {
                let selected = try await ReaderImageExportFiles.remember(folder: folder, request: request)
                guard let self, self.canDeliver(request) else { return }
                self.task = nil
                self.defaults.set(selected.bookmark, forKey: Storage.folderBookmarkKey)
                if let image {
                    self.write(image, folder: selected.url, request: request)
                } else {
                    self.finish(request)
                    self.onMessage("已选择图片保存文件夹")
                }
            } catch {
                self?.fail(error, request: request, selectingFolder: image == nil)
            }
        }
    }

    private func write(_ image: ReaderImageExportFiles.Image, folder: URL, request: ReaderImageExportRequest) {
        task = Task { @MainActor [weak self] in
            do {
                _ = try await ReaderImageExportFiles.write(image, folder: folder, request: request)
                guard let self, self.canDeliver(request) else { return }
                self.finish(request)
                self.onMessage("图片已保存到所选文件夹")
            } catch {
                self?.fail(error, request: request)
            }
        }
    }

    private func dismissOwnedPicker(_ controller: UIDocumentPickerViewController, animated: Bool, completion: @escaping () -> Void) {
        guard picker === controller else { return }
        picker = nil
        dismissingPicker = controller
        controller.delegate = nil
        controller.presentationController?.delegate = nil
        let didDismiss = { [weak self, weak controller] in
            guard let self, let controller, self.dismissingPicker === controller else { return }
            self.dismissingPicker = nil
            completion()
        }
        if controller.presentingViewController != nil {
            finishDismissing(controller, animated: animated, completion: didDismiss)
        } else {
            if controller.isBeingDismissed, let transition = controller.transitionCoordinator,
                transition.animate(alongsideTransition: nil, completion: { _ in didDismiss() })
            {
                return
            }
            didDismiss()
        }
    }

    private func finishDismissing(_ controller: UIDocumentPickerViewController, animated: Bool, completion: @escaping () -> Void) {
        if controller.isBeingDismissed, let transition = controller.transitionCoordinator,
            transition.animate(alongsideTransition: nil, completion: { _ in completion() })
        {
            return
        }
        if controller.isBeingPresented, let transition = controller.transitionCoordinator,
            transition.animate(
                alongsideTransition: nil,
                completion: { [weak controller] _ in
                    guard let controller, controller.presentingViewController != nil else {
                        completion()
                        return
                    }
                    controller.dismiss(animated: animated, completion: completion)
                })
        {
            return
        }
        controller.dismiss(animated: animated, completion: completion)
    }

    private func canDeliver(_ request: ReaderImageExportRequest) -> Bool {
        guard self.request === request, !request.isCancelled else { return false }
        guard presenterIsCurrent(allowOwnedPicker: true) else {
            suspend()
            return false
        }
        return true
    }

    private func finish(_ request: ReaderImageExportRequest) {
        guard self.request === request else { return }
        self.request = nil
        pendingImage = nil
        task = nil
        visibilityTask?.cancel()
        visibilityTask = nil
    }

    private func fail(_ error: Error, request: ReaderImageExportRequest, selectingFolder: Bool = false) {
        guard canDeliver(request) else { return }
        finish(request)
        guard !(error is CancellationError) else { return }
        let message = selectingFolder ? "选择图片保存文件夹失败" : "保存图片失败"
        onMessage("\(message)：\(error.localizedDescription)")
    }

    private func presenterIsCurrent(allowOwnedPicker: Bool) -> Bool {
        guard let presenter, presenter.isViewLoaded else { return false }
        let owned = picker ?? dismissingPicker
        var current: UIViewController? = presenter
        while let controller = current {
            if controller.isBeingDismissed || controller.isMovingFromParent { return false }
            if let navigation = controller.parent as? UINavigationController,
                navigation.topViewController !== controller
            {
                return false
            }
            if let tabs = controller.parent as? UITabBarController, tabs.selectedViewController !== controller {
                return false
            }
            if let presented = controller.presentedViewController,
                !(allowOwnedPicker && presented === owned)
            {
                return false
            }
            current = controller.parent
        }
        return presenter.viewIfLoaded?.window != nil
            || (allowOwnedPicker && owned?.presentingViewController != nil)
    }

    private func watchVisibility(request: ReaderImageExportRequest) {
        visibilityTask = Task { @MainActor [weak self, weak request] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 150_000_000)
                } catch { return }
                guard let self, let request, self.request === request else { return }
                if !self.presenterIsCurrent(allowOwnedPicker: true) {
                    self.suspend()
                    return
                }
            }
        }
    }
}
