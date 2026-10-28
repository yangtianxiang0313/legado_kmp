import shared
import UIKit
import UniformTypeIdentifiers

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
    private var pickingDirectory = false
    private var importGroupID: Int64 = 0
    private var task: Task<Void, Never>?
    private var deliveryScopes: [SandboxFileReadLease] = []

    init(presenter: AndroidReplicaBookshelfViewController, screen: BookshelfScreenAdapter) {
        self.presenter = presenter
        self.screen = screen
        super.init()
    }

    deinit {
        task?.cancel()
    }

    func start() {
        guard task == nil, picker == nil, coordinator == nil, directoryCoordinator == nil,
            let presenter, presenter.viewIfLoaded?.window != nil,
            presenter.presentedViewController == nil, presenter.canPerformNavigationAction,
            presenter.view.window.map({ AppLockManager.shared.isUnlocked(in: $0) }) == true
        else { return }
        let menu = UIAlertController(title: BookshelfLocalImportText.title, message: nil, preferredStyle: .actionSheet)
        menu.addAction(
            UIAlertAction(title: "选择文件", style: .default) { [weak self, weak menu] _ in
                self?.afterMenu(menu) { [weak self] in self?.chooseFiles(directory: false) }
            })
        menu.addAction(
            UIAlertAction(title: "扫描文件夹", style: .default) { [weak self, weak menu] _ in
                self?.afterMenu(menu) { [weak self] in self?.chooseFiles(directory: true) }
            })
        menu.addAction(
            UIAlertAction(title: "导入文件名规则", style: .default) { [weak self, weak menu] _ in
                self?.afterMenu(menu) { [weak self] in
                    guard let self, let presenter = self.presenter, presenter.canPerformNavigationAction else { return }
                    let navigation = UINavigationController(rootViewController: LocalBookFileNameRuleViewController())
                    navigation.modalPresentationStyle = .formSheet
                    presenter.present(navigation, animated: !UIAccessibility.isReduceMotionEnabled)
                }
            })
        menu.addAction(UIAlertAction(title: BookshelfLocalImportText.cancel, style: .cancel))
        menu.popoverPresentationController?.sourceView = presenter.view
        menu.popoverPresentationController?.sourceRect = CGRect(
            x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
        presenter.present(menu, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    private func afterMenu(_ menu: UIViewController?, action: @escaping @MainActor () -> Void) {
        guard task == nil, let menu else { return }
        task = Task { @MainActor [weak self] in
            await Self.dismiss(menu)
            guard let self else { return }
            self.task = nil
            guard !Task.isCancelled else { return }
            action()
        }
    }

    private func chooseFiles(directory: Bool) {
        guard let presenter, presenter.canPerformNavigationAction,
            task == nil, picker == nil, coordinator == nil, directoryCoordinator == nil,
            presenter.view.window.map({ AppLockManager.shared.isUnlocked(in: $0) }) == true
        else { return }
        pickingDirectory = directory
        importGroupID = screen.currentSelectedGroupId
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: directory ? [.folder] : LocalBookFormats.pickerTypes, asCopy: !directory)
        picker.allowsMultipleSelection = !directory
        picker.delegate = self
        self.picker = picker
        presenter.present(picker, animated: true)
        picker.presentationController?.delegate = self
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        finishPicking(controller, urls: urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finishPicking(controller, urls: [])
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard presentationController.presentedViewController === picker, task == nil else { return }
        picker = nil
        presenter?.showMessage(BookshelfLocalImportText.cancelled)
    }

    private func finishPicking(_ controller: UIDocumentPickerViewController, urls: [URL]) {
        guard picker === controller, task == nil else { return }
        deliveryScopes = urls.map(SandboxFileReadLease.init)
        task = Task { @MainActor [weak self, screen] in
            await Self.dismiss(controller)
            self?.picker = nil
            guard let self else { return }
            defer {
                self.deliveryScopes.forEach { $0.cancel() }
                self.deliveryScopes.removeAll()
            }
            self.task = nil
            guard !urls.isEmpty, !Task.isCancelled,
                let presenter = self.presenter, presenter.viewIfLoaded?.window != nil
            else {
                self.presenter?.showMessage(BookshelfLocalImportText.cancelled)
                return
            }
            if self.pickingDirectory, let root = urls.first {
                let coordinator = LocalBookDirectoryImportCoordinator(presenter: presenter)
                coordinator.onBatchCompleted = { [weak self, screen] summary in self?.complete(summary, screen: screen) }
                coordinator.onFinished = { [weak self] in self?.directoryCoordinator = nil }
                self.directoryCoordinator = coordinator
                coordinator.start(root: root, groupID: self.importGroupID)
                return
            }
            let coordinator = LocalBookImportCoordinator(presenter: presenter) { _ in }
            coordinator.onBatchCompleted = { [weak self, screen] summary in self?.complete(summary, screen: screen) }
            coordinator.onFinished = { [weak self] in self?.coordinator = nil }
            self.coordinator = coordinator
            coordinator.start(urls: urls, groupID: self.importGroupID)
        }
    }

    private func complete(_ summary: LocalBookImportSummary, screen: BookshelfScreenAdapter) {
        task = Task { @MainActor [weak self] in
            defer { self?.task = nil }
            guard let self else { return }
            do {
                let books = try await screen.reloadBooks()
                if let imported = summary.books.first { presenter?.applyLocalBookImport(imported, refreshedBooks: books) }
            } catch {
                presenter?.showMessage(error.userFacingMessage)
            }
            guard let presenter else { return }
            LocalBookImportResultViewController(summary: summary).present(from: presenter)
        }
    }

    private static func dismiss(_ controller: UIViewController) async {
        if controller.isBeingDismissed, let transition = controller.transitionCoordinator {
            await withCheckedContinuation { continuation in
                let registered = transition.animate(alongsideTransition: nil) { _ in
                    continuation.resume()
                }
                if !registered {
                    continuation.resume()
                }
            }
        } else if controller.presentingViewController != nil {
            await withCheckedContinuation { continuation in
                controller.dismiss(animated: true) {
                    continuation.resume()
                }
            }
        }
    }
}
