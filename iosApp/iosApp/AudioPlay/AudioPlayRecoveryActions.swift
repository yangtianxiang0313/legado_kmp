import UIKit
import shared

@MainActor
final class AudioPlayRecoveryActions {
    private weak var presenter: UIViewController?
    private weak var returnOwner: UIViewController?
    private let bookURL: String
    private let session: AudioPlaybackSession
    private let adapter: AndroidReplicaBookDetailAdapter
    private let onLeaving: () -> Void
    private var recoveryToken: UUID?
    private var isPreparing = false
    private var returnTargets: [UIViewController] = []
    private var destination: (book: Book, generation: UUID)?

    private lazy var sourceChange: BookDetailSourceChangeActions? = {
        guard let presenter else { return nil }
        return BookDetailSourceChangeActions(
            presenter: presenter, adapter: adapter,
            currentBook: { [weak self] in self?.currentBook },
            canPresent: { [weak self] in self?.canInteract == true },
            onBusyChange: { [weak self] busy in self?.sourceChangeBusyChanged(busy) },
            onCommitted: { [weak self] result, originalURL, targets in
                self?.sourceChangeCommitted(result, replacing: originalURL, targets: targets)
            })
    }()

    init(presenter: UIViewController, bookURL: String, session: AudioPlaybackSession, onLeaving: @escaping () -> Void) {
        self.presenter = presenter
        self.bookURL = bookURL
        self.session = session
        self.adapter = AndroidReplicaBookDetailAdapter(bookURL: bookURL)
        self.onLeaving = onLeaving
        adapter.onFlushReadingProgress = { [weak self] in
            guard let self, let token = self.recoveryToken else { return }
            await self.session.flushSourceChange(token)
        }
    }

    var isBusy: Bool { isPreparing }

    private var currentBook: Book? {
        guard session.bookURL == bookURL, destination == nil else { return nil }
        if isPreparing {
            guard let recoveryToken, session.isSourceChangeCurrent(recoveryToken) else { return nil }
        }
        return session.book
    }

    private var canInteract: Bool {
        guard canLoadMenu, let presenter, presenter.presentedViewController == nil,
            presenter.viewIfLoaded?.window?.isKeyWindow == true
        else { return false }
        return presenter.navigationController == nil || presenter.canPerformNavigationAction
    }

    private var canLoadMenu: Bool {
        guard let presenter, session.bookURL == bookURL, destination == nil,
            !presenter.isBeingPresented, !presenter.isBeingDismissed, !presenter.isMovingFromParent,
            let window = presenter.viewIfLoaded?.window, !window.isHidden,
            window.windowScene?.activationState == .foregroundActive,
            UIApplication.shared.applicationState == .active
        else { return false }
        return presenter.navigationController.map { $0.topViewController === presenter } ?? true
    }

    func menuElements() async -> [UIMenuElement] {
        // UIKit's context-menu presentation can temporarily own the key window during deferred loading.
        guard canLoadMenu, !isBusy else { return [] }
        let token = session.recoveryGeneration
        var items: [UIMenuElement] = [
            UIAction(
                title: "重试当前章节", image: UIImage(systemName: "arrow.clockwise"),
                identifier: UIAction.Identifier("audioPlay.retry")
            ) { [weak self] _ in
                guard let self, self.canInteract, !self.isBusy, self.session.recoveryGeneration == token else { return }
                self.session.retry()
            }
        ]
        guard let book = currentBook, !book.isLocal else { return items }
        do {
            try adapter.bootstrap().get()
            let source = try await adapter.loadMenuSource(expectedBookURL: bookURL)
            guard !Task.isCancelled, canLoadMenu, session.recoveryGeneration == token,
                currentBook?.origin == book.origin
            else { return [] }
            if let source, source.bookSourceUrl == book.origin, source.hasManagementLoginURL {
                items.append(
                    UIAction(
                        title: "原书源登录", image: UIImage(systemName: "person.crop.circle"),
                        identifier: UIAction.Identifier("audioPlay.sourceLogin")
                    ) { [weak self] _ in
                        self?.openLogin(sourceURL: source.bookSourceUrl, generation: token)
                    })
            }
        } catch {
            if canInteract, session.recoveryGeneration == token { presenter?.showTransientMessage(error.userFacingMessage) }
        }
        return items
    }

    private func openLogin(sourceURL: String, generation: UUID) {
        guard canInteract, !isBusy, session.recoveryGeneration == generation,
            currentBook?.origin == sourceURL, let presenter
        else { return }
        SourceLoginEntry.open(sourceURL: sourceURL, from: presenter)
        if presenter.presentedViewController != nil {
            // Login never replays a cached pre-login request; the consumer explicitly retries.
            session.suspendForLogin(bookURL: bookURL, generation: generation)
        }
    }

    func presentSourcePicker() {
        guard canInteract, !isBusy, let book = currentBook, !book.isLocal, let presenter else { return }
        guard let owner = readingOwner(of: presenter), owner.navigationController != nil else {
            presenter.showTransientMessage("当前无法打开换源结果")
            return
        }
        do {
            try adapter.bootstrap().get()
            returnOwner = owner
            returnTargets = owner.navigationController?.viewControllers ?? []
            sourceChange?.presentPicker()
        } catch {
            presenter.showTransientMessage(error.userFacingMessage)
        }
    }

    func cancelPreparation() {
        guard isPreparing else { return }
        sourceChange?.cancelPreparation()
    }

    private func sourceChangeBusyChanged(_ busy: Bool) {
        isPreparing = busy
        if busy {
            recoveryToken = session.suspendForSourceChange(bookURL: bookURL)
        } else {
            if let token = recoveryToken, destination == nil { session.restoreSourceChange(token) }
            recoveryToken = nil
            navigateIfNeeded()
        }
    }

    private func sourceChangeCommitted(
        _ result: BookDetailRefreshResult, replacing originalURL: String,
        targets: [UIViewController]
    ) {
        if let token = recoveryToken, session.completeSourceChange(token) {
            destination = (result.book, session.recoveryGeneration)
        }
        _ = adapter.adoptCommittedSourceChange(replacing: originalURL, bookURL: result.book.bookUrl)
        var seen = Set<ObjectIdentifier>()
        let receivers = (returnTargets + targets).filter { seen.insert(ObjectIdentifier($0)).inserted }
        BookSourceChangeNavigation.publish(result, replacing: originalURL, to: receivers, excluding: presenter)
    }

    func navigateIfNeeded() {
        guard !isPreparing, let destination, let presenter, let owner = returnOwner,
            session.bookURL == nil, session.recoveryGeneration == destination.generation,
            presenter.presentedViewController == nil, presenter.presentingViewController != nil,
            !presenter.isBeingDismissed, !owner.isBeingDismissed, !owner.isMovingFromParent,
            owner.navigationController?.topViewController === owner,
            UIApplication.shared.applicationState == .active,
            presenter.viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive
        else { return }
        self.destination = nil
        onLeaving()
        // onBusyChange(false) runs after the shared coordinator has detached its picker.
        presenter.dismiss(animated: true) { [weak owner] in
            DispatchQueue.main.async {
                guard let owner else { return }
                BookReadingDestination.open(destination.book, from: owner)
            }
        }
    }

    private func readingOwner(of presenter: UIViewController) -> UIViewController? {
        var owner = presenter.presentingViewController
        while let current = owner {
            if let navigation = current as? UINavigationController {
                owner = navigation.topViewController
            } else if let tabs = current as? UITabBarController {
                owner = tabs.selectedViewController
            } else {
                return current
            }
        }
        return nil
    }
}
