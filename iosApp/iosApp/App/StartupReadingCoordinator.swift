import UIKit
import shared

/// A scene gets one launcher-only attempt, after both runtime startup and app-lock dismissal.
@MainActor
final class StartupReadingCoordinator {
    private weak var window: UIWindow?
    private weak var navigation: UINavigationController?
    private weak var home: MainTabBarController?
    private var isUnlocked = false
    private var isFinished = false
    private var requestID: UUID?
    private var task: Task<Void, Never>?

    deinit { task?.cancel() }

    func runtimeDidBecomeReady(window: UIWindow, navigation: UINavigationController, home: MainTabBarController) {
        guard !isFinished else { return }
        self.window = window
        self.navigation = navigation
        self.home = home
        home.onStartupNavigationReady = { [weak self] in self?.resumeIfPossible() }
        if !StartupReadingPreferences.isEnabled { cancel() }
    }

    func appDidUnlock() {
        isUnlocked = true
        resumeIfPossible()
    }

    func resumeIfPossible() {
        guard !isFinished, isUnlocked, task == nil, let window,
            SharedRuntime.startupState == .ready,
            UIApplication.shared.applicationState == .active,
            window.windowScene?.activationState == .foregroundActive,
            home?.isReadyForStartupNavigation == true
        else { return }
        guard StartupReadingPreferences.isEnabled else {
            cancel()
            return
        }
        let id = UUID()
        requestID = id
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.requestID == id {
                    self.isFinished = true
                    self.home?.onStartupNavigationReady = nil
                    self.requestID = nil
                    self.task = nil
                }
            }
            do {
                guard let home = self.home else { return }
                var bookshelf: UIViewController?
                // The first scene activation may precede the home container's viewDidAppear.
                // Wait only for that initial appearance; any other navigation cancels this attempt.
                for _ in 0..<20 {
                    guard self.canNavigate(id) else { return }
                    if let selected = StartupBookshelfDestination.select(in: home) {
                        bookshelf = selected
                        break
                    }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                guard let bookshelf else { return }
                let facade = try SharedRuntime.bookshelfFacade().get()
                let books = try await facade.loadBooksAsync(groupId: BookGroup.companion.ID_ALL)
                guard self.accepts(id, bookshelf: bookshelf), let book = Self.lastReadBook(in: books),
                    book.durChapterIndex >= 0, book.durChapterPos >= 0
                else { return }
                let readerFacade = try SharedRuntime.readerFacade().get()
                let payload = try await Self.prepare(book, using: readerFacade)
                guard self.accepts(id, bookshelf: bookshelf), Self.canResume(payload, book: book) else { return }

                // Preparation can suspend for I/O. Never replace newer saved progress, a removed book,
                // or a new last-read selection with the snapshot that started this request.
                let currentBooks = try await facade.loadBooksAsync(groupId: BookGroup.companion.ID_ALL)
                guard self.accepts(id, bookshelf: bookshelf),
                    let current = Self.lastReadBook(in: currentBooks), Self.sameReadingContext(book, current)
                else { return }
                self.isFinished = true
                StartupBookshelfDestination.open(payload, from: home)
            } catch is CancellationError {
            } catch {
                guard self.canNavigate(id) else { return }
                SharedRuntime.log("Startup reading failed; keeping bookshelf: \(error.localizedDescription)")
            }
        }
    }

    func sceneBecameInactive() {
        // Do not defer an interrupted automatic navigation until a later foreground visit.
        if task != nil { cancel() }
    }

    func cancel() {
        isFinished = true
        requestID = nil
        task?.cancel()
        task = nil
        home?.onStartupNavigationReady = nil
    }

    private func canNavigate(_ id: UUID) -> Bool {
        guard !isFinished, !Task.isCancelled, requestID == id, isUnlocked,
            StartupReadingPreferences.isEnabled, SharedRuntime.startupState == .ready,
            let window, let navigation, let home,
            window.rootViewController === navigation, window.isKeyWindow, !window.isHidden,
            window.windowScene?.activationState == .foregroundActive,
            navigation.viewControllers.count == 1, navigation.topViewController === home
        else { return false }
        return home.isReadyForStartupNavigation
    }

    private func accepts(_ id: UUID, bookshelf: UIViewController) -> Bool {
        guard canNavigate(id), let home else { return false }
        return StartupBookshelfDestination.selectedBookshelf(in: home) === bookshelf
            && bookshelf.canPerformNavigationAction
    }

    private static func lastReadBook(in books: [Book]) -> Book? {
        books.filter { book in
            let isText =
                book.type & BookType.shared.TEXT != 0
                || [BookType.shared.LEGACY_TEXT, BookType.shared.LEGACY_LOCAL, BookType.shared.LEGACY_EPUB].contains(
                    book.type)
            let isLocalFormat =
                book.isLocal
                && LocalBookFormats.bookExtensions.contains(
                    URL(fileURLWithPath: book.bookUrl).pathExtension.lowercased())
            return (isText || isLocalFormat || book.isImage) && !book.isAudio && !book.isWebFile && !book.isNotShelf
                && !book.bookUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.sorted {
            if $0.durChapterTime != $1.durChapterTime { return $0.durChapterTime > $1.durChapterTime }
            return $0.bookUrl < $1.bookUrl
        }.first
    }

    private static func sameReadingContext(_ lhs: Book, _ rhs: Book) -> Bool {
        lhs.bookUrl == rhs.bookUrl && lhs.origin == rhs.origin && lhs.type == rhs.type
            && lhs.durChapterIndex == rhs.durChapterIndex && lhs.durChapterPos == rhs.durChapterPos
            && lhs.durChapterTime == rhs.durChapterTime
    }

    private static func canResume(_ payload: ReaderChapterPayload, book: Book) -> Bool {
        payload.book.bookUrl == book.bookUrl && payload.book.origin == book.origin
            && payload.chapter.index == book.durChapterIndex && payload.book.durChapterPos == book.durChapterPos
            && !payload.chapters.isEmpty
            && (payload.chapter.isVolume || (book.isLocal && book.bookUrl.lowercased().hasSuffix(".pdf"))
                || !payload.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private static func prepare(_ book: Book, using facade: ReaderFacade) async throws -> ReaderChapterPayload {
        try Task.checkCancellation()
        // Unlike loadChapter, this existing shared request never persists a reading position.
        let payload: ReaderChapterPayload = try await SharedCancellableAsync.value { completion in
            facade.prepareChapterRequest(
                bookUrl: book.bookUrl, chapterIndex: book.durChapterIndex, refreshContent: false
            ) { result in
                if result.isCancelled {
                    completion(nil, CancellationError())
                } else if let message = result.errorMessage ?? result.errorCode {
                    completion(
                        nil,
                        NSError(
                            domain: "io.legado.startupReading", code: -1,
                            userInfo: [NSLocalizedDescriptionKey: message]))
                } else {
                    completion(result.payload, nil)
                }
            }
        }
        try Task.checkCancellation()
        return payload
    }
}
