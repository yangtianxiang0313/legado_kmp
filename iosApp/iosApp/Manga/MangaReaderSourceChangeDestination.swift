import UIKit
import shared

@MainActor
final class MangaReaderSourceChangeDestination {
    private weak var owner: UIViewController?
    private weak var navigation: UINavigationController?
    private weak var window: UIWindow?
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
        guard !isPending, let owner else { return }
        isPending = true
        book = result.book
        navigation = owner.navigationController
        window = owner.viewIfLoaded?.window
        BookSourceChangeNavigation.publish(result, replacing: originalURL, to: targets, excluding: owner)
        retirement = Task { [self] in
            await adapter.retireAfterSourceChange()
            isRetired = true
            retirement = nil
            navigateIfNeeded()
        }
    }

    func navigateIfNeeded() {
        guard isPending, isRetired, let book, let owner, let navigation, let window,
            owner.navigationController === navigation, navigation.topViewController === owner,
            owner.viewIfLoaded?.window === window, window.isKeyWindow,
            owner.presentedViewController == nil, !owner.isBeingDismissed, !owner.isMovingFromParent,
            owner.transitionCoordinator == nil, owner.canPerformNavigationAction,
            UIApplication.shared.applicationState == .active,
            window.windowScene?.activationState == .foregroundActive,
            AppLockManager.shared.isUnlocked(in: window)
        else { return }
        let destination = MangaReaderViewController(
            bookURL: book.bookUrl, initialChapterIndex: Int(book.durChapterIndex),
            initialChapterPosition: Int(book.durChapterPos))
        var stack = navigation.viewControllers
        guard stack.last === owner else { return }
        stack[stack.count - 1] = destination.configuredForDrillDownPresentation()
        self.book = nil
        navigation.setViewControllers(stack, animated: false)
    }
}
