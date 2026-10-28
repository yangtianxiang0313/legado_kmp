import UIKit
import shared

@MainActor
final class MangaReaderRecoveryActions {
    private weak var presenter: UIViewController?
    private let bookURL: String
    private let adapter: MangaReaderAdapter
    private let detailAdapter: AndroidReplicaBookDetailAdapter
    private let canInteract: () -> Bool
    private let onBusyChange: (Bool) -> Void
    private let onCommitted: (BookDetailRefreshResult, String, [UIViewController]) -> Void
    private let onSuspendForLogin: () -> Void
    private var generation = UUID()
    private var menuRequestID = UUID()
    private var openingID: UUID?
    private var openingTask: Task<Void, Never>?
    private var loginID: UUID?
    private var loginTask: Task<Void, Never>?
    private var pickerBook: Book?
    private var pickerGeneration: UUID?
    private var recoveryToken: UUID?
    private var flushedGeneration: UUID?
    private var flushError: Error?
    private var isPreparing = false
    private var hasCommitted = false

    private lazy var sourceChange: BookDetailSourceChangeActions? = {
        guard let presenter else { return nil }
        let detailAdapter = self.detailAdapter
        let onCommitted = self.onCommitted
        return BookDetailSourceChangeActions(
            presenter: presenter, adapter: detailAdapter,
            currentBook: { [weak self] in self?.currentPickerBook },
            canPresent: { [weak self] in self?.canPresent == true },
            onBusyChange: { [weak self] busy in self?.busyChanged(busy) },
            onCommitted: { [weak self] result, originalURL, targets in
                self?.hasCommitted = true
                self?.generation = UUID()
                self?.pickerBook = nil
                _ = detailAdapter.adoptCommittedSourceChange(replacing: originalURL, bookURL: result.book.bookUrl)
                // The owner publishes once, retires the old adapter and replaces its pushed navigation entry.
                onCommitted(result, originalURL, targets)
            },
            validatePrepared: { [weak self] prepared in
                guard let self else { throw CancellationError() }
                try self.validate(prepared)
            })
    }()

    init(
        presenter: UIViewController,
        bookURL: String,
        adapter: MangaReaderAdapter,
        canInteract: @escaping () -> Bool,
        onBusyChange: @escaping (Bool) -> Void,
        onCommitted: @escaping (BookDetailRefreshResult, String, [UIViewController]) -> Void,
        onSuspendForLogin: @escaping () -> Void
    ) {
        self.presenter = presenter
        self.bookURL = bookURL
        self.adapter = adapter
        detailAdapter = AndroidReplicaBookDetailAdapter(bookURL: bookURL)
        self.canInteract = canInteract
        self.onBusyChange = onBusyChange
        self.onCommitted = onCommitted
        self.onSuspendForLogin = onSuspendForLogin
        detailAdapter.onFlushReadingProgress = { [weak self] in
            guard let self, let token = self.recoveryToken else { return }
            do {
                try await self.adapter.flushForRecovery()
                guard self.recoveryToken == token, self.generation == token else { return }
                self.flushedGeneration = self.adapter.recoveryGeneration
                self.flushError = nil
            } catch {
                guard self.recoveryToken == token else { return }
                self.flushedGeneration = nil
                self.flushError = error
            }
        }
    }

    deinit {
        openingTask?.cancel()
        loginTask?.cancel()
    }

    var isBusy: Bool { isPreparing || openingTask != nil || loginTask != nil }

    private var canLoadMenu: Bool {
        guard !hasCommitted, !adapter.isRetired, adapter.bookURL == bookURL, let presenter,
            canInteract(), !presenter.isBeingPresented, !presenter.isBeingDismissed, !presenter.isMovingFromParent,
            presenter.navigationController?.topViewController === presenter,
            presenter.navigationController?.isBeingDismissed != true,
            let window = presenter.viewIfLoaded?.window, !window.isHidden, window.alpha > 0,
            window.windowScene?.activationState == .foregroundActive,
            UIApplication.shared.applicationState == .active
        else { return false }
        return true
    }

    private var canPresent: Bool {
        canLoadMenu && presenter?.presentedViewController == nil && presenter?.canPerformNavigationAction == true
    }

    private var currentPickerBook: Book? {
        guard !hasCommitted, !adapter.isRetired, adapter.bookURL == bookURL, pickerGeneration == generation else {
            return nil
        }
        return pickerBook
    }

    func menuElements() async -> [UIMenuElement] {
        // Deferred menus may temporarily give their own window key status.
        guard canLoadMenu, !isBusy else { return [] }
        let requestID = UUID()
        menuRequestID = requestID
        let token = generation
        let readerGeneration = adapter.recoveryGeneration
        do {
            guard let book = try await resolveOriginalBook(),
                acceptsMenu(token, readerGeneration: readerGeneration), menuRequestID == requestID
            else { return [] }
            var elements: [UIMenuElement] = [
                UIAction(
                    title: L10n.Reader.bookChangeSource, image: UIImage(systemName: "arrow.triangle.2.circlepath"),
                    identifier: UIAction.Identifier("mangaReader.changeSource")
                ) { [weak self] _ in
                    guard let self, self.canPresent, self.acceptsMenu(token, readerGeneration: readerGeneration)
                    else { return }
                    self.presentSourcePicker()
                }
            ]
            let source = try await detailAdapter.loadMenuSource(expectedBookURL: bookURL)
            guard acceptsMenu(token, readerGeneration: readerGeneration), menuRequestID == requestID else { return [] }
            if let source, source.bookSourceUrl == book.origin, source.hasManagementLoginURL {
                elements.append(
                    UIAction(
                        title: "原书源登录", image: UIImage(systemName: "person.crop.circle"),
                        identifier: UIAction.Identifier("mangaReader.sourceLogin")
                    ) { [weak self] _ in
                        self?.openLogin(sourceURL: source.bookSourceUrl, token: token, readerGeneration: readerGeneration)
                    })
            }
            return elements
        } catch {
            if !(error is CancellationError), acceptsMenu(token, readerGeneration: readerGeneration),
                menuRequestID == requestID, canPresent
            {
                presenter?.showTransientMessage(error.userFacingMessage)
            }
            return []
        }
    }

    func presentSourcePicker() {
        guard canPresent, !isBusy else { return }
        let token = generation
        let readerGeneration = adapter.recoveryGeneration
        let id = UUID()
        openingID = id
        openingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.openingID == id {
                    self.openingTask = nil
                    self.openingID = nil
                }
            }
            do {
                guard let book = try await self.resolveOriginalBook(), !Task.isCancelled,
                    self.openingID == id, self.generation == token,
                    self.adapter.recoveryGeneration == readerGeneration, self.canPresent
                else { return }
                self.pickerBook = book
                self.pickerGeneration = token
                self.sourceChange?.presentPicker()
            } catch {
                if !(error is CancellationError), !Task.isCancelled, self.generation == token, self.canPresent {
                    self.presenter?.showTransientMessage(error.userFacingMessage)
                }
            }
        }
    }

    func cancelPreparation() {
        guard sourceChange?.isCommitting != true else { return }
        // Presenting our own picker does not leave the pushed reader's identity.
        if let presenter, let navigation = presenter.presentedViewController as? ChangeSourceNavigationController,
            navigation.viewControllers.first is ChangeSourceViewController,
            presenter.navigationController?.topViewController === presenter,
            !presenter.isMovingFromParent, !presenter.isBeingDismissed,
            presenter.navigationController?.isBeingDismissed != true
        {
            return
        }
        generation = UUID()
        menuRequestID = UUID()
        openingID = nil
        openingTask?.cancel()
        openingTask = nil
        loginID = nil
        loginTask?.cancel()
        loginTask = nil
        sourceChange?.cancelPreparation()
    }

    private func resolveOriginalBook() async throws -> Book? {
        try detailAdapter.bootstrap().get()
        // Resolve persisted identity even when the very first chapter request failed.
        guard let book = try await detailAdapter.resolveInitialBook(), book.bookUrl == bookURL,
            !book.isLocal, book.isImage, !book.origin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        if let chapter = adapter.chapter, chapter.book.origin != book.origin { throw CancellationError() }
        return book
    }

    private func acceptsMenu(_ token: UUID, readerGeneration: UUID) -> Bool {
        !Task.isCancelled && generation == token && adapter.recoveryGeneration == readerGeneration && canLoadMenu && !isBusy
    }

    private func openLogin(sourceURL: String, token: UUID, readerGeneration: UUID) {
        guard canPresent, acceptsMenu(token, readerGeneration: readerGeneration) else { return }
        let id = UUID()
        loginID = id
        loginTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.loginID == id {
                    self.loginID = nil
                    self.loginTask = nil
                }
            }
            do {
                guard let book = try await self.resolveOriginalBook(), book.origin == sourceURL,
                    let source = try await self.detailAdapter.loadMenuSource(expectedBookURL: self.bookURL),
                    source.bookSourceUrl == sourceURL, source.hasManagementLoginURL,
                    !Task.isCancelled, self.loginID == id, self.generation == token,
                    self.adapter.recoveryGeneration == readerGeneration, self.canPresent, let presenter = self.presenter
                else { return }
                SourceLoginEntry.open(sourceURL: sourceURL, from: presenter)
                if presenter.presentedViewController != nil {
                    self.generation = UUID()
                    // Never replay a request made with the old cookies; refresh belongs to the reader.
                    self.onSuspendForLogin()
                }
            } catch {
                if !(error is CancellationError), !Task.isCancelled, self.generation == token, self.canPresent {
                    self.presenter?.showTransientMessage(error.userFacingMessage)
                }
            }
        }
    }

    private func busyChanged(_ busy: Bool) {
        isPreparing = busy
        flushedGeneration = nil
        flushError = nil
        if busy {
            generation = UUID()
            pickerGeneration = generation
            recoveryToken = generation
        } else {
            recoveryToken = nil
        }
        // The owner stops loading, prefetch and progress recording, or restores after cancellation.
        onBusyChange(busy)
    }

    private func validate(_ prepared: PreparedBookSourceChange) throws {
        guard prepared.book.isImage else {
            throw NSError(
                domain: "io.legado.manga", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "所选择的源不是漫画源"])
        }
        if let flushError { throw flushError }
        try Task.checkCancellation()
        guard isPreparing, recoveryToken == generation, currentPickerBook != nil,
            prepared.originalBookUrl == bookURL, !prepared.book.isLocal,
            flushedGeneration == adapter.recoveryGeneration
        else { throw CancellationError() }
    }
}
