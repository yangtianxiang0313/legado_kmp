import UIKit
import shared

@MainActor
enum ReaderBookmarkCreationCoordinator {
    static func present(
        in reader: ReaderContainerViewController,
        chapterIndex: Int,
        chapterPosition: Int,
        text: String,
        trimsText: Bool
    ) {
        guard reader.presentedViewController == nil, !reader.isBeingDismissed,
            !reader.isMovingFromParent, reader.viewIfLoaded?.window != nil
        else { return }
        guard let book = reader.book, book.bookUrl == reader.bookURL,
            reader.chapters.indices.contains(chapterIndex), chapterPosition >= 0,
            let index = Int32(exactly: chapterIndex), let position = Int32(exactly: chapterPosition)
        else {
            reader.showToast(L10n.Reader.unavailable)
            return
        }

        // Snapshot the location before opening the editor. Saving must not move the reader's progress.
        let draft = Bookmark(
            time: Int64(Date().timeIntervalSince1970 * 1000),
            bookName: book.name,
            bookAuthor: book.author,
            chapterIndex: index,
            chapterPos: position,
            chapterName: reader.chapterTitle,
            bookText: trimsText ? text.trimmingCharacters(in: .whitespacesAndNewlines) : text,
            content: ""
        )
        let bookURL = book.bookUrl
        let origin = book.origin
        let screen = reader.screen
        let editor = ReaderTocBookmarkEditorViewController(
            bookmark: draft,
            onSave: { bookText, note in
                let bookmark = ReaderTocBookmarkEditCoordinator.updatedBookmark(
                    draft, bookText: bookText, content: note)
                try await screen.updateBookmark(bookmark)
            })
        // Validate before acceptance; the accepted write keeps the original draft even if the reader leaves.
        editor.canSubmit = { [weak reader] in
            guard let reader else { return false }
            return reader.bookURL == bookURL && reader.book?.bookUrl == bookURL
                && reader.book?.origin == origin
        }
        editor.overrideUserInterfaceStyle = reader.readMenu.overflowInterfaceStyle
        reader.setMenuVisible(false)
        reader.present(editor, animated: true)
    }
}

/// A bookmark editor is single-use; losing its UI never cancels an accepted persistence operation.
@MainActor
final class ReaderBookmarkEditorPresentation: NSObject {
    var onChange: (() -> Void)?
    private(set) var generation = UUID()
    private(set) var isRetired = false
    private weak var editor: UIViewController?
    private weak var sourcePresenter: UIViewController?
    private weak var sourceController: UIViewController?
    private weak var sourceWindow: UIWindow?
    private weak var sourceScene: UIWindowScene?
    private weak var sourceRootController: UIViewController?
    private var hasBoundSource = false
    private var isVisible = false
    private var isForegroundSuspended = false
    private var refreshTimer: Timer?

    init(editor: UIViewController) {
        self.editor = editor
        super.init()
        for name in [
            UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
            UIApplication.didBecomeActiveNotification, UIScene.willDeactivateNotification,
            UIScene.didEnterBackgroundNotification, UIScene.didActivateNotification,
            UIWindow.didResignKeyNotification, UIWindow.didBecomeKeyNotification,
            UIWindow.didBecomeHiddenNotification,
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(activationChanged(_:)), name: name, object: nil)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func bindSourceIfNeeded() {
        guard !hasBoundSource, !isRetired, let presenter = editor?.presentingViewController else { return }
        hasBoundSource = true
        sourcePresenter = presenter
        sourceController = currentSource(from: presenter)
        sourceWindow = presenter.viewIfLoaded?.window
        sourceScene = sourceWindow?.windowScene
        sourceRootController = sourceWindow?.rootViewController
    }

    func didAppear() {
        guard !isRetired else { return }
        isVisible = true
        refreshTimer?.invalidate()
        let timer = Timer(
            timeInterval: 0.1, target: RefreshTarget(owner: self),
            selector: #selector(RefreshTarget.tick(_:)), userInfo: nil, repeats: true)
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        refresh()
    }

    func willDisappear() {
        isVisible = false
        revokeDelivery()
        refreshTimer?.invalidate()
        refreshTimer = nil
        onChange?()
    }

    func didDisappear() {
        if editor?.presentingViewController == nil || isPresentationBeingRemoved { retire() }
    }

    func revokeDelivery() {
        generation = UUID()
    }

    func retire() {
        guard !isRetired else { return }
        isRetired = true
        isVisible = false
        revokeDelivery()
        refreshTimer?.invalidate()
        refreshTimer = nil
        NotificationCenter.default.removeObserver(self)
    }

    var isCurrent: Bool {
        guard hasBoundSource, !isRetired, isVisible, !isForegroundSuspended,
            UIApplication.shared.applicationState == .active,
            let editor, !editor.isBeingPresented, !editor.isBeingDismissed,
            !editor.isMovingFromParent, !editor.isMovingToParent,
            editor.presentedViewController == nil,
            let presenter = sourcePresenter, editor.presentingViewController === presenter,
            presenter.presentedViewController === editor,
            let source = sourceController, currentSource(from: presenter) === source,
            let window = sourceWindow, !window.isHidden, window.alpha > 0, window.isKeyWindow,
            let scene = sourceScene, window.windowScene === scene, scene.activationState == .foregroundActive,
            let root = sourceRootController, window.rootViewController === root,
            editor.viewIfLoaded?.window === window, presenter.viewIfLoaded?.window === window,
            source.viewIfLoaded?.window === window
        else { return false }

        var current: UIViewController? = source
        var expectedPresentation: UIViewController?
        var includesPresenter = false
        var lastController: UIViewController?
        while let controller = current {
            if controller === presenter { includesPresenter = true }
            guard !controller.isBeingPresented, !controller.isBeingDismissed,
                !controller.isMovingFromParent, !controller.isMovingToParent
            else { return false }
            if let presented = controller.presentedViewController,
                presented !== expectedPresentation, presented !== editor
            {
                return false
            }
            if let navigation = controller.parent as? UINavigationController,
                navigation.topViewController !== controller
            {
                return false
            }
            if let tabs = controller.parent as? UITabBarController, tabs.selectedViewController !== controller {
                return false
            }
            lastController = controller
            if let parent = controller.parent {
                expectedPresentation = nil
                current = parent
            } else {
                expectedPresentation = controller
                current = controller.presentingViewController
            }
        }
        return includesPresenter && lastController === root
    }

    private var isPresentationBeingRemoved: Bool {
        var current = editor
        while let controller = current {
            if controller.isBeingDismissed || controller.isMovingFromParent { return true }
            current = controller.parent ?? controller.presentingViewController
        }
        return false
    }

    private func currentSource(from presenter: UIViewController) -> UIViewController {
        var source = presenter
        while true {
            if let navigation = source as? UINavigationController, let top = navigation.topViewController {
                source = top
            } else if let tabs = source as? UITabBarController, let selected = tabs.selectedViewController {
                source = selected
            } else {
                return source
            }
        }
    }

    func refresh() {
        guard !isRetired else { return }
        if hasBoundSource, editor?.presentingViewController == nil {
            retire()
        } else if !isCurrent {
            revokeDelivery()
        }
        onChange?()
    }

    @objc private func activationChanged(_ notification: Notification) {
        if let scene = notification.object as? UIScene, scene !== sourceScene { return }
        if let window = notification.object as? UIWindow, window !== sourceWindow { return }
        switch notification.name {
        case UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
            UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification:
            isForegroundSuspended = true
            revokeDelivery()
        case UIApplication.didBecomeActiveNotification, UIScene.didActivateNotification:
            isForegroundSuspended = false
        case UIWindow.didResignKeyNotification, UIWindow.didBecomeHiddenNotification:
            revokeDelivery()
        default:
            break
        }
        refresh()
    }

    @MainActor
    private final class RefreshTarget: NSObject {
        weak var owner: ReaderBookmarkEditorPresentation?

        init(owner: ReaderBookmarkEditorPresentation) { self.owner = owner }

        @objc func tick(_ timer: Timer) {
            guard let owner else {
                timer.invalidate()
                return
            }
            owner.refresh()
        }
    }
}
