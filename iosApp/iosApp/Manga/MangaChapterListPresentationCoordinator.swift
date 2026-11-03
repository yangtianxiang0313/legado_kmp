import UIKit
import shared

@MainActor
final class MangaChapterListPresentationCoordinator: NSObject {
    private struct Identity {
        let chapter: MangaReaderChapter
        let recoveryGeneration: UUID
        var book: Book { chapter.book }
    }

    private weak var owner: UIViewController?
    private weak var navigation: UINavigationController?
    private weak var window: UIWindow?
    private weak var scene: UIWindowScene?
    private weak var chapterList: AndroidChapterListSheetViewController?
    private let adapter: MangaReaderAdapter
    private let canPresent: () -> Bool
    private let onPrepared: (MangaReaderChapter) -> Void
    private var identity: Identity?
    private var snapshot: MangaReaderCatalogSnapshot?
    private var requestID: UUID?
    private var taskID: UUID?
    private var task: Task<Void, Never>?
    private(set) var isPreparingSelection = false
    var onActivityChanged: (() -> Void)?
    var isActive: Bool { requestID != nil || task != nil || chapterList != nil }
    var isPreparing: Bool { task != nil }

    init(
        owner: UIViewController, adapter: MangaReaderAdapter,
        canPresent: @escaping () -> Bool, onPrepared: @escaping (MangaReaderChapter) -> Void
    ) {
        self.owner = owner
        self.adapter = adapter
        self.canPresent = canPresent
        self.onPrepared = onPrepared
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationWillDeactivate), name: UIApplication.willResignActiveNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(sceneWillDeactivate(_:)), name: UIScene.willDeactivateNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(lockWillCover(_:)), name: .appLockWillCover, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(lockStatusChanged), name: .appLockStatusDidChange, object: nil)
    }

    deinit {
        task?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    func present() {
        guard !isActive, let owner, let current = adapter.chapter,
            current.book.bookUrl == adapter.bookURL,
            let window = owner.viewIfLoaded?.window, canInteract(in: owner, window: window)
        else { return }
        let identity = Identity(chapter: current, recoveryGeneration: adapter.recoveryGeneration)
        let requestID = UUID()
        let taskID = UUID()
        self.identity = identity
        self.requestID = requestID
        self.taskID = taskID
        self.navigation = owner.navigationController
        self.window = window
        self.scene = window.windowScene
        task = Task { @MainActor [weak self, weak owner, weak window, adapter] in
            defer { self?.finishTask(taskID, requestID: requestID) }
            do {
                try Task.checkCancellation()
                let snapshot = try await adapter.loadCatalogSnapshot()
                guard let self, let owner, let window,
                    self.isCurrent(requestID, identity: identity, owner: owner, window: window),
                    ReaderSyncClient.sameIdentity(snapshot.book, identity.book),
                    snapshot.items.allSatisfy({ $0.chapter.bookUrl == adapter.bookURL })
                else { return }
                guard !snapshot.items.isEmpty else {
                    owner.showTransientMessage(L10n.BookDetail.emptyChapters)
                    return
                }
                self.snapshot = snapshot
                let list = MangaCatalogViewController(
                    items: snapshot.items, book: snapshot.book, bookURL: adapter.bookURL,
                    onSelect: { [weak self] index in
                        self?.select(index: index, position: 0, requestID: requestID, snapshot: snapshot)
                    },
                    onSelectPosition: { [weak self] index, position in
                        self?.select(index: index, position: position, requestID: requestID, snapshot: snapshot)
                    },
                    onRefresh: nil)
                list.onDismissed = { [weak self, weak list] in
                    guard let list else { return }
                    self?.catalogDidDismiss(list)
                }
                list.modalPresentationStyle = .fullScreen
                self.chapterList = list
                owner.present(list, animated: true) { [weak self, weak list] in
                    guard let self, let list, self.chapterList === list else { return }
                    guard self.requestID == requestID, self.matches(identity), self.canPresent(),
                        self.hasOwnerIdentity(), self.environmentIsActive(in: window),
                        self.ownsCatalogPresentation, self.chapterList?.viewIfLoaded?.window === window
                    else { self.cancel(); return }
                }
            } catch {
                guard !(error is CancellationError), let self, let owner, let window,
                    self.isCurrent(requestID, identity: identity, owner: owner, window: window)
                else { return }
                owner.showTransientMessage(error.userFacingMessage)
            }
        }
        onActivityChanged?()
    }

    func cancel() {
        guard isActive else { return }
        clearRequest()
        // Shared cancellation can settle later; only finishTask releases the single flight.
        task?.cancel()
        dismissInvalidatedCatalog()
        onActivityChanged?()
    }

    func ownerWillDisappear() {
        // A full-screen TOC removes the reader's view from its window, but does not pop its owner.
        if ownsCatalogPresentation, hasOwnerIdentity() { return }
        cancel()
    }

    private func catalogDidDismiss(_ list: AndroidChapterListSheetViewController) {
        guard chapterList === list else { return }
        chapterList = nil
        if task == nil { clearRequest() }
        onActivityChanged?()
    }

    private func select(index: Int, position: Int, requestID: UUID, snapshot: MangaReaderCatalogSnapshot) {
        // Both shared TOC callbacks run only after the list has naturally dismissed.
        guard task == nil, self.requestID == requestID, self.snapshot?.identity == snapshot.identity,
            let identity, let owner, let window
        else { return }
        chapterList = nil
        let taskID = UUID()
        self.taskID = taskID
        isPreparingSelection = true
        task = Task { @MainActor [weak self, weak owner, weak window, adapter] in
            defer { self?.finishTask(taskID, requestID: requestID) }
            await Task.yield()
            guard let owner, let window,
                self?.isCurrent(requestID, identity: identity, owner: owner, window: window) == true
            else { return }
            do {
                let prepared = try await adapter.prepareCatalogSelection(
                    index: index, position: position, snapshot: snapshot)
                // The adapter binds its legal generation rollover to this exact snapshot and prepared object.
                guard let self,
                    self.isPresentationCurrent(requestID, identity: identity, owner: owner, window: window),
                    self.snapshot?.identity == snapshot.identity,
                    ReaderSyncClient.sameIdentity(prepared.book, snapshot.book), Int(prepared.chapterIndex) == index,
                    adapter.isPreparedCatalogSelectionCurrent(prepared, snapshot: snapshot)
                else { return }
                self.onPrepared(prepared)
            } catch {
                guard !(error is CancellationError), let self,
                    self.isPresentationCurrent(requestID, identity: identity, owner: owner, window: window),
                    self.snapshot?.identity == snapshot.identity,
                    adapter.isCatalogSelectionContextCurrent(snapshot: snapshot)
                else { return }
                owner.showTransientMessage(error.userFacingMessage)
            }
        }
        onActivityChanged?()
    }

    private func finishTask(_ taskID: UUID, requestID: UUID) {
        guard self.taskID == taskID else { return }
        self.taskID = nil
        task = nil
        isPreparingSelection = false
        if self.requestID == requestID, chapterList == nil { clearRequest() }
        onActivityChanged?()
    }

    private func clearRequest() {
        requestID = nil
        identity = nil
        snapshot = nil
        navigation = nil
        window = nil
        scene = nil
    }

    private func matches(_ identity: Identity) -> Bool {
        adapter.recoveryGeneration == identity.recoveryGeneration && hasReaderIdentity(identity)
    }

    private func hasReaderIdentity(_ identity: Identity) -> Bool {
        !adapter.isRetired && adapter.bookURL == identity.book.bookUrl
            && adapter.chapter === identity.chapter
            && adapter.chapter.map { ReaderSyncClient.sameIdentity($0.book, identity.book) } == true
    }

    private func isCurrent(_ requestID: UUID, identity: Identity, owner: UIViewController, window: UIWindow) -> Bool {
        matches(identity) && isPresentationCurrent(requestID, identity: identity, owner: owner, window: window)
    }

    private func isPresentationCurrent(_ requestID: UUID, identity: Identity, owner: UIViewController, window: UIWindow)
        -> Bool
    {
        !Task.isCancelled && self.requestID == requestID && self.owner === owner && self.window === window
            && hasOwnerIdentity() && environmentIsActive(in: window)
            && hasReaderIdentity(identity)
            && canInteract(in: owner, window: window)
    }

    private func hasOwnerIdentity() -> Bool {
        guard let owner, let navigation, owner.navigationController === navigation,
            navigation.topViewController === owner
        else { return false }
        var current: UIViewController? = owner
        while let controller = current {
            guard !controller.isMovingFromParent, !controller.isMovingToParent,
                !controller.isBeingPresented, !controller.isBeingDismissed
            else { return false }
            current = controller.parent
        }
        return true
    }

    private func environmentIsActive(in window: UIWindow) -> Bool {
        window.windowScene === scene && scene?.activationState == .foregroundActive
            && UIApplication.shared.applicationState == .active && window.isKeyWindow
            && !window.isHidden && window.alpha > 0 && AppLockManager.shared.isUnlocked(in: window)
    }

    private func canInteract(in owner: UIViewController, window: UIWindow) -> Bool {
        canPresent() && !adapter.isRetired && owner.viewIfLoaded?.window === window
            && owner.navigationController?.topViewController === owner && owner.canPerformNavigationAction
            && owner.transitionCoordinator == nil && window.windowScene?.activationState == .foregroundActive
            && AppLockManager.shared.isUnlocked(in: window)
    }

    private var ownsCatalogPresentation: Bool {
        guard let chapterList else { return false }
        var current = owner
        while let controller = current {
            if let presented = controller.presentedViewController { return presented === chapterList }
            current = controller.parent
        }
        return false
    }

    private func dismissInvalidatedCatalog() {
        guard let list = chapterList, !list.isBeingPresented else { return }
        let completion = { [weak self, weak list] in
            guard let self, self.chapterList === list else { return }
            self.chapterList = nil
            self.onActivityChanged?()
        }
        if list.isBeingDismissed {
            list.transitionCoordinator?.animate(alongsideTransition: nil) { _ in completion() }
        } else if list.presentedViewController != nil, let presenter = list.presentingViewController {
            presenter.dismiss(animated: true, completion: completion)
        } else {
            ChapterListNavigation.close(list, completion: completion)
        }
    }

    @objc private func applicationWillDeactivate() { cancel() }

    @objc private func sceneWillDeactivate(_ notification: Notification) {
        guard let scene = notification.object as? UIScene, scene === self.scene else { return }
        cancel()
    }

    @objc private func lockWillCover(_ notification: Notification) {
        guard let window = notification.object as? UIWindow, window === self.window else { return }
        cancel()
    }

    @objc private func lockStatusChanged() {
        guard let window, !AppLockManager.shared.isUnlocked(in: window) else { return }
        cancel()
    }
}

// Keep the shared TOC UI intact; its completion must consume selection before presentation cleanup.
@MainActor
private final class MangaCatalogViewController: AndroidChapterListSheetViewController {
    var onDismissed: (() -> Void)?

    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        super.dismiss(animated: flag) { [self] in
            completion?()
            guard presentingViewController == nil, viewIfLoaded?.window == nil else { return }
            onDismissed?()
        }
    }
}
