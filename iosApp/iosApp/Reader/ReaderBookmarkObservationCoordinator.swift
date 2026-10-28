import UIKit
import shared

@MainActor
final class ReaderBookmarkObservationCoordinator: NSObject {
    var window: (() -> UIWindow?)?
    var canApplySnapshot: (() -> Bool)?
    var onSnapshot: (([Bookmark]) -> Void)?
    var onLoadError: ((Error) -> Void)?
    var onLoadingChanged: ((Bool) -> Void)?

    private(set) var isActive = false
    private(set) var hasSnapshot = false
    var hasPendingSnapshot: Bool { pendingResult != nil || mailbox?.hasPendingSnapshot == true }

    private let screen: ReaderBookmarkListProviding
    private var isVisible = false
    private var generation = UUID()
    private var subscription: FlowSubscription?
    private var loadTask: Task<Void, Never>?
    private var mailbox: ReaderBookmarkSnapshotMailbox?
    private var pendingResult: Result<[Bookmark], Error>?

    init(screen: ReaderBookmarkListProviding) {
        self.screen = screen
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(sceneDidActivate(_:)), name: UIScene.didActivateNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(sceneWillDeactivate(_:)), name: UIScene.willDeactivateNotification, object: nil)
    }

    deinit {
        loadTask?.cancel()
        subscription?.cancel()
        mailbox?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    func activate() {
        isVisible = true
        guard !isActive, isSceneActive else { return }
        isActive = true
        startLoading()
    }

    func deactivate() {
        isVisible = false
        stopLoading()
    }

    func reload() {
        stopLoading()
        if isVisible { activate() }
    }

    func resumeUpdates() {
        guard isActive, isSceneActive, mailbox?.hasPendingSnapshot != true,
            canApplySnapshot?() == true, let result = pendingResult
        else { return }
        pendingResult = nil
        switch result {
        case .success(let bookmarks):
            hasSnapshot = true
            onSnapshot?(bookmarks)
        case .failure(let error): onLoadError?(error)
        }
    }

    private var isSceneActive: Bool {
        window?()?.windowScene?.activationState == .foregroundActive
    }

    private func startLoading() {
        let generation = generation
        onLoadingChanged?(true)
        let mailbox = ReaderBookmarkSnapshotMailbox { [weak self] bookmarks in
            self?.receive(.success(bookmarks), generation: generation)
        }
        self.mailbox = mailbox
        subscription = screen.watchBookmarks { bookmarks in mailbox.submit(bookmarks) }
        guard subscription == nil else { return }
        // Providers without flow support retain their one-shot loading path.
        mailbox.cancel()
        self.mailbox = nil
        loadTask = Task { @MainActor [weak self, screen] in
            do {
                let bookmarks = try await screen.loadBookmarks()
                guard !Task.isCancelled else { return }
                self?.receive(.success(bookmarks), generation: generation)
            } catch {
                guard !Task.isCancelled else { return }
                self?.receive(.failure(error), generation: generation)
            }
        }
    }

    private func stopLoading() {
        isActive = false
        hasSnapshot = false
        generation = UUID()
        mailbox?.cancel()
        mailbox = nil
        subscription?.cancel()
        subscription = nil
        loadTask?.cancel()
        loadTask = nil
        pendingResult = nil
        onLoadingChanged?(false)
    }

    private func receive(_ result: Result<[Bookmark], Error>, generation: UUID) {
        guard isActive, isSceneActive, self.generation == generation else { return }
        loadTask = nil
        // Coalesce during gestures/transitions instead of replaying an update queue.
        pendingResult = result
        onLoadingChanged?(false)
        resumeUpdates()
    }

    @objc private func sceneDidActivate(_ notification: Notification) {
        guard let scene = notification.object as? UIScene, scene === window?()?.windowScene, isVisible else { return }
        activate()
    }

    @objc private func sceneWillDeactivate(_ notification: Notification) {
        guard let scene = notification.object as? UIScene, scene === window?()?.windowScene else { return }
        stopLoading()
    }
}

// The shared flow can call off-main. Keep only one undelivered value and one main-queue drain.
private final class ReaderBookmarkSnapshotMailbox {
    private let lock = NSLock()
    private let onSnapshot: @MainActor ([Bookmark]) -> Void
    private var latest: [Bookmark]?
    private var isScheduled = false
    private var isCancelled = false

    var hasPendingSnapshot: Bool {
        lock.lock()
        defer { lock.unlock() }
        return latest != nil
    }

    init(onSnapshot: @escaping @MainActor ([Bookmark]) -> Void) {
        self.onSnapshot = onSnapshot
    }

    func submit(_ bookmarks: [Bookmark]) {
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            return
        }
        latest = bookmarks
        let shouldSchedule = !isScheduled
        isScheduled = true
        lock.unlock()
        if shouldSchedule { DispatchQueue.main.async { [weak self] in self?.drain() } }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        latest = nil
        lock.unlock()
    }

    @MainActor private func drain() {
        lock.lock()
        let bookmarks = isCancelled ? nil : latest
        latest = nil
        isScheduled = false
        lock.unlock()
        if let bookmarks { onSnapshot(bookmarks) }
    }
}
