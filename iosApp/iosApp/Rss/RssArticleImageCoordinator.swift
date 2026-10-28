import Photos
import UIKit
import WebKit

@MainActor
final class RssArticleImageCoordinator: NSObject {
    private enum Destination {
        case photos, files, share
    }

    private struct Operation {
        let id = UUID()
        let url: URL
        let anchor: CGRect
        let loader = RssArticleImageLoader()
    }

    private enum Outcome {
        case selected(Destination)
        case loaded(RssArticleImageFile, Destination)
        case completed(String?)
        case failed(Error, Destination)
        case cancelled
    }

    private weak var owner: UIViewController?
    private let prepareResource: @MainActor (URL) async throws -> URLRequest
    private let canUseActions: @MainActor () -> Bool
    private var operation: Operation?
    private var task: Task<Void, Never>?
    private var visibilityTask: Task<Void, Never>?
    private var presentation: Presentation?
    private var hitTestID: UUID?

    var isBusy: Bool { operation != nil || hitTestID != nil }
    var ownsPresentation: Bool { presentation != nil }

    /// canUseActions must include the originating page generation, foreground scene and app-lock gate,
    /// but must NOT reject our own modal. Cancel on page replacement as well as actual departure.
    init(
        owner: UIViewController,
        prepareResource: @escaping @MainActor (URL) async throws -> URLRequest,
        canUseActions: @escaping @MainActor () -> Bool
    ) {
        self.owner = owner
        self.prepareResource = prepareResource
        self.canUseActions = canUseActions
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(sceneEnteredBackground(_:)), name: UIScene.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationEnteredBackground), name: UIApplication.didEnterBackgroundNotification,
            object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        operation?.loader.cancel()
        task?.cancel()
        visibilityTask?.cancel()
        let presentation = presentation
        Task { @MainActor in
            if presentation?.isSystemConsumer == false { presentation?.finish(.cancelled, animated: false) }
        }
    }

    func presentImage(at point: CGPoint, in webView: WKWebView, anchor: CGRect) {
        guard !isBusy, canUseActions(), ownerCanPresent else { return }
        let token = UUID()
        hitTestID = token
        let script = """
            (function() {
                var nodes = document.elementsFromPoint(\(point.x), \(point.y));
                var image = nodes.find(function(node) { return node.tagName === 'IMG'; });
                return image ? image.currentSrc || image.src : '';
            })()
            """
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            guard let self, self.hitTestID == token else { return }
            self.hitTestID = nil
            guard self.canUseActions(), let address = result as? String, !address.isEmpty,
                let url = URL(string: address)
            else { return }
            self.present(url: url, anchor: anchor)
        }
    }

    /// anchor is the hit image/press rectangle in owner.view coordinates (also used for iPad popovers).
    func present(url: URL, anchor: CGRect) {
        guard operation == nil, presentation == nil, canUseActions(), ownerCanPresent else { return }
        let captured = Operation(url: url, anchor: anchor)
        operation = captured
        watchVisibility(captured)
        let menu = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        let handle = makePresentation(menu, captured: captured)
        for (title, destination) in [("保存到相册", Destination.photos), ("保存到文件", .files), ("系统分享", .share)] {
            menu.addAction(
                UIAlertAction(title: title, style: .default) { [weak self, weak handle] _ in
                    guard let self, self.accepts(captured), let handle else { return }
                    handle.finish(.selected(destination))
                })
        }
        menu.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in self?.cancelIfCurrent(captured) })
        show(handle, captured: captured)
    }

    /// Invalidates late preparation/authorization and closes only our menu or busy UI.
    /// A handed-off Activity/Files panel is NOT dismissed: its terminal callback owns the lease.
    /// Safe to call from viewWillDisappear even when our own system panel caused the disappearance.
    func cancel() {
        hitTestID = nil
        operation?.loader.cancel()
        operation = nil
        task?.cancel()
        task = nil
        visibilityTask?.cancel()
        visibilityTask = nil
        if presentation?.isSystemConsumer == false { presentation?.finish(.cancelled, animated: false) }
    }

    @objc private func applicationEnteredBackground() { cancel() }

    @objc private func sceneEnteredBackground(_ notification: Notification) {
        guard let scene = notification.object as? UIScene,
            scene === owner?.viewIfLoaded?.window?.windowScene
                || scene === presentation?.controller.viewIfLoaded?.window?.windowScene
        else { return }
        cancel()
    }

    private func load(_ previous: Operation, destination: Destination) {
        guard accepts(previous), presentation == nil else { cancelIfCurrent(previous); return }
        // A retry owns a new transport and identity; a completed/cancelled URLSession is never reused.
        previous.loader.cancel()
        task?.cancel()
        visibilityTask?.cancel()
        let captured = Operation(url: previous.url, anchor: previous.anchor)
        operation = captured
        watchVisibility(captured)
        let busy = showBusy("正在获取图片", captured: captured)
        guard let busy else { cancelIfCurrent(captured); return }
        let prepare = prepareResource
        task = Task { @MainActor [weak self] in
            do {
                let request = try await prepare(captured.url)
                try Task.checkCancellation()
                guard self?.accepts(captured) == true else { self?.cancelIfCurrent(captured); return }
                let file = try await captured.loader.load(request, expectedURL: captured.url, prepareRedirect: prepare)
                try Task.checkCancellation()
                guard let self else { return }
                guard self.accepts(captured), self.presentation === busy else { self.cancelIfCurrent(captured); return }
                self.task = nil
                busy.finish(.loaded(file, destination))
            } catch {
                guard let self else { return }
                guard self.accepts(captured), self.presentation === busy else { self.cancelIfCurrent(captured); return }
                self.task = nil
                if error is CancellationError { self.cancel() } else { busy.finish(.failed(error, destination)) }
            }
        }
    }

    private func deliver(_ file: RssArticleImageFile, to destination: Destination, captured: Operation) {
        guard accepts(captured), presentation == nil, ownerCanPresent else { cancelIfCurrent(captured); return }
        switch destination {
        case .photos:
            saveToPhotos(file, captured: captured)
        case .files:
            // Export a COPY through Files. Delegate-returned URLs belong to the user, never to our lease.
            let picker = UIDocumentPickerViewController(forExporting: [file.url], asCopy: true)
            picker.allowsMultipleSelection = false
            picker.modalPresentationStyle = .formSheet
            let handle = makePresentation(picker, file: file, captured: captured)
            picker.delegate = handle
            show(handle, captured: captured)
        case .share:
            let share = UIActivityViewController(activityItems: [file.url], applicationActivities: nil)
            share.excludedActivityTypes = [.saveToCameraRoll]
            let handle = makePresentation(share, file: file, captured: captured)
            share.completionWithItemsHandler = { [weak handle] _, _, _, error in
                Task { @MainActor in
                    if let error { handle?.finish(.failed(error, .share)) } else { handle?.finish(.completed(nil)) }
                }
            }
            show(handle, captured: captured)
        }
    }

    private func saveToPhotos(_ file: RssArticleImageFile, captured: Operation) {
        guard let busy = showBusy("正在保存到相册", captured: captured) else { cancelIfCurrent(captured); return }
        task = Task { @MainActor [weak self] in
            do {
                var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
                if status == .notDetermined {
                    guard self?.accepts(captured) == true else { self?.cancelIfCurrent(captured); return }
                    status = await withCheckedContinuation { continuation in
                        PHPhotoLibrary.requestAuthorization(for: .addOnly) { continuation.resume(returning: $0) }
                    }
                }
                try Task.checkCancellation()
                // The system authorization sheet can report its result before the scene becomes active.
                for _ in 0..<30 {
                    if UIApplication.shared.applicationState == .active { break }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                guard let self else { return }
                guard self.accepts(captured), self.presentation === busy else { self.cancelIfCurrent(captured); return }
                guard status == .authorized || status == .limited else {
                    throw RssArticleImageLoader.failure("未获得添加照片权限；仍可通过“保存到文件”导出图片")
                }
                try await Self.addPhoto(file, loader: captured.loader)
                try Task.checkCancellation()
                guard self.accepts(captured), self.presentation === busy else { self.cancelIfCurrent(captured); return }
                self.task = nil
                busy.finish(.completed("图片已保存到相册"))
            } catch {
                guard let self else { return }
                guard self.accepts(captured), self.presentation === busy else { self.cancelIfCurrent(captured); return }
                self.task = nil
                if error is CancellationError { self.cancel() } else { busy.finish(.failed(error, .photos)) }
            }
        }
    }

    private static func addPhoto(_ file: RssArticleImageFile, loader: RssArticleImageLoader) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                guard !loader.isCancelled else { return }
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = file.url.lastPathComponent
                options.shouldMoveFile = false
                PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: file.url, options: options)
            } completionHandler: { success, error in
                // Photos can still be reading after the owner cancels or disappears.
                withExtendedLifetime(file) {
                    if loader.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if let error {
                        continuation.resume(throwing: error)
                    } else if success {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: RssArticleImageLoader.failure("保存图片失败，请重试"))
                    }
                }
            }
        }
    }

    private func showFailure(_ error: Error, destination: Destination, captured: Operation) {
        guard accepts(captured), presentation == nil, ownerCanPresent else { cancelIfCurrent(captured); return }
        let alert = UIAlertController(title: "图片处理失败", message: error.localizedDescription, preferredStyle: .alert)
        let handle = makePresentation(alert, captured: captured)
        alert.addAction(
            UIAlertAction(title: "重试", style: .default) { [weak self, weak handle] _ in
                guard let self, self.accepts(captured), let handle else { return }
                handle.finish(.selected(destination))
            })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in self?.cancelIfCurrent(captured) })
        show(handle, captured: captured)
    }

    private func showBusy(_ title: String, captured: Operation) -> Presentation? {
        guard accepts(captured), presentation == nil, ownerCanPresent else { return nil }
        let alert = UIAlertController(title: title, message: "\n\n", preferredStyle: .alert)
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        alert.view.addSubview(indicator)
        NSLayoutConstraint.activate([
            indicator.centerXAnchor.constraint(equalTo: alert.view.centerXAnchor),
            indicator.centerYAnchor.constraint(equalTo: alert.view.centerYAnchor, constant: -4),
        ])
        indicator.startAnimating()
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in self?.cancelIfCurrent(captured) })
        let handle = makePresentation(alert, captured: captured)
        show(handle, captured: captured)
        return presentation === handle ? handle : nil
    }

    private func makePresentation(
        _ controller: UIViewController, file: RssArticleImageFile? = nil, captured: Operation
    ) -> Presentation {
        let handle = Presentation(controller: controller, file: file)
        handle.onFinish = { [weak self, weak handle] outcome in
            guard let self, let handle, self.presentation === handle else { return }
            self.presentation = nil
            guard self.accepts(captured) else { self.cancelIfCurrent(captured); return }
            switch outcome {
            case let .selected(destination): self.load(captured, destination: destination)
            case let .loaded(file, destination): self.deliver(file, to: destination, captured: captured)
            case let .failed(error, destination): self.showFailure(error, destination: destination, captured: captured)
            case let .completed(message):
                self.complete(captured)
                if let message, self.canUseActions(), self.ownerCanPresent { self.owner?.showTransientMessage(message) }
            case .cancelled: self.cancelIfCurrent(captured)
            }
        }
        return handle
    }

    private func show(_ handle: Presentation, captured: Operation) {
        guard accepts(captured), presentation == nil, ownerCanPresent, let owner else {
            cancelIfCurrent(captured)
            return
        }
        let controller = handle.controller
        if let popover = controller.popoverPresentationController {
            let bounds = owner.view.bounds
            let requested = captured.anchor
            let finite = [requested.origin.x, requested.origin.y, requested.width, requested.height].allSatisfy { $0.isFinite }
            let clipped = finite ? requested.standardized.intersection(bounds) : .null
            popover.sourceView = owner.view
            popover.sourceRect =
                clipped.isNull || clipped.isEmpty
                ? CGRect(x: bounds.midX, y: bounds.midY, width: 1, height: 1) : clipped
        }
        presentation = handle
        handle.handoff()
        if handle.observesDismissal { controller.presentationController?.delegate = handle }
        owner.present(controller, animated: true) { [weak self, weak handle] in
            guard let self, let handle, self.presentation === handle else { return }
            guard self.accepts(captured), controller.presentingViewController != nil else {
                self.cancelIfCurrent(captured); return
            }
            if handle.observesDismissal { controller.presentationController?.delegate = handle }
        }
    }

    private var ownerCanPresent: Bool {
        guard let owner, owner.viewIfLoaded?.window != nil, owner.presentedViewController == nil,
            !owner.isBeingPresented, !owner.isBeingDismissed, !owner.isMovingFromParent
        else { return false }
        return true
    }

    private func accepts(_ captured: Operation) -> Bool {
        guard operation?.id == captured.id, !captured.loader.isCancelled, canUseActions(), let owner,
            !owner.isBeingDismissed, !owner.isMovingFromParent,
            UIApplication.shared.applicationState == .active
        else { return false }
        var current: UIViewController? = owner
        while let controller = current {
            if controller.isBeingDismissed || controller.isMovingFromParent { return false }
            if let navigation = controller.parent as? UINavigationController, navigation.topViewController !== controller {
                return false
            }
            if let tabs = controller.parent as? UITabBarController, tabs.selectedViewController !== controller { return false }
            current = controller.parent
        }
        if let modal = owner.presentedViewController, modal !== presentation?.controller { return false }
        return owner.viewIfLoaded?.window != nil || presentation?.controller.presentingViewController != nil
    }

    private func cancelIfCurrent(_ captured: Operation) {
        if operation?.id == captured.id { cancel() }
    }

    private func complete(_ captured: Operation) {
        guard operation?.id == captured.id else { return }
        operation = nil
        task = nil
        visibilityTask?.cancel()
        visibilityTask = nil
    }

    private func watchVisibility(_ captured: Operation) {
        visibilityTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
                guard let self, self.operation?.id == captured.id else { return }
                guard self.owner != nil else { self.cancel(); return }
                // Do not mistake our Photos authorization sheet or a system consumer for leaving the page.
                // Actual backgrounding is handled synchronously by notifications above.
                if UIApplication.shared.applicationState == .active, !self.accepts(captured) {
                    self.cancel()
                    return
                }
            }
        }
    }

    /// The terminal task retains both the controller and the file independently of the coordinator.
    @MainActor
    private final class Presentation: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
        let controller: UIViewController
        private let file: RssArticleImageFile?
        var onFinish: ((Outcome) -> Void)?
        private var ending = false
        private var consumerRetention: Presentation?

        var isSystemConsumer: Bool {
            controller is UIDocumentPickerViewController || controller is UIActivityViewController
        }

        var observesDismissal: Bool {
            // UIKit owns alert-style presentation delegates and asserts if an app changes them.
            (controller as? UIAlertController)?.preferredStyle != .alert
        }

        init(controller: UIViewController, file: RssArticleImageFile?) {
            self.controller = controller
            self.file = file
            super.init()
        }

        func handoff() {
            // UIDocumentPicker's delegate is weak. Keep the lease alive independently of owner/VC
            // lifetime until the provider has actually finished exporting, not merely disappeared.
            if isSystemConsumer { consumerRetention = self }
        }

        func finish(_ outcome: Outcome, animated: Bool = true) {
            guard !ending else { return }
            ending = true
            Task { @MainActor [self] in
                await dismiss(animated: animated)
                let callback = onFinish
                onFinish = nil
                (controller as? UIDocumentPickerViewController)?.delegate = nil
                (controller as? UIActivityViewController)?.completionWithItemsHandler = nil
                if observesDismissal { controller.presentationController?.delegate = nil }
                callback?(outcome)
                withExtendedLifetime(file) {}
                consumerRetention = nil
            }
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard self.controller === controller else { return }
            finish(urls.isEmpty ? .cancelled : .completed("图片已导出到文件"))
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            guard self.controller === controller else { return }
            finish(.cancelled)
        }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            guard presentationController.presentedViewController === controller else { return }
            // An activity extension can outlive the share sheet's visible presentation.
            if controller is UIActivityViewController { return }
            finish(.cancelled, animated: false)
        }

        private func dismiss(animated: Bool) async {
            // UIKit callbacks can arrive during either half of a transition. Never dismiss a successor,
            // and never unlink a leased file just because presentedViewController became nil early.
            while true {
                if controller.isBeingPresented || controller.isBeingDismissed, let transition = controller.transitionCoordinator {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        let registered = transition.animate(alongsideTransition: nil) { _ in continuation.resume() }
                        if !registered { continuation.resume() }
                    }
                }
                if let presenter = controller.presentingViewController, presenter.presentedViewController === controller,
                    !controller.isBeingPresented, !controller.isBeingDismissed
                {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        controller.dismiss(animated: animated) { continuation.resume() }
                    }
                }
                if controller.presentingViewController == nil, controller.viewIfLoaded?.window == nil { return }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }
}
