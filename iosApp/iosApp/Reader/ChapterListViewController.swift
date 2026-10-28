import shared
import UIKit

/// BookInfoActivity and ReadBookActivity both use TocActivity at Legado 5f5d314.
final class ChapterListViewController: AndroidChapterListSheetViewController {
    init(
        items: [ReaderChapterListItem],
        bookURL: String? = nil,
        bookmarkProvider: ReaderBookmarkListProviding? = nil,
        onSelect: @escaping (Int) -> Void
    ) {
        let resolvedURL = ([bookURL].compactMap { $0 } + items.map { $0.chapter.bookUrl })
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        let reloadTitles: (() async throws -> [ReaderChapterListItem])?
        let reverseChapters: (() async throws -> [ReaderChapterListItem])?
        if let resolvedURL {
            reloadTitles = {
                try await SharedRuntime.readerFacade().get().loadChapterListStateAsync(bookUrl: resolvedURL)
            }
            reverseChapters = {
                let facade = try SharedRuntime.readerFacade().get()
                let result = try await facade.reverseChapterList(bookUrl: resolvedURL)
                if let items = try? await facade.loadChapterListStateAsync(bookUrl: resolvedURL) { return items }
                // A committed reorder must remain usable even if reloading display titles fails.
                return result.chapters.map { chapter in
                    ReaderChapterListItem(
                        chapter: chapter, displayTitle: chapter.title,
                        isCurrent: chapter.index == result.book.durChapterIndex,
                        isCached: result.book.isLocal || chapter.isVolume)
                }
            }
        } else {
            reloadTitles = nil
            reverseChapters = nil
        }
        super.init(
            items: items, bookURL: resolvedURL, bookmarkProvider: bookmarkProvider, onSelect: onSelect,
            onRefresh: nil, onReverse: reverseChapters, onReloadTitles: reloadTitles)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }
}

enum ChapterListNavigation {
    static func close(_ controller: UIViewController, completion: @escaping () -> Void) {
        if let navigation = controller.navigationController,
            navigation.topViewController === controller, navigation.viewControllers.first !== controller
        {
            navigation.popViewController(animated: true)
            if let transition = navigation.transitionCoordinator {
                transition.animate(alongsideTransition: nil) { context in
                    if !context.isCancelled { completion() }
                }
            } else {
                DispatchQueue.main.async(execute: completion)
            }
        } else if controller.presentingViewController != nil
            || controller.navigationController?.presentingViewController != nil
        {
            controller.dismiss(animated: true, completion: completion)
        } else {
            completion()
        }
    }
}
