import UIKit
import shared

@MainActor
enum StartupBookshelfDestination {
    static func select(in home: MainTabBarController) -> UIViewController? {
        home.selectBookshelfForStartup()
    }

    static func selectedBookshelf(in home: MainTabBarController) -> UIViewController? {
        home.children.first { $0 is AndroidReplicaBookshelfViewController }
    }

    static func open(_ payload: ReaderChapterPayload, from home: MainTabBarController) {
        guard home.canPerformNavigationAction, let navigation = home.navigationController,
            navigation.viewControllers.count == 1, navigation.topViewController === home,
            selectedBookshelf(in: home) != nil
        else { return }
        if payload.book.isImage || (payload.book.isLocal && payload.book.bookUrl.lowercased().hasSuffix(".pdf")) {
            BookReadingDestination.open(payload.book, from: home)
            return
        }
        let reader = ReaderContainerViewController(
            bookURL: payload.book.bookUrl, initialChapterIndex: Int(payload.chapter.index))
        reader.isInBookshelf = true
        _ = reader.configuredForDrillDownPresentation()
        navigation.pushViewController(reader, animated: false)
        reader.loadViewIfNeeded()
        // viewDidLoad schedules the usual chapter task. Adopt the already prepared payload in this
        // same main-actor turn, before that task can start another request or save a stale position.
        reader.chapterLoadCoordinator.cancel(in: reader)
        reader.applyPayload(payload, restorePosition: nil)
    }

}
