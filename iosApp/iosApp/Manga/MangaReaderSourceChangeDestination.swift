import UIKit
import shared

@MainActor
final class MangaReaderSourceChangeDestination {
    private weak var owner: UIViewController?
    private weak var navigation: UINavigationController?
    private weak var window: UIWindow?
    private weak var scene: UIWindowScene?
    private let adapter: MangaReaderAdapter
    private var book: Book?
    private var retirement: Task<Void, Never>?
    private var isRetired = false
    private(set) var isPending = false

    init(owner: UIViewController, adapter: MangaReaderAdapter) {
        self.owner = owner
        self.adapter = adapter
    }

    func committed(_ result: BookDetailRefreshResult, replacing originalURL: String, targets: [UIViewController]) {
        guard !isPending, originalURL == adapter.bookURL, let owner else { return }
        isPending = true
        book = result.book
        navigation = owner.navigationController
        window = owner.viewIfLoaded?.window ?? navigation?.viewIfLoaded?.window
        scene = window?.windowScene
        BookSourceChangeNavigation.publish(result, replacing: originalURL, to: targets, excluding: owner)
        retirement = Task { [self] in
            await adapter.retireAfterSourceChange()
            isRetired = true
            retirement = nil
            navigateIfNeeded()
        }
    }

    func navigateIfNeeded() {
        guard isPending, isRetired, adapter.isRetired, let book, book.isImage,
            !book.bookUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let owner, let navigation, let window, let scene,
            owner.navigationController === navigation, navigation.viewIfLoaded?.window === window,
            let ownerIndex = navigation.viewControllers.firstIndex(where: { $0 === owner }),
            !navigation.isBeingPresented, !navigation.isBeingDismissed,
            !navigation.isMovingFromParent, !navigation.isMovingToParent, navigation.transitionCoordinator == nil,
            window.windowScene === scene, window.isKeyWindow, !window.isHidden, window.alpha > 0,
            owner.presentedViewController == nil, !owner.isBeingDismissed, !owner.isMovingFromParent,
            !owner.isBeingPresented, !owner.isMovingToParent,
            UIApplication.shared.applicationState == .active,
            scene.activationState == .foregroundActive,
            AppLockManager.shared.isUnlocked(in: window)
        else { return }
        var stack = navigation.viewControllers
        if navigation.topViewController === owner {
            guard owner.viewIfLoaded?.window === window, owner.transitionCoordinator == nil,
                owner.canPerformNavigationAction
            else { return }
        } else {
            // Only repair the hidden reader directly below its newly adopted detail; never pop that detail.
            guard ownerIndex == stack.count - 2,
                let detail = stack.last as? AndroidReplicaBookDetailViewController, detail.bookURL == book.bookUrl,
                detail.navigationController === navigation, detail.viewIfLoaded?.window === window,
                !detail.isBeingPresented, !detail.isBeingDismissed,
                !detail.isMovingFromParent, !detail.isMovingToParent, detail.transitionCoordinator == nil,
                detail.presentedViewController == nil, detail.canPerformNavigationAction,
                owner.viewIfLoaded?.window == nil || owner.viewIfLoaded?.window === window
            else { return }
        }
        let destination = MangaReaderViewController(
            bookURL: book.bookUrl, initialChapterIndex: Int(book.durChapterIndex),
            initialChapterPosition: Int(book.durChapterPos))
        stack[ownerIndex] = destination.configuredForDrillDownPresentation()
        self.book = nil
        navigation.setViewControllers(stack, animated: false)
    }
}
