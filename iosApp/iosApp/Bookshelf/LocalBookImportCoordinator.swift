import UIKit
import shared

struct LocalBookImportIssue {
    let fileName: String
    let message: String
}

struct LocalBookImportSummary {
    let books: [Book]
    let failures: [LocalBookImportIssue]
    let isCancelled: Bool
    // Counts refer to deduplicated source URLs, not individual archive entries.
    // A started source counts as processed once its preparation/import cleanup has ended.
    let processedFiles: Int
    let totalFiles: Int
}

/// An owned full-screen picker may detach its caller's view without changing its UI identity.
@MainActor
final class LocalBookImportOwnership: NSObject {
    let id = UUID()
    private weak var owner: UIViewController?
    private weak var window: UIWindow?
    private weak var scene: UIWindowScene?
    private weak var root: UIViewController?
    private weak var modal: UIViewController?
    private weak var modalHost: UIViewController?
    private var ancestors: [Ancestor] = []
    private var invalidated = false
    private var timer: Timer?
    private var observationID: UUID?
    private var onInvalidated: (() -> Void)?
    var onCheck: (() -> Void)?

    init?(owner: UIViewController) {
        guard owner.canPerformNavigationAction, owner.presentedViewController == nil,
            let window = owner.viewIfLoaded?.window, let scene = window.windowScene,
            let root = window.rootViewController, AppLockManager.shared.isUnlocked(in: window),
            UIApplication.shared.isProtectedDataAvailable
        else { return nil }
        self.owner = owner
        self.window = window
        self.scene = scene
        self.root = root
        super.init()
        var current: UIViewController? = owner
        var seen = Set<ObjectIdentifier>()
        while let controller = current, seen.insert(ObjectIdentifier(controller)).inserted {
            ancestors.append(Ancestor(controller))
            if controller === root { break }
            current = controller.parent ?? controller.presentingViewController
        }
        guard ancestors.last?.controller === root, isCurrent, canPresent else { return nil }
    }

    deinit {
        timer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    func observe(onInvalidated: @escaping () -> Void) {
        let observationID = UUID()
        self.observationID = observationID
        self.onInvalidated = onInvalidated
        for name in [
            UIApplication.didBecomeActiveNotification, UIApplication.protectedDataWillBecomeUnavailableNotification,
            UIScene.didActivateNotification, UIScene.didDisconnectNotification,
            UIWindow.didBecomeKeyNotification, UIWindow.didBecomeHiddenNotification,
            .appLockWillCover, .appLockStatusDidChange,
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(environmentChanged(_:)), name: name, object: nil)
        }
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.observationID == observationID, self.isCurrent else { return }
                self.onCheck?()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stopObserving() {
        observationID = nil
        timer?.invalidate()
        timer = nil
        NotificationCenter.default.removeObserver(self)
        onInvalidated = nil
        onCheck = nil
    }

    func bind(_ modal: UIViewController?) {
        self.modal = modal
        modalHost = nil
    }

    func acknowledgePresentation(_ modal: UIViewController) throws {
        guard self.modal === modal, isCurrent, let host = modal.presentingViewController,
            ancestors.contains(where: { $0.controller === host }), host.presentedViewController === modal
        else { throw CancellationError() }
        modalHost = host
    }

    var isCurrent: Bool {
        guard !invalidated else { return false }
        guard let owner, let window, let scene, let root,
            window.windowScene === scene, window.rootViewController === root,
            !window.isHidden, window.alpha > 0,
            owner.viewIfLoaded?.window == nil || owner.viewIfLoaded?.window === window,
            ancestors.allSatisfy({ $0.matches(allowing: modal) }),
            !(AppLockManager.shared.hasPassword && !AppLockManager.shared.isUnlocked(in: window))
        else {
            invalidate()
            return false
        }
        return true
    }

    private var environmentReady: Bool {
        guard let window, let scene else { return false }
        return UIApplication.shared.applicationState == .active
            && UIApplication.shared.isProtectedDataAvailable && scene.activationState == .foregroundActive
            && window.isKeyWindow && window.isUserInteractionEnabled && !window.accessibilityElementsHidden
            && AppLockManager.shared.isUnlocked(in: window)
    }

    var canPresent: Bool {
        isCurrent && environmentReady && owner?.canPerformNavigationAction == true
            && ancestors.allSatisfy {
                $0.hasOriginalPresentation && $0.controller?.transitionCoordinator == nil
            }
    }

    func canUse(
        _ modal: UIViewController, allowingDismissal: Bool = false, requiringActivation: Bool = true,
        coveredBy ownedSelection: UIViewController? = nil
    ) -> Bool {
        guard self.modal === modal, isCurrent, !requiringActivation || environmentReady else { return false }
        // UIAlertController and document picker actions may arrive after UIKit started dismissal.
        if allowingDismissal, modal.presentingViewController == nil, modal.viewIfLoaded?.window == nil {
            return requiringActivation ? canPresent : ancestors.allSatisfy { $0.hasOriginalPresentation }
        }
        let selectionIsAttached =
            ownedSelection.map {
                $0.presentingViewController === modal && modal.presentedViewController === $0
                    && $0.viewIfLoaded?.window === window
            } ?? false
        guard let host = modal.presentingViewController,
            modalHost == nil || modalHost === host,
            ancestors.contains(where: { $0.controller === host }), host.presentedViewController === modal,
            modal.viewIfLoaded?.window === window || selectionIsAttached
                || (allowingDismissal && modal.isBeingDismissed && modal.viewIfLoaded?.window == nil),
            ancestors.allSatisfy({ allowingDismissal || $0.controller?.transitionCoordinator == nil })
        else { return false }
        return allowingDismissal
            || (!modal.isBeingPresented && !modal.isBeingDismissed && modal.transitionCoordinator == nil)
    }

    func waitUntilReady() async throws {
        while true {
            try Task.checkCancellation()
            guard isCurrent else { throw CancellationError() }
            if environmentReady { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        let callback = onInvalidated
        onInvalidated = nil
        callback?()
    }

    func isRelated(_ notification: Notification) -> Bool {
        if let scene = notification.object as? UIScene, scene !== self.scene { return false }
        if let window = notification.object as? UIWindow, window !== self.window { return false }
        return true
    }

    @objc private func environmentChanged(_ notification: Notification) {
        guard observationID != nil, isRelated(notification) else { return }
        if notification.name == UIScene.didDisconnectNotification
            || notification.name == UIApplication.protectedDataWillBecomeUnavailableNotification
            || (notification.name == .appLockWillCover && AppLockManager.shared.hasPassword)
        {
            invalidate()
        } else {
            // The disabled app lock also covers ordinary provider/scene suspension for privacy.
            _ = isCurrent
        }
    }

    static func dismiss(_ controller: UIViewController) async {
        if let transition = controller.transitionCoordinator,
            controller.isBeingPresented || controller.isBeingDismissed
        {
            await withCheckedContinuation { continuation in
                if !transition.animate(alongsideTransition: nil, completion: { _ in continuation.resume() }) {
                    continuation.resume()
                }
            }
        }
        guard controller.presentingViewController != nil else { return }
        await withCheckedContinuation { continuation in
            controller.dismiss(animated: !UIAccessibility.isReduceMotionEnabled) { continuation.resume() }
        }
    }

    @MainActor
    private final class Ancestor {
        weak var controller: UIViewController?
        private weak var parent: UIViewController?
        private weak var presenter: UIViewController?
        private weak var originallyPresented: UIViewController?
        private weak var navigation: UINavigationController?
        private weak var top: UIViewController?
        private weak var tabs: UITabBarController?
        private weak var selected: UIViewController?

        init(_ controller: UIViewController) {
            self.controller = controller
            parent = controller.parent
            presenter = controller.presentingViewController
            originallyPresented = controller.presentedViewController
            navigation = controller.navigationController
            top = (controller as? UINavigationController)?.topViewController
            tabs = controller.tabBarController
            selected = (controller as? UITabBarController)?.selectedViewController
        }

        var hasOriginalPresentation: Bool { controller?.presentedViewController === originallyPresented }

        func matches(allowing modal: UIViewController?) -> Bool {
            guard let controller, controller.parent === parent, controller.presentingViewController === presenter,
                controller.navigationController === navigation, controller.tabBarController === tabs,
                !controller.isBeingDismissed, !controller.isMovingFromParent,
                hasOriginalPresentation || (originallyPresented == nil && controller.presentedViewController === modal)
            else { return false }
            if let navigation = controller as? UINavigationController, navigation.topViewController !== top {
                return false
            }
            if let tabs = controller as? UITabBarController, tabs.selectedViewController !== selected { return false }
            if let tabs = parent as? UITabBarController, tabs.selectedViewController !== controller { return false }
            return true
        }
    }
}

/// Reusable by file browsing, document previews, system URL handling and the bookshelf.
@MainActor
final class LocalBookImportCoordinator {
    var onBatchCompleted: ((LocalBookImportSummary) -> Void)?
    var onFinished: (() -> Void)?
    private(set) var completedSummary: LocalBookImportSummary?
    private(set) var canDeliverResult = false

    private weak var presenter: UIViewController?
    private let onImported: (Book) -> Void
    private var task: Task<Void, Never>?
    private var ownership: LocalBookImportOwnership?
    private var isFinishing = false
    private var progress: LocalBookImportProgressViewController?
    private weak var progressPresenter: UIViewController?
    private var selection: LocalBookArchiveSelectionViewController?
    private var selectionNavigation: UINavigationController?
    private var selectionContinuation: CheckedContinuation<[ArchiveBookEntry]?, Never>?
    private var presentationContinuation: CheckedContinuation<Void, Never>?
    private var isPresentingSelection = false
    private var hasPendingSelectionReply = false
    private var pendingSelectionReply: [ArchiveBookEntry]?

    init(presenter: UIViewController, onImported: @escaping (Book) -> Void) {
        self.presenter = presenter
        self.onImported = onImported
    }

    func start(url: URL, groupID: Int64 = 0) {
        start(urls: [url], groupID: groupID)
    }

    func start(urls: [URL], groupID: Int64 = 0) {
        guard task == nil, !isFinishing else { return }
        completedSummary = nil
        canDeliverResult = false
        let ownership = presenter.flatMap { LocalBookImportOwnership(owner: $0) }
        self.ownership = ownership
        let id = ownership?.id
        ownership?.onCheck = { [weak self] in self?.checkInteraction() }
        ownership?.observe { [weak self] in
            guard let self, self.ownership?.id == id else { return }
            self.cancel()
        }
        var seen: Set<URL> = []
        let sources = urls.compactMap { url -> SandboxFileReadLease? in
            let key = url.isFileURL ? url.standardizedFileURL : url.absoluteURL.standardized
            guard seen.insert(key).inserted else { return nil }
            // Keep the original scoped URL; normalization is only used for identity.
            // Acquire synchronously so picker delivery scopes can be released after start returns.
            return SandboxFileReadLease(url)
        }
        // The task owns the coordinator until finish, even when the entry point does not retain it.
        task = Task { @MainActor [self] in
            var batch = Batch(totalFiles: sources.count)
            do {
                try Task.checkCancellation()
                if let first = sources.first {
                    try await showProgress(fileName: first.source.lastPathComponent)
                }
                for source in sources {
                    // Never begin another source after cancellation, even while cleanup was suspended.
                    try Task.checkCancellation()
                    await importSource(source.source, groupID: groupID, batch: &batch)
                    if batch.isCancelled { break }
                }
            } catch is CancellationError {
                batch.isCancelled = true
            } catch {
                batch.failures.append(
                    LocalBookImportIssue(
                        fileName: sources.first?.source.lastPathComponent ?? "",
                        message: error.userFacingMessage
                    ))
            }
            isFinishing = true
            await dismissImportUI()
            // These leases only hold incoming scopes. They do not cancel LocalBookFileStore's copy.
            // Every prepare/shared request and prepared-file lease has already reached its terminal state.
            for source in sources { source.cancel() }
            let summary = batch.summary
            completedSummary = summary
            let completed = onBatchCompleted
            let finished = onFinished
            ownership?.stopObserving()
            canDeliverResult = ownership?.canPresent == true
            // Data remains available to the terminal owner even when stale UI callbacks are rejected.
            if canDeliverResult {
                if let completed {
                    completed(summary)
                } else {
                    summary.books.forEach(onImported)
                    if !summary.failures.isEmpty { showFailures(summary.failures) }
                }
            }
            self.ownership = nil
            task = nil
            isFinishing = false
            finished?()
        }
    }

    func cancel() {
        guard task != nil, !isFinishing else { return }
        task?.cancel()
        resolveSelection(nil)
        progress?.setStatus(BookshelfLocalImportText.cancelling, cancelling: true)
    }

    private func importSource(_ url: URL, groupID: Int64, batch: inout Batch) async {
        var prepared: PreparedLocalBookImport?
        do {
            try Task.checkCancellation()
            try await ownership?.waitUntilReady()
            let controller = try activeProgress()
            controller.setFileName(url.lastPathComponent)
            controller.setStatus("文件 \(batch.processedFiles + 1) / \(batch.totalFiles)\n\(BookshelfLocalImportText.preparing)")
            let input = try await LocalBookImportService.prepare(from: url)
            prepared = input
            try Task.checkCancellation()
            try await ownership?.waitUntilReady()
            _ = try activeProgress()
            let paths = try await entryPaths(for: input)
            for (entryIndex, entryPath) in paths.enumerated() {
                try Task.checkCancellation()
                try await ownership?.waitUntilReady()
                let controller = try activeProgress()
                let fileName = entryPath.map { "\(input.fileName) / \($0)" } ?? input.fileName
                controller.setFileName(fileName)
                controller.setStatus(
                    "文件 \(batch.processedFiles + 1) / \(batch.totalFiles)，条目 \(entryIndex + 1) / \(paths.count)\n\(BookshelfLocalImportText.importing)"
                )
                do {
                    let book = try await LocalBookImportService.importBook(
                        input, entryPath: entryPath, groupID: groupID
                    )
                    // Record an acknowledged commit even when cancel arrived during the shared request.
                    // Keep the first returned Book without rewriting reading progress or stored books.
                    batch.append(book)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    batch.failures.append(LocalBookImportIssue(fileName: fileName, message: error.userFacingMessage))
                    try Task.checkCancellation()
                }
            }
        } catch is CancellationError {
            batch.isCancelled = true
        } catch {
            batch.failures.append(LocalBookImportIssue(fileName: url.lastPathComponent, message: error.userFacingMessage))
            if Task.isCancelled { batch.isCancelled = true }
        }
        if let prepared { await LocalBookImportService.discard(prepared) }
        batch.processedFiles += 1
        // No cancellation check after the last acknowledged commit: it still owns its retained copy.
    }

    private func entryPaths(for input: PreparedLocalBookImport) async throws -> [String?] {
        guard let archive = input.archive else { return [nil] }
        guard !archive.entries.isEmpty else { throw failure("压缩包中没有可导入的书籍") }
        if archive.entries.count == 1 { return [archive.entries[0].path] }
        let selected = try await selectEntries(in: archive, fileName: input.fileName)
        let selectedPaths = Set(selected.map(\.path))
        var seen: Set<String> = []
        // Selection order does not affect import order, and a repeated entry is never imported twice.
        let paths = archive.entries.compactMap { entry -> String? in
            guard selectedPaths.contains(entry.path), seen.insert(entry.path).inserted else { return nil }
            return entry.path
        }
        guard !paths.isEmpty else { throw failure("请选择压缩包内需要导入的书籍") }
        return paths.map { Optional($0) }
    }

    private func showProgress(fileName: String) async throws {
        try Task.checkCancellation()
        guard let presenter, let ownership, ownership.canPresent
        else { throw CancellationError() }
        let controller = LocalBookImportProgressViewController(fileName: fileName)
        let id = ownership.id
        controller.onCancel = { [weak self, weak controller] in
            guard let self, let controller, self.ownership?.id == id,
                self.ownership?.canUse(controller) == true, controller.presentedViewController == nil
            else { return }
            self.cancel()
        }
        progress = controller
        ownership.bind(controller)
        await withCheckedContinuation { continuation in
            presentationContinuation = continuation
            presenter.present(controller, animated: true) { [weak self] in
                guard let self, self.ownership?.id == id else { return }
                self.finishPresentation()
            }
        }
        // UIKit may forward presentation to a navigation/container controller.
        // Track the actual presenter instead of comparing against the original caller.
        progressPresenter = controller.presentingViewController
        try ownership.acknowledgePresentation(controller)
        try await ownership.waitUntilReady()
        _ = try activeProgress()
    }

    private func activeProgress() throws -> LocalBookImportProgressViewController {
        try Task.checkCancellation()
        guard let ownership, let controller = progress, let host = progressPresenter,
            ownership.canUse(controller),
            controller.presentingViewController === host,
            host.presentedViewController === controller,
            controller.viewIfLoaded?.window != nil, !controller.isBeingDismissed,
            controller.presentedViewController == nil
        else { throw CancellationError() }
        return controller
    }

    private func selectEntries(in archive: ArchiveBookListing, fileName: String) async throws -> [ArchiveBookEntry] {
        try Task.checkCancellation()
        let host = try activeProgress()
        let controller = LocalBookArchiveSelectionViewController(fileName: fileName, entries: archive.entries)
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .formSheet
        selection = controller
        selectionNavigation = navigation
        let id = ownership?.id
        let selected: [ArchiveBookEntry]? = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return await withCheckedContinuation { continuation in
                selectionContinuation = continuation
                controller.onSelection = { [weak self, weak controller] entries in
                    guard let self, let controller, self.selection === controller,
                        self.ownership?.id == id
                    else { return }
                    let current = self.isCurrentSelection(navigation, host: host)
                    self.resolveSelection(current ? entries : nil)
                }
                // Keep one progress controller alive for the whole batch, with selection above it.
                isPresentingSelection = true
                host.present(navigation, animated: true) { [weak self] in
                    guard let self, self.selectionNavigation === navigation else { return }
                    self.isPresentingSelection = false
                    if self.hasPendingSelectionReply {
                        let reply = self.pendingSelectionReply
                        self.hasPendingSelectionReply = false
                        self.pendingSelectionReply = nil
                        self.resolveSelection(reply)
                    }
                }
                navigation.presentationController?.delegate = controller
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.ownership?.id == id else { return }
                self.resolveSelection(nil)
            }
        }
        selection = nil
        selectionNavigation = nil
        try Task.checkCancellation()
        guard let selected else { throw CancellationError() }
        try await ownership?.waitUntilReady()
        _ = try activeProgress()
        return selected
    }

    private func isCurrentSelection(_ navigation: UINavigationController, host: UIViewController) -> Bool {
        guard let ownership, selectionNavigation === navigation,
            ownership.canUse(host, coveredBy: navigation),
            navigation.topViewController === selection,
            navigation.presentedViewController == nil
        else { return false }
        if navigation.presentingViewController == nil, navigation.viewIfLoaded?.window == nil {
            return host.presentedViewController == nil
        }
        return navigation.presentingViewController === host && host.presentedViewController === navigation
            && navigation.viewIfLoaded?.window != nil
            && (host.viewIfLoaded?.window == nil || navigation.viewIfLoaded?.window === host.viewIfLoaded?.window)
            && !navigation.isBeingPresented && !navigation.isBeingDismissed
    }

    private func resolveSelection(_ entries: [ArchiveBookEntry]?) {
        guard let continuation = selectionContinuation else { return }
        if isPresentingSelection {
            if !hasPendingSelectionReply || entries == nil { pendingSelectionReply = entries }
            hasPendingSelectionReply = true
            return
        }
        // Consume before dismissal suspends, including forced departure without a UIKit delegate callback.
        selectionContinuation = nil
        selection?.onSelection = nil
        selection?.cancelSelection()
        let navigation = selectionNavigation
        Task { @MainActor in
            if let navigation { await LocalBookImportOwnership.dismiss(navigation) }
            continuation.resume(returning: entries)
        }
    }

    private func finishPresentation() {
        let continuation = presentationContinuation
        presentationContinuation = nil
        continuation?.resume()
    }

    private func checkInteraction() {
        guard task != nil, !isFinishing else { return }
        if let progress, let host = progressPresenter,
            progress.presentingViewController !== host || host.presentedViewController !== progress || progress.isBeingDismissed
        {
            cancel()
        }
        if selectionContinuation != nil, let navigation = selectionNavigation,
            navigation.topViewController !== selection || navigation.presentingViewController !== progress
                || progress?.presentedViewController !== navigation || navigation.isBeingDismissed
        {
            cancel()
        }
    }

    private func dismissImportUI() async {
        resolveSelection(nil)
        if let navigation = selectionNavigation {
            selection?.onSelection = nil
            await LocalBookImportOwnership.dismiss(navigation)
            selection = nil
            selectionNavigation = nil
        }
        guard let controller = progress else { return }
        controller.onCancel = nil
        await LocalBookImportOwnership.dismiss(controller)
        progress = nil
        progressPresenter = nil
        ownership?.bind(nil)
    }

    private func showFailures(_ failures: [LocalBookImportIssue]) {
        guard let presenter, ownership?.canPresent == true
        else { return }
        let message = failures.map { "\($0.fileName)：\($0.message)" }.joined(separator: "\n")
        let alert = UIAlertController(title: "导入失败", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default))
        presenter.present(alert, animated: true)
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "io.legado.local-book-import", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private struct Batch {
        let totalFiles: Int
        var books: [Book] = []
        var failures: [LocalBookImportIssue] = []
        var isCancelled = false
        var processedFiles = 0
        private var bookURLs: Set<String> = []

        init(totalFiles: Int) { self.totalFiles = totalFiles }

        mutating func append(_ book: Book) {
            if bookURLs.insert(book.bookUrl).inserted { books.append(book) }
        }

        var summary: LocalBookImportSummary {
            LocalBookImportSummary(
                books: books, failures: failures, isCancelled: isCancelled,
                processedFiles: processedFiles, totalFiles: totalFiles
            )
        }
    }
}
