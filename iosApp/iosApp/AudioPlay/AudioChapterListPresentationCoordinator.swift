import UIKit
import shared

@MainActor
final class AudioChapterListPresentationCoordinator: NSObject {
    private struct Identity {
        let bookURL: String
        let origin: String
    }

    private let session: AudioPlaybackSession
    private let canPresent: () -> Bool
    private weak var presenter: UIViewController?
    private weak var window: UIWindow?
    private weak var chapterList: AndroidChapterListSheetViewController?
    private var identity: Identity?
    private var catalogIdentity: UUID?
    private var requestID: UUID?
    private var taskID: UUID?
    private var task: Task<Void, Never>?

    init(session: AudioPlaybackSession, canPresent: @escaping () -> Bool = { true }) {
        self.session = session
        self.canPresent = canPresent
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(sessionDidChange), name: AudioPlaybackSession.didChange, object: session)
        NotificationCenter.default.addObserver(
            self, selector: #selector(cancelPendingPresentation), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(sceneWillDeactivate(_:)), name: UIScene.willDeactivateNotification, object: nil)
    }

    deinit {
        task?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    func cancel() {
        requestID = nil
        identity = nil
        catalogIdentity = nil
        presenter = nil
        window = nil
        // Cancellation may not stop the shared call immediately; retain its single flight until it settles.
        task?.cancel()
        let list = chapterList
        chapterList = nil
        if let list, !list.isBeingPresented, !list.isBeingDismissed, !list.isMovingFromParent {
            ChapterListNavigation.close(list, completion: {})
        }
    }

    func present(in presenter: UIViewController, bookURL: String) {
        guard task == nil, chapterList == nil,
            !bookURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            session.bookURL == bookURL, let book = session.book, book.bookUrl == bookURL,
            let window = presenter.viewIfLoaded?.window, canInteract(in: presenter, window: window)
        else { return }
        cancel()
        let identity = Identity(bookURL: bookURL, origin: book.origin)
        let requestID = UUID()
        let taskID = UUID()
        self.identity = identity
        self.requestID = requestID
        self.taskID = taskID
        self.presenter = presenter
        self.window = window
        task = Task { @MainActor [weak self, weak presenter, weak window, session] in
            defer { self?.finishTask(taskID, requestID: requestID) }
            do {
                try Task.checkCancellation()
                let snapshot = try await session.loadCatalogSnapshot()
                guard let self, let presenter, let window,
                    self.isCurrent(requestID, identity: identity, presenter: presenter, window: window),
                    snapshot.book.bookUrl == identity.bookURL, snapshot.book.origin == identity.origin,
                    session.isCatalogCurrent(bookURL: identity.bookURL, origin: identity.origin, identity: snapshot.identity),
                    snapshot.items.allSatisfy({ $0.chapter.bookUrl == identity.bookURL })
                else { return }
                guard !snapshot.items.isEmpty else {
                    presenter.showTransientMessage(L10n.BookDetail.emptyChapters)
                    return
                }
                let catalogIdentity = snapshot.identity
                self.catalogIdentity = catalogIdentity
                let list = AndroidChapterListSheetViewController(
                    items: snapshot.items, book: snapshot.book, bookURL: identity.bookURL,
                    onSelect: { [weak self, weak presenter, weak window] index in
                        guard let presenter, let window else { return }
                        self?.select(
                            index, position: 0, requestID: requestID, identity: identity,
                            catalogIdentity: catalogIdentity, presenter: presenter, window: window)
                    },
                    onSelectPosition: { [weak self, weak presenter, weak window] index, position in
                        guard let presenter, let window else { return }
                        self?.select(
                            index, position: position, requestID: requestID, identity: identity,
                            catalogIdentity: catalogIdentity, presenter: presenter, window: window)
                    },
                    onRefresh: nil)
                list.modalPresentationStyle = .fullScreen
                self.chapterList = list
                presenter.present(list, animated: true) { [weak self, weak list] in
                    guard let list, self?.requestID != requestID,
                        !list.isBeingDismissed, !list.isMovingFromParent
                    else { return }
                    ChapterListNavigation.close(list, completion: {})
                }
            } catch {
                guard !(error is CancellationError), let self, let presenter, let window,
                    self.isCurrent(requestID, identity: identity, presenter: presenter, window: window)
                else { return }
                presenter.showTransientMessage(error.userFacingMessage)
            }
        }
    }

    private func select(
        _ index: Int, position: Int, requestID: UUID, identity: Identity,
        catalogIdentity: UUID, presenter: UIViewController, window: UIWindow
    ) {
        // Both TOC callbacks run after ChapterListNavigation has completed its pop or dismissal.
        guard task == nil, self.requestID == requestID, self.catalogIdentity == catalogIdentity,
            matches(identity), canPresent()
        else { return }
        chapterList = nil
        let taskID = UUID()
        self.taskID = taskID
        task = Task { @MainActor [weak self, weak presenter, weak window, session] in
            defer { self?.finishTask(taskID, requestID: requestID) }
            // Let UIKit detach its dismissal transition before requiring the player to own interaction again.
            await Task.yield()
            guard let self, let presenter, let window,
                self.isCurrent(requestID, identity: identity, presenter: presenter, window: window)
            else { return }
            do {
                try await session.selectCatalogChapter(
                    index, position: position, bookURL: identity.bookURL, origin: identity.origin, identity: catalogIdentity)
            } catch {
                guard !(error is CancellationError),
                    self.isCurrent(requestID, identity: identity, presenter: presenter, window: window)
                else { return }
                presenter.showTransientMessage(error.userFacingMessage)
            }
        }
    }

    private func finishTask(_ taskID: UUID, requestID: UUID) {
        guard self.taskID == taskID else { return }
        self.taskID = nil
        task = nil
        if self.requestID == requestID, chapterList == nil {
            self.requestID = nil
            identity = nil
            catalogIdentity = nil
            presenter = nil
            window = nil
        }
    }

    private func isCurrent(
        _ requestID: UUID, identity: Identity, presenter: UIViewController, window: UIWindow
    ) -> Bool {
        !Task.isCancelled && self.requestID == requestID && self.presenter === presenter && self.window === window
            && matches(identity) && canInteract(in: presenter, window: window)
    }

    private func matches(_ identity: Identity) -> Bool {
        guard !session.isChangingSource, session.bookURL == identity.bookURL,
            session.book?.bookUrl == identity.bookURL, session.book?.origin == identity.origin
        else { return false }
        guard let catalogIdentity else { return true }
        return session.isCatalogCurrent(bookURL: identity.bookURL, origin: identity.origin, identity: catalogIdentity)
    }

    private func canInteract(in presenter: UIViewController, window: UIWindow) -> Bool {
        guard canPresent(), !session.isChangingSource,
            UIApplication.shared.applicationState == .active, window.isKeyWindow, !window.isHidden, window.alpha > 0,
            window.windowScene?.activationState == .foregroundActive,
            presenter.viewIfLoaded?.window === window, presenter.viewIfLoaded?.isHidden == false,
            (presenter.viewIfLoaded?.alpha ?? 0) > 0,
            !presenter.isBeingPresented, !presenter.isBeingDismissed, !presenter.isMovingFromParent,
            presenter.presentedViewController == nil, presenter.transitionCoordinator == nil
        else { return false }
        return presenter.navigationController == nil || presenter.canPerformNavigationAction
    }

    @objc private func sessionDidChange() {
        guard let identity else { return }
        if !matches(identity) || !canPresent() { cancel() }
    }

    @objc private func cancelPendingPresentation() {
        if task != nil || chapterList == nil || chapterList?.isBeingDismissed == true
            || chapterList?.isMovingFromParent == true
        {
            cancel()
        }
    }

    @objc private func sceneWillDeactivate(_ notification: Notification) {
        guard let scene = notification.object as? UIScene, scene === window?.windowScene else { return }
        cancelPendingPresentation()
    }
}
