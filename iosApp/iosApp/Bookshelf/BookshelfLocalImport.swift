import UIKit
import UniformTypeIdentifiers
import shared

enum BookshelfLocalImportText {
    static let title = "导入本地书籍"
    static let preparing = "正在准备文件…"
    static let importing = "正在解析并加入书架…"
    static let cancelling = "正在取消，等待当前操作结束…"
    static let cancelled = "已取消导入"
    static let unsupported = LocalBookFormats.unsupportedMessage
    static let cancel = "取消"

    static func success(_ name: String) -> String {
        "已导入《\(name)》"
    }
}
@MainActor
final class BookshelfLocalImport: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
    private weak var presenter: AndroidReplicaBookshelfViewController?
    private let screen: BookshelfScreenAdapter
    private var picker: UIDocumentPickerViewController?
    private var coordinator: LocalBookImportCoordinator?
    private var directoryCoordinator: LocalBookDirectoryImportCoordinator?
    private var request: LocalBookImportOwnership?
    private var menu: UIAlertController?
    private var pickingDirectory = false
    private var importGroupID: Int64 = 0
    private var transitionTask: Task<Void, Never>?
    private var completionTask: Task<Void, Never>?
    private var consumedMenu = false
    private var consumedPicker = false
    private var pendingSummary: LocalBookImportSummary?
    private var deliveryScopes: [SandboxFileReadLease] = []

    init(presenter: AndroidReplicaBookshelfViewController, screen: BookshelfScreenAdapter) {
        self.presenter = presenter
        self.screen = screen
        super.init()
    }

    deinit {
        transitionTask?.cancel()
        completionTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    func start() {
        guard request == nil, transitionTask == nil, completionTask == nil,
            picker == nil, coordinator == nil, directoryCoordinator == nil,
            let presenter, let request = LocalBookImportOwnership(owner: presenter)
        else { return }
        self.request = request
        let id = request.id
        consumedMenu = false
        consumedPicker = false
        pendingSummary = nil
        request.onCheck = { [weak self] in self?.checkPendingPresentation(id) }
        request.observe { [weak self] in self?.invalidate(id) }
        for name in [UIApplication.willResignActiveNotification, UIScene.willDeactivateNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(menuEnvironmentChanged(_:)), name: name, object: nil)
        }
        let menu = UIAlertController(title: BookshelfLocalImportText.title, message: nil, preferredStyle: .actionSheet)
        self.menu = menu
        request.bind(menu)
        menu.addAction(
            UIAlertAction(title: "选择文件", style: .default) { [weak self, weak menu] _ in
                self?.afterMenu(menu, id: id) { [weak self] in self?.chooseFiles(directory: false, id: id) }
            })
        menu.addAction(
            UIAlertAction(title: "扫描文件夹", style: .default) { [weak self, weak menu] _ in
                self?.afterMenu(menu, id: id) { [weak self] in self?.chooseFiles(directory: true, id: id) }
            })
        menu.addAction(
            UIAlertAction(title: "导入文件名规则", style: .default) { [weak self, weak menu] _ in
                self?.afterMenu(menu, id: id) { [weak self] in
                    guard let self, self.request?.id == id, self.request?.canPresent == true,
                        let presenter = self.presenter
                    else { return }
                    let navigation = UINavigationController(rootViewController: LocalBookFileNameRuleViewController())
                    navigation.modalPresentationStyle = .formSheet
                    self.finish(id)
                    presenter.present(navigation, animated: !UIAccessibility.isReduceMotionEnabled)
                }
            })
        menu.addAction(
            UIAlertAction(title: BookshelfLocalImportText.cancel, style: .cancel) { [weak self, weak menu] _ in
                self?.afterMenu(menu, id: id) { [weak self] in self?.finish(id) }
            })
        menu.popoverPresentationController?.sourceView = presenter.view
        menu.popoverPresentationController?.sourceRect = CGRect(
            x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
        present(menu, from: presenter, request: request)
    }

    private func afterMenu(_ menu: UIViewController?, id: UUID, action: @escaping @MainActor () -> Void) {
        guard let request, request.id == id, let menu, self.menu === menu,
            !consumedMenu, transitionTask == nil
        else { return }
        guard request.canUse(menu, allowingDismissal: true) else {
            request.invalidate()
            return
        }
        consumedMenu = true
        transitionTask = Task { @MainActor [self] in
            await LocalBookImportOwnership.dismiss(menu)
            self.menu = nil
            request.bind(nil)
            transitionTask = nil
            guard self.request?.id == id, !Task.isCancelled, request.canPresent else {
                finish(id)
                return
            }
            action()
        }
    }

    private func chooseFiles(directory: Bool, id: UUID) {
        guard let presenter, let request, request.id == id, request.canPresent,
            picker == nil, coordinator == nil, directoryCoordinator == nil
        else {
            finish(id)
            return
        }
        pickingDirectory = directory
        importGroupID = screen.currentSelectedGroupId
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: directory ? [.folder] : LocalBookFormats.pickerTypes, asCopy: !directory)
        picker.allowsMultipleSelection = !directory
        picker.delegate = self
        self.picker = picker
        request.bind(picker)
        present(picker, from: presenter, request: request)
    }

    private func present(_ controller: UIViewController, from presenter: UIViewController, request: LocalBookImportOwnership) {
        let id = request.id
        transitionTask = Task { @MainActor [self] in
            do {
                try Task.checkCancellation()
                guard self.request?.id == id, request.canPresent else { throw CancellationError() }
                await withCheckedContinuation { continuation in
                    presenter.present(controller, animated: !UIAccessibility.isReduceMotionEnabled) {
                        continuation.resume()
                    }
                    if controller === picker { controller.presentationController?.delegate = self }
                }
                try Task.checkCancellation()
                try request.acknowledgePresentation(controller)
                guard self.request?.id == id else { throw CancellationError() }
                if controller === picker { controller.presentationController?.delegate = self }
                transitionTask = nil
            } catch {
                await LocalBookImportOwnership.dismiss(controller)
                guard self.request?.id == id else { return }
                if controller === picker { picker = nil }
                if controller === menu { menu = nil }
                transitionTask = nil
                finish(id)
            }
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        finishPicking(controller, urls: urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finishPicking(controller, urls: [])
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard request != nil else { return }
        if let picker, presentationController.presentedViewController === picker {
            finishPicking(picker, urls: [])
        }
    }

    private func finishPicking(_ controller: UIDocumentPickerViewController, urls: [URL]) {
        guard picker === controller, let request, !consumedPicker, transitionTask == nil else { return }
        let id = request.id
        consumedPicker = true
        // Identity, not temporary activation/key status, decides whether a provider delivery belongs here.
        guard request.canUse(controller, allowingDismissal: true, requiringActivation: false)
        else {
            request.invalidate()
            invalidate(id)
            return
        }
        deliveryScopes = urls.map(SandboxFileReadLease.init)
        let directory = pickingDirectory
        let groupID = importGroupID
        transitionTask = Task { @MainActor [self] in
            await LocalBookImportOwnership.dismiss(controller)
            picker = nil
            request.bind(nil)
            if urls.isEmpty {
                releaseDeliveryScopes()
                transitionTask = nil
                if request.canPresent { presenter?.showMessage(BookshelfLocalImportText.cancelled) }
                finish(id)
                return
            }
            do {
                try await request.waitUntilReady()
                guard self.request?.id == id, request.canPresent, let presenter else { throw CancellationError() }
                if directory, let root = urls.first {
                    let coordinator = LocalBookDirectoryImportCoordinator(presenter: presenter)
                    coordinator.onBatchCompleted = { [weak self] summary in self?.receive(summary, id: id) }
                    coordinator.onFinished = { [weak self, weak coordinator] in
                        guard let self, self.request?.id == id, self.directoryCoordinator === coordinator else { return }
                        let summary = coordinator?.completedSummary ?? self.pendingSummary
                        let canDeliver = coordinator?.canDeliverResult == true
                        self.directoryCoordinator = nil
                        if !canDeliver { self.request?.invalidate() }
                        self.importDidFinish(summary, id: id)
                    }
                    directoryCoordinator = coordinator
                    // No suspension between the original-owner check and the child's own snapshot/leases.
                    guard request.canPresent else {
                        directoryCoordinator = nil
                        throw CancellationError()
                    }
                    request.stopObserving()
                    coordinator.start(root: root, groupID: groupID)
                } else {
                    let coordinator = LocalBookImportCoordinator(presenter: presenter) { _ in }
                    coordinator.onBatchCompleted = { [weak self] summary in self?.receive(summary, id: id) }
                    coordinator.onFinished = { [weak self, weak coordinator] in
                        guard let self, self.request?.id == id, self.coordinator === coordinator else { return }
                        let summary = coordinator?.completedSummary ?? self.pendingSummary
                        let canDeliver = coordinator?.canDeliverResult == true
                        self.coordinator = nil
                        if !canDeliver { self.request?.invalidate() }
                        self.importDidFinish(summary, id: id)
                    }
                    self.coordinator = coordinator
                    guard request.canPresent else {
                        self.coordinator = nil
                        throw CancellationError()
                    }
                    request.stopObserving()
                    coordinator.start(urls: urls, groupID: groupID)
                }
                // start synchronously takes its own incoming/root leases before this handoff ends.
                releaseDeliveryScopes()
                transitionTask = nil
                if coordinator == nil, directoryCoordinator == nil, completionTask == nil { finish(id) }
            } catch {
                releaseDeliveryScopes()
                transitionTask = nil
                finish(id)
            }
        }
    }

    private func receive(_ summary: LocalBookImportSummary, id: UUID) {
        guard request?.id == id, pendingSummary == nil else { return }
        pendingSummary = summary
    }

    private func importDidFinish(_ summary: LocalBookImportSummary?, id: UUID) {
        guard request?.id == id, completionTask == nil else { return }
        guard let summary, request?.canPresent == true else {
            finish(id)
            return
        }
        request?.observe { [weak self] in self?.invalidate(id) }
        completionTask = Task { @MainActor [self, screen] in
            defer {
                completionTask = nil
                finish(id)
            }
            guard let request, request.id == id, request.canPresent else { return }
            do {
                let books = try await screen.reloadBooks()
                guard !Task.isCancelled, self.request?.id == id, request.canPresent else { return }
                if let imported = summary.books.first {
                    presenter?.applyLocalBookImport(imported, refreshedBooks: books)
                }
            } catch {
                guard !Task.isCancelled, self.request?.id == id, request.canPresent else { return }
                presenter?.showMessage(error.userFacingMessage)
            }
            guard !Task.isCancelled, self.request?.id == id, request.canPresent, let presenter else { return }
            LocalBookImportResultViewController(summary: summary).present(from: presenter)
        }
    }

    private func invalidate(_ id: UUID) {
        guard request?.id == id else { return }
        coordinator?.cancel()
        directoryCoordinator?.cancel()
        completionTask?.cancel()
        transitionTask?.cancel()
        guard coordinator == nil, directoryCoordinator == nil,
            completionTask == nil, transitionTask == nil
        else { return }
        let modal: UIViewController? = picker ?? menu
        transitionTask = Task { @MainActor [self] in
            if let modal { await LocalBookImportOwnership.dismiss(modal) }
            picker = nil
            menu = nil
            releaseDeliveryScopes()
            transitionTask = nil
            finish(id)
        }
    }

    private func releaseDeliveryScopes() {
        for lease in deliveryScopes { lease.cancel() }
        deliveryScopes.removeAll()
    }

    private func finish(_ id: UUID) {
        guard request?.id == id, coordinator == nil, directoryCoordinator == nil,
            transitionTask == nil, completionTask == nil
        else { return }
        releaseDeliveryScopes()
        request?.stopObserving()
        request = nil
        menu = nil
        picker = nil
        pendingSummary = nil
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func menuEnvironmentChanged(_ notification: Notification) {
        guard let request, menu != nil, picker == nil else { return }
        if request.isRelated(notification) {
            request.invalidate()
        }
    }

    private func checkPendingPresentation(_ id: UUID) {
        guard request?.id == id, transitionTask == nil,
            let modal = (picker as UIViewController?) ?? menu,
            modal.presentingViewController == nil, modal.viewIfLoaded?.window == nil,
            !modal.isBeingPresented, !modal.isBeingDismissed
        else { return }
        if let picker, !consumedPicker {
            finishPicking(picker, urls: [])
        } else if menu != nil, !consumedMenu {
            request?.invalidate()
        }
    }
}
