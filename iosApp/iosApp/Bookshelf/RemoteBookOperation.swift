import shared
import UIKit

/// Owns work, not its page. A late commit is retained even when its UI delivery is no longer valid.
@MainActor
final class RemoteBookOperation: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
    var onStateChanged: ((String?, Bool) -> Void)?
    var onBooksLoaded: (([RemoteBook]) -> Void)?
    var onLoadFailed: ((String) -> Void)?
    var onReady: (() -> Void)?

    private enum Phase { case loading, downloading, importing, associating, picking, uploading, deleting }
    private enum Outcome {
        case message(String)
        case imported(LocalBookImportSummary, [Book]?)
    }

    private weak var owner: UIViewController?
    private let screen: BookshelfScreenAdapter
    private let browser: Result<RemoteBookBrowserClient, Error>
    private var context: RemoteBookOperationOwner?
    private var task: Task<Void, Never>?
    private var importer: LocalBookImportCoordinator?
    private var picker: UIDocumentPickerViewController?
    private var phase: Phase?
    private var operationID: UUID?
    private var operationGeneration = UUID()
    private(set) var interactionGeneration = UUID()
    private var pageVisible = false
    private var cancellationRequested = false
    private var pendingOutcome: Outcome?
    private var lastLoadError: String?
    private(set) var needsReload = false

    var isBusy: Bool { phase != nil }
    var canStart: Bool { !isBusy && pendingOutcome == nil && pageVisible && context?.canPresent == true }

    init(owner: UIViewController, screen: BookshelfScreenAdapter, browser: Result<RemoteBookBrowserClient, Error>) {
        self.owner = owner
        self.screen = screen
        self.browser = browser
        super.init()
        for name in [
            UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification,
            UIApplication.willResignActiveNotification, .appLockWillCover,
        ] {
            NotificationCenter.default.addObserver(self, selector: #selector(suspend(_:)), name: name, object: nil)
        }
        for name in [
            UIScene.didActivateNotification, UIApplication.didBecomeActiveNotification,
            UIWindow.didBecomeKeyNotification, .appLockStatusDidChange,
        ] {
            NotificationCenter.default.addObserver(self, selector: #selector(resume(_:)), name: name, object: nil)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        task?.cancel()
    }

    func appear() {
        guard let owner, owner.isVisibleInNavigationStack else { return }
        if context == nil { context = RemoteBookOperationOwner(owner) }
        pageVisible = true
        deliverOutcome()
        if canStart, pendingOutcome == nil { onReady?() }
    }

    func disappear() {
        pageVisible = false
        interactionGeneration = UUID()
        cancel()
    }

    func ownerDidDisappear() {
        // A progress/selection sheet does not change the navigation owner. Nor may an idle
        // parent page cancel a loader which its child has just started on the shared client.
        if context?.hasCurrentNavigation == false { disappear() }
    }

    func acceptsInteraction(_ generation: UUID) -> Bool {
        interactionGeneration == generation && canStart
    }

    @objc private func suspend(_ notification: Notification) {
        if let scene = notification.object as? UIScene, scene !== context?.scene { return }
        if let window = notification.object as? UIWindow, context?.isIn(window) != true { return }
        interactionGeneration = UUID()
        cancel()
    }

    @objc private func resume(_ notification: Notification) {
        if let scene = notification.object as? UIScene, scene !== context?.scene { return }
        if let window = notification.object as? UIWindow, context?.isIn(window) != true { return }
        guard pageVisible else { return }
        DispatchQueue.main.async { [weak self] in self?.appear() }
    }

    func cancel() {
        guard let phase, !cancellationRequested else { return }
        cancellationRequested = true
        interactionGeneration = UUID()
        if phase == .uploading || phase == .deleting { needsReload = true }
        // Import cleanup must return its acknowledged commits before source association starts.
        // Do not cancel that Task: the association pass still visits every committed book.
        if phase != .importing && phase != .associating { task?.cancel() }
        if phase == .downloading || phase == .uploading { try? browser.get().cancel() }
        importer?.cancel()
        onStateChanged?(BookshelfLocalImportText.cancelling, false)
        if phase == .picking, task == nil, let picker, let id = operationID {
            picker.delegate = nil
            task = Task { @MainActor [self] in
                await Self.dismiss(picker)
                self.picker = nil
                finish(id)
            }
        }
    }

    func load(path: String?) {
        guard let id = begin(.loading, message: L10n.Bookshelf.remoteLoading) else { return }
        // One requested refresh is one attempt, not an automatic retry loop after a failure.
        needsReload = false
        lastLoadError = nil
        task = Task { @MainActor [self] in
            do {
                try ensureCurrent(id)
                let books = try await browser.get().list(path: path)
                try ensureCurrent(id)
                needsReload = false
                lastLoadError = nil
                onBooksLoaded?(books)
            } catch {
                if canDeliver(id), !cancellationRequested, !(error is CancellationError) {
                    lastLoadError = error.userFacingMessage
                    pendingOutcome = .message(error.userFacingMessage)
                } else if cancellationRequested {
                    lastLoadError = "已停止加载，可点击重试"
                }
            }
            finish(id)
        }
    }

    func downloadAndImport(_ book: RemoteBook, groupID: Int64) {
        guard !book.isDir, let id = begin(.downloading, message: L10n.Bookshelf.remoteDownloading) else { return }
        task = Task { @MainActor [self] in
            do {
                try ensureCurrent(id)
                let client = try browser.get()
                let file = try await client.download(
                    book,
                    onProgress: { [weak self] received, total in
                        guard let self, self.canDeliver(id), !self.cancellationRequested else { return }
                        let receivedText = ByteCountFormatter.string(fromByteCount: max(0, received), countStyle: .file)
                        let suffix = total.flatMap {
                            $0 > 0 ? ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) : nil
                        }
                        self.onStateChanged?(
                            "\(L10n.Bookshelf.remoteDownloading) \(receivedText)\(suffix.map { " / \($0)" } ?? "")", true)
                    })
                try ensureCurrent(id)
                setPhase(.importing, message: BookshelfLocalImportText.importing)
                let summary = await importDownloaded(file.url, groupID: groupID, id: id)
                // The coordinator reports only after dismissImportUI has completed. Also let
                // UIKit finish clearing transition flags before any result can be delivered.
                await waitForOwnerTransition()
                setPhase(.associating, message: cancellationRequested ? BookshelfLocalImportText.cancelling : "正在关联远程来源")
                var associated: [Book] = []
                var failures = summary.failures
                for committed in summary.books {
                    do {
                        // Metadata only. Never import again or replace reading progress with a download snapshot.
                        associated.append(try await client.associate(committed, remoteOrigin: file.remoteOrigin))
                    } catch {
                        associated.append(committed)
                        failures.append(
                            LocalBookImportIssue(
                                fileName: committed.name,
                                message: "书籍已保留在书架，远程来源关联未确认：\(error.userFacingMessage)"
                            ))
                    }
                }
                var refreshed: [Book]?
                if !associated.isEmpty {
                    do { refreshed = try await screen.reloadBooks() } catch {
                        failures.append(LocalBookImportIssue(fileName: "书架", message: "书籍已入架，刷新失败：\(error.userFacingMessage)"))
                    }
                }
                pendingOutcome = .imported(
                    LocalBookImportSummary(
                        books: associated, failures: failures, isCancelled: summary.isCancelled || cancellationRequested,
                        processedFiles: summary.processedFiles, totalFiles: summary.totalFiles
                    ), refreshed)
            } catch {
                if canDeliver(id), !cancellationRequested, !(error is CancellationError) {
                    pendingOutcome = .message(error.userFacingMessage)
                }
            }
            // The downloaded file and all committed local copies remain owned by their stores.
            finish(id)
        }
    }

    private func importDownloaded(_ url: URL, groupID: Int64, id: UUID) async -> LocalBookImportSummary {
        await withCheckedContinuation { continuation in
            guard canDeliver(id), !cancellationRequested, let owner else {
                continuation.resume(
                    returning: LocalBookImportSummary(
                        books: [], failures: [], isCancelled: true, processedFiles: 0, totalFiles: 1
                    ))
                return
            }
            let importer = LocalBookImportCoordinator(presenter: owner) { _ in }
            self.importer = importer
            importer.onBatchCompleted = { summary in continuation.resume(returning: summary) }
            importer.onFinished = { [weak self, weak importer] in
                if self?.importer === importer { self?.importer = nil }
            }
            importer.start(url: url, groupID: groupID)
        }
    }

    func chooseUploads() {
        guard let owner, let id = begin(.picking, message: L10n.Bookshelf.remoteUpload) else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: LocalBookFormats.pickerTypes, asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        self.picker = picker
        owner.present(picker, animated: true)
        picker.presentationController?.delegate = self
        // The generation belongs to this picker, including its dismissal and URL scope delivery.
        operationID = id
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        finishPicking(controller, urls: urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finishPicking(controller, urls: [])
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard presentationController.presentedViewController === picker, task == nil, let id = operationID else { return }
        picker = nil
        finish(id)
    }

    private func finishPicking(_ controller: UIDocumentPickerViewController, urls: [URL]) {
        guard picker === controller, task == nil, let id = operationID, !cancellationRequested else { return }
        // Hold picker-delivery scopes until the client's safe copy and upload have reached a terminal state.
        let leases = urls.map(SandboxFileReadLease.init)
        controller.delegate = nil
        task = Task { @MainActor [self] in
            defer { leases.forEach { $0.cancel() } }
            await Self.dismiss(controller)
            picker = nil
            do {
                try ensureCurrent(id)
                if !leases.isEmpty {
                    setPhase(.uploading, message: L10n.Bookshelf.remoteUploading)
                    let client = try browser.get()
                    var successful = 0
                    var failures: [String] = []
                    for lease in leases {
                        try ensureCurrent(id)
                        guard LocalBookFormats.importExtensions.contains(lease.source.pathExtension.lowercased()) else {
                            failures.append("\(lease.source.lastPathComponent)：\(LocalBookFormats.unsupportedMessage)")
                            continue
                        }
                        needsReload = true
                        do {
                            _ = try await client.upload(lease.source) { [weak self] sent, total in
                                guard let self, self.canDeliver(id), !self.cancellationRequested else { return }
                                let sentText = ByteCountFormatter.string(fromByteCount: sent, countStyle: .file)
                                let totalText = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
                                self.onStateChanged?("上传 \(sentText) / \(totalText)", true)
                            }
                            successful += 1
                        } catch {
                            if error is RemoteBookUploadOutcomeError {
                                pendingOutcome = .message(error.userFacingMessage)
                                // Never replay an uncertain mutation or continue a batch against a changed session.
                                throw error
                            }
                            if cancellationRequested || Task.isCancelled || error is CancellationError {
                                pendingOutcome = .message(
                                    "已取消当前文件上传，当前文件尚未发送。"
                                        + (successful > 0 ? "此前已确认上传 \(successful) 个文件，取消不会撤销这些文件。" : ""))
                                throw CancellationError()
                            }
                            failures.append("\(lease.source.lastPathComponent)：\(error.userFacingMessage)")
                        }
                    }
                    try ensureCurrent(id)
                    let message: String
                    if leases.count == 1, successful == 1 {
                        message = String(format: L10n.Bookshelf.remoteUploaded, leases[0].source.lastPathComponent)
                    } else {
                        message =
                            L10n.Bookshelf.batchResult(successCount: successful, failedCount: failures.count)
                            + (failures.isEmpty ? "" : "\n" + failures.joined(separator: "\n"))
                    }
                    pendingOutcome = .message(message)
                }
            } catch {
                if !cancellationRequested, !(error is CancellationError), canDeliver(id) {
                    pendingOutcome = .message(error.userFacingMessage)
                }
            }
            finish(id)
        }
    }

    func delete(_ book: RemoteBook) {
        guard let id = begin(.deleting, message: L10n.Common.delete) else { return }
        task = Task { @MainActor [self] in
            do {
                try ensureCurrent(id)
                needsReload = true
                try await browser.get().delete(book)
                try ensureCurrent(id)
            } catch {
                if canDeliver(id), !cancellationRequested, !(error is CancellationError) {
                    pendingOutcome = .message(error.userFacingMessage)
                }
            }
            finish(id)
        }
    }

    private func begin(_ phase: Phase, message: String) -> UUID? {
        guard canStart else { return nil }
        let id = UUID()
        operationID = id
        interactionGeneration = UUID()
        operationGeneration = interactionGeneration
        cancellationRequested = false
        self.phase = phase
        onStateChanged?(message, true)
        return id
    }

    private func setPhase(_ phase: Phase, message: String) {
        self.phase = phase
        if pageVisible { onStateChanged?(message, !cancellationRequested) }
    }

    private func canDeliver(_ id: UUID) -> Bool {
        operationID == id && operationGeneration == interactionGeneration && pageVisible && context?.canPresent == true
    }

    private func ensureCurrent(_ id: UUID) throws {
        try Task.checkCancellation()
        guard !cancellationRequested, canDeliver(id) else { throw CancellationError() }
    }

    private func finish(_ id: UUID) {
        guard operationID == id else { return }
        let wasWriting = phase == .uploading || phase == .deleting
        if cancellationRequested, wasWriting, pendingOutcome == nil {
            pendingOutcome = .message("已停止本地等待，远端操作可能已完成；请刷新确认。已成功处理的文件不会删除。")
        }
        phase = nil
        task = nil
        importer = nil
        operationID = nil
        onStateChanged?(nil, false)
        if let lastLoadError { onLoadFailed?(lastLoadError) }
        // Dismissal callbacks may still be inside UIKit's transition completion stack.
        let generation = interactionGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.interactionGeneration == generation, !self.isBusy else { return }
            self.deliverOutcome()
            if self.canStart, self.needsReload, self.pendingOutcome == nil { self.onReady?() }
        }
    }

    private func deliverOutcome() {
        guard !isBusy, pageVisible, context?.canPresent == true, let owner, let outcome = pendingOutcome else { return }
        pendingOutcome = nil
        switch outcome {
        case .message(let message):
            owner.showTransientMessage(message, duration: 4)
        case .imported(let summary, let refreshed):
            if let first = summary.books.first, let refreshed {
                context?.bookshelf?.applyLocalBookImport(first, refreshedBooks: refreshed)
            }
            if summary.books.count == 1, summary.failures.isEmpty, !summary.isCancelled,
                summary.processedFiles == summary.totalFiles, let book = summary.books.first
            {
                owner.showTransientMessage(BookshelfLocalImportText.success(book.name))
            } else {
                LocalBookImportResultViewController(summary: summary).present(from: owner)
            }
        }
    }

    private static func dismiss(_ controller: UIViewController) async {
        if let transition = controller.transitionCoordinator,
            controller.isBeingPresented || controller.isBeingDismissed
        {
            await withCheckedContinuation { continuation in
                if !transition.animate(alongsideTransition: nil, completion: { _ in continuation.resume() }) {
                    continuation.resume()
                }
            }
            await Task.yield()
        }
        guard controller.presentingViewController != nil else { return }
        await withCheckedContinuation { continuation in
            controller.dismiss(animated: false) { continuation.resume() }
        }
        await Task.yield()
    }

    private func waitForOwnerTransition() async {
        if let transition = context?.transition {
            await withCheckedContinuation { continuation in
                if !transition.animate(alongsideTransition: nil, completion: { _ in continuation.resume() }) {
                    continuation.resume()
                }
            }
        }
        await Task.yield()
    }
}

@MainActor
private final class RemoteBookOperationOwner {
    weak var scene: UIWindowScene?
    weak var bookshelf: AndroidReplicaBookshelfViewController?
    private weak var owner: UIViewController?
    private weak var window: UIWindow?
    private weak var root: UIViewController?
    private weak var navigation: UINavigationController?

    init(_ owner: UIViewController) {
        self.owner = owner
        window = owner.viewIfLoaded?.window
        scene = window?.windowScene
        root = window?.rootViewController
        navigation = owner.navigationController
        bookshelf = navigation?.viewControllers.reversed().compactMap(Self.findBookshelf).first
    }

    var canPresent: Bool {
        guard let owner, let window, let scene, let root, let navigation,
            owner.navigationController === navigation, navigation.topViewController === owner,
            owner.viewIfLoaded?.window === window, window.windowScene === scene,
            window.rootViewController === root, owner.canPerformNavigationAction,
            window.isUserInteractionEnabled, !window.accessibilityElementsHidden,
            AppLockManager.shared.isUnlocked(in: window)
        else { return false }
        return true
    }

    var hasCurrentNavigation: Bool {
        guard let owner, let navigation, let window, let root else { return false }
        return owner.navigationController === navigation && navigation.topViewController === owner
            && window.rootViewController === root
    }

    var transition: UIViewControllerTransitionCoordinator? { owner?.transitionCoordinator }

    func isIn(_ window: UIWindow) -> Bool { self.window === window }

    private static func findBookshelf(_ controller: UIViewController) -> AndroidReplicaBookshelfViewController? {
        if let bookshelf = controller as? AndroidReplicaBookshelfViewController { return bookshelf }
        return controller.children.compactMap(findBookshelf).first
    }
}
