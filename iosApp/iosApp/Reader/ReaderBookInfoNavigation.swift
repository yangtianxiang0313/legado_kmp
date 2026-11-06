import UIKit
import shared

@MainActor
final class ReaderBookInfoNavigation: NSObject {
    private weak var owner: UIViewController?
    private let bookURL: @MainActor () -> String
    private let currentBook: @MainActor () -> Book?
    private let snapshot: @MainActor () async throws -> Book?
    private let canInteract: @MainActor () -> Bool
    private let onWillNavigate: (@MainActor () -> Void)?
    private var generation = UUID()
    private var task: Task<Void, Never>?

    var isPreparing: Bool { task != nil }

    init(
        owner: UIViewController, bookURL: @escaping @MainActor () -> String,
        currentBook: @escaping @MainActor () -> Book?,
        snapshot: @escaping @MainActor () async throws -> Book?,
        canInteract: @escaping @MainActor () -> Bool,
        onWillNavigate: (@MainActor () -> Void)? = nil
    ) {
        self.owner = owner
        self.bookURL = bookURL
        self.currentBook = currentBook
        self.snapshot = snapshot
        self.canInteract = canInteract
        self.onWillNavigate = onWillNavigate
        super.init()
    }

    deinit {
        task?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    func open(expectedOrigin: String, isCurrent: @escaping @MainActor () -> Bool = { true }) {
        guard task == nil else { return }
        let bookURL = self.bookURL()
        guard isCurrent(), !bookURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !expectedOrigin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let expected = currentBook(), expected.bookUrl == bookURL,
            expected.origin == expectedOrigin,
            let owner, let navigation = owner.navigationController,
            let window = owner.viewIfLoaded?.window, let scene = window.windowScene,
            canNavigate(owner: owner, navigation: navigation, window: window, scene: scene)
        else { return }

        let token = UUID()
        generation = token
        observeEnvironment(window: window, scene: scene)
        let snapshot = snapshot
        task = Task { @MainActor [weak self, weak owner, weak navigation, weak window, weak scene] in
            defer { self?.finishPreparation() }
            guard isCurrent(),
                self?.accepts(
                    token, expected: expected, owner: owner, navigation: navigation, window: window,
                    scene: scene) == true
            else { return }
            do {
                // The owner stages progress first; this closure flushes it and returns a fresh, identity-bound book.
                let book = try await snapshot()
                guard isCurrent(), let self, let owner, let navigation,
                    self.accepts(
                        token, expected: expected, owner: owner, navigation: navigation, window: window,
                        scene: scene),
                    self.matches(book, expected: expected)
                else { return }

                let destination = AndroidReplicaBookDetailViewController(bookURL: expected.bookUrl)
                    .configuredForDrillDownPresentation()
                self.onWillNavigate?()
                guard isCurrent(),
                    self.accepts(
                        token, expected: expected, owner: owner, navigation: navigation, window: window,
                        scene: scene),
                    self.matches(book, expected: expected)
                else { return }
                navigation.pushViewController(destination, animated: !UIAccessibility.isReduceMotionEnabled)
            } catch {
                guard !(error is CancellationError), isCurrent(), let self, let owner,
                    self.accepts(
                        token, expected: expected, owner: owner, navigation: navigation, window: window,
                        scene: scene)
                else { return }
                owner.showTransientMessage(error.userFacingMessage)
            }
        }
    }

    func cancel() {
        generation = UUID()
        NotificationCenter.default.removeObserver(self)
        // An authorized save may still finish. Keep the flight occupied until its closure settles.
        task?.cancel()
    }

    func currentBookDidChange(from previous: Book?) {
        guard task != nil else { return }
        guard let previous, matches(currentBook(), expected: previous) else {
            cancel()
            return
        }
    }

    private func observeEnvironment(window: UIWindow, scene: UIWindowScene) {
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(environmentInvalidated),
            name: UIApplication.willResignActiveNotification,
            object: nil)
        for name in [UIScene.willDeactivateNotification, UIScene.didDisconnectNotification] {
            center.addObserver(
                self, selector: #selector(environmentInvalidated), name: name, object: scene)
        }
        for name in [
            UIWindow.didResignKeyNotification, UIWindow.didBecomeHiddenNotification, .appLockWillCover,
        ] {
            center.addObserver(
                self, selector: #selector(environmentInvalidated), name: name, object: window)
        }
    }

    private func finishPreparation() {
        NotificationCenter.default.removeObserver(self)
        task = nil
    }

    @objc private func environmentInvalidated() { cancel() }

    private func accepts(
        _ token: UUID, expected: Book, owner: UIViewController?, navigation: UINavigationController?,
        window: UIWindow?, scene: UIWindowScene?
    ) -> Bool {
        guard !Task.isCancelled, generation == token, let owner, self.owner === owner,
            let navigation, let window, let scene,
            matches(currentBook(), expected: expected)
        else { return false }
        return canNavigate(owner: owner, navigation: navigation, window: window, scene: scene)
    }

    private func matches(_ book: Book?, expected: Book) -> Bool {
        guard let book else { return false }
        // Preview books may open their natural detail page without being added to the shelf.
        return book.bookUrl == bookURL() && book.type == expected.type
            && ReaderSyncClient.sameIdentity(book, expected)
            && book.isNotShelf == expected.isNotShelf
    }

    private func canNavigate(
        owner: UIViewController, navigation: UINavigationController, window: UIWindow,
        scene: UIWindowScene
    ) -> Bool {
        canInteract() && owner.navigationController === navigation
            && navigation.topViewController === owner
            && owner.viewIfLoaded?.window === window && navigation.viewIfLoaded?.window === window
            && window.windowScene === scene && scene.activationState == .foregroundActive
            && UIApplication.shared.applicationState == .active && window.isKeyWindow
            && !window.isHidden && window.alpha > 0 && AppLockManager.shared.isUnlocked(in: window)
            && owner.canPerformNavigationAction && owner.transitionCoordinator == nil
    }
}
