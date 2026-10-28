import UIKit
import shared

/// ReadBookActivity.onBackPressed / finish, Legado 5f5d314.
@MainActor
final class ReaderExitCoordinator: NSObject {
    private struct Progress: Equatable {
        let chapterIndex: Int
        let position: Int

        func matches(_ book: Book) -> Bool {
            chapterIndex == Int(book.durChapterIndex) && position == Int(book.durChapterPos)
        }
    }

    private enum Action {
        case save
        case pauseReadAloud
        case exit
        case completePreview(addToShelf: Bool)
    }

    private weak var reader: ReaderContainerViewController?
    private weak var dialog: ReaderExitConfirmationDialogViewController?
    private var dialogContext: ReaderExitPresentationContext?
    private var context: ReaderExitPresentationContext?
    private var revision = UUID()
    private var latestProgress: Progress?
    private var task: Task<Void, Never>?
    private var monitor: Timer?
    private var isCompletingPreview = false
    private var isStagingProgress = false
    private var suspendedLoadURL: String?
    private var resumeScheduled = false

    var isBusy: Bool { task != nil || context != nil || dialog != nil }

    init(reader: ReaderContainerViewController) {
        self.reader = reader
        super.init()
        for name in [
            UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
            UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification,
            UIWindow.didResignKeyNotification, UIWindow.didBecomeHiddenNotification,
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(presentationInterrupted(_:)), name: name, object: nil)
        }
        for name in [UIApplication.didBecomeActiveNotification, UIScene.didActivateNotification, UIWindow.didBecomeKeyNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(presentationActivated(_:)), name: name, object: nil)
        }
    }

    deinit {
        task?.cancel()
        monitor?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    func readerContextDidChange(resetProgress: Bool = false) {
        revision = UUID()
        if resetProgress { latestProgress = nil }
        invalidate()
    }

    func bookDidChange(from previous: Book?) {
        guard let reader else { return }
        let current = reader.book
        if let current {
            let changedOrigin = previous.map { $0.origin != current.origin } ?? false
            let changedContextOrigin = context?.origin.map { $0 != current.origin } ?? false
            if current.bookUrl != reader.bookURL || changedOrigin || changedContextOrigin {
                readerContextDidChange(resetProgress: true)
            } else {
                context?.observeBook(origin: current.origin)
            }
        } else if current == nil, previous != nil, !isCompletingPreview, dialog == nil {
            readerContextDidChange(resetProgress: true)
        }
    }

    func didStageProgress(chapterIndex: Int, position: Int) {
        let progress = Progress(chapterIndex: chapterIndex, position: position)
        guard progress != latestProgress else { return }
        latestProgress = progress
        if isStagingProgress { return }
        readerContextDidChange()
    }

    func readerWillDisappear() {
        // Only the owned presentation may cover the reader, never an ancestor's departure.
        if let selected = context, let dialog, dialog.isBeingPresented,
            reader?.presentedViewController === dialog, accepts(selected, allowing: dialog)
        {
            return
        }
        invalidate()
    }

    func readerDidAppear() { resumeChapterLoadingIfNeeded() }

    func pauseReadAloudForBack() { begin(.pauseReadAloud) }
    func saveProgressForBack() { begin(.save) }
    func requestExit() { begin(.exit) }

    func enqueueBackAction() {
        guard let reader, reader.canPerformNavigationAction else { return }
        let requested = ReaderExitPresentationContext(reader: reader, revision: revision)
        DispatchQueue.main.async { [weak self, weak reader] in
            guard let self, let reader, requested.matches(reader, revision: self.revision) else { return }
            reader.performReaderBackAction()
        }
    }

    private func begin(_ action: Action) {
        guard !isBusy, let reader, reader.canPerformNavigationAction else { return }
        reader.cancelPageTurnForContentChange()
        if case .exit = action, reader.chapterLoadCoordinator.isLoading {
            suspendedLoadURL = reader.bookURL
            reader.chapterLoadCoordinator.suspend(in: reader)
        }
        let selected = ReaderExitPresentationContext(reader: reader, revision: revision)
        context = selected
        startMonitor()
        run(action, selected: selected)
    }

    private func run(_ action: Action, selected: ReaderExitPresentationContext) {
        guard task == nil, accepts(selected), let reader else { return }
        task = Task { @MainActor [self, weak reader] in
            defer {
                task = nil
                isCompletingPreview = false
                if dialog == nil, context === selected { finish(selected) }
                scheduleChapterLoadingResume()
            }
            guard let reader else { return }
            do {
                if case .pauseReadAloud = action {
                    try check(selected)
                    reader.readAloudService.pauseForUser()
                    try await reader.screen.pauseReadAloud()
                    try check(selected)
                    reader.showToast("朗读暂停")
                }
                switch action {
                case .save, .pauseReadAloud:
                    _ = try await saveProgress(in: reader, selected: selected)
                case .exit:
                    let latest = try await resolveBook(in: reader, selected: selected)
                    try check(selected)
                    guard let latest else {
                        popReader(selected)
                        return
                    }
                    if !latest.isNotShelf {
                        // The same transaction is a no-op for a shelf book and strictly flushes progress.
                        try await completePreview(addToShelf: false, selected: selected, in: reader)
                    } else if ReaderExitPreferences().showsAddToShelfPrompt {
                        presentPrompt(for: latest, selected: selected)
                    } else {
                        try await completePreview(addToShelf: false, selected: selected, in: reader)
                    }
                case .completePreview(let addToShelf):
                    try await completePreview(addToShelf: addToShelf, selected: selected, in: reader)
                }
            } catch {
                guard !(error is CancellationError), accepts(selected) else { return }
                reader.showToast(error.userFacingMessage)
            }
        }
    }

    private func saveProgress(
        in reader: ReaderContainerViewController, selected: ReaderExitPresentationContext
    ) async throws -> Book? {
        let expected = latestProgress
        try stageProgress(in: reader, selected: selected)
        let staged = latestProgress ?? expected
        await reader.screen.flushReadingProgressNow()
        try check(selected)
        guard let latest = try await resolveBook(in: reader, selected: selected) else { return nil }
        // ReaderProgressQueue's ordinary flush is non-throwing; pause/stop stays on this page.
        if let staged, !staged.matches(latest) {
            throw exitError("阅读进度未能保存，已留在阅读页，请再次返回重试")
        }
        return latest
    }

    private func resolveBook(
        in reader: ReaderContainerViewController, selected: ReaderExitPresentationContext
    ) async throws -> Book? {
        try check(selected)
        let persisted = try await reader.screen.resolveBookForExit()
        try check(selected)
        guard let latest = persisted else { return nil }
        if latest.bookUrl == selected.bookURL { selected.captureOrigin(latest.origin) }
        try check(selected)
        guard latest.bookUrl == selected.bookURL, latest.origin == selected.origin else {
            throw exitError("书籍来源已变化，请返回后重试")
        }
        return latest
    }

    private func presentPrompt(for book: Book, selected: ReaderExitPresentationContext) {
        guard accepts(selected), let reader, book.origin == selected.origin else { return }
        let controller = ReaderExitConfirmationDialogViewController(
            title: L10n.BookDetail.primaryActionShelfAdd,
            message: "是否将《\(book.name)》放入书架？"
        ) { [weak self] decision in
            guard let self else { return }
            guard self.dialogContext === selected else { return }
            self.dialog = nil
            self.dialogContext = nil
            guard self.context === selected else {
                self.scheduleChapterLoadingResume()
                return
            }
            if decision != nil { self.isCompletingPreview = true }
            guard let decision, self.accepts(selected) else {
                self.finish(selected)
                self.isCompletingPreview = false
                self.scheduleChapterLoadingResume()
                return
            }
            self.run(.completePreview(addToShelf: decision), selected: selected)
        }
        controller.canDecide = { [weak self, weak controller] in
            guard let self, let controller else { return false }
            return self.accepts(selected, allowing: controller)
        }
        controller.overrideUserInterfaceStyle = reader.readMenu.overflowInterfaceStyle
        dialog = controller
        dialogContext = selected
        reader.present(controller, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    private func completePreview(
        addToShelf: Bool, selected: ReaderExitPresentationContext, in reader: ReaderContainerViewController
    ) async throws {
        try check(selected)
        guard let origin = selected.origin else { throw exitError(L10n.Reader.syncProgressBookMissing) }
        isCompletingPreview = true
        try stageProgress(in: reader, selected: selected)
        // Shared owns the transactional NOT_SHELF / origin check, not this old UI snapshot.
        let current = try await reader.screen.completePreviewReadingExit(
            bookURL: selected.bookURL, expectedOrigin: origin, addToShelf: addToShelf)
        try check(selected, allowingMissingBook: true)
        if addToShelf {
            guard let current, current.bookUrl == selected.bookURL, current.origin == origin, !current.isNotShelf else {
                throw exitError(L10n.Reader.syncProgressBookMissing)
            }
            // The adapter's existing shared watcher refreshes Book; no stale result is assigned here.
            reader.showToast(L10n.Reader.addToBookshelfSuccess)
        } else {
            // A concurrent shelf addition is returned by Shared and must never be deleted.
            if let current, current.bookUrl != selected.bookURL || current.origin != origin || current.isNotShelf {
                throw exitError("书籍状态已变化，请再次返回重试")
            }
            popReader(selected, allowingMissingBook: true)
        }
    }

    private func popReader(_ selected: ReaderExitPresentationContext, allowingMissingBook: Bool = false) {
        guard accepts(selected, allowingMissingBook: allowingMissingBook), let reader,
            let navigation = reader.navigationController, navigation.viewControllers.count > 1
        else { return }
        suspendedLoadURL = nil
        finish(selected)
        navigation.popViewController(animated: !UIAccessibility.isReduceMotionEnabled)
    }

    private func check(_ selected: ReaderExitPresentationContext, allowingMissingBook: Bool = false) throws {
        try Task.checkCancellation()
        guard accepts(selected, allowingMissingBook: allowingMissingBook) else { throw CancellationError() }
    }

    private func stageProgress(in reader: ReaderContainerViewController, selected: ReaderExitPresentationContext) throws {
        try check(selected)
        isStagingProgress = true
        defer { isStagingProgress = false }
        // Synchronous staging belongs to this accepted action, not a new reader selection.
        reader.stageProgress(immediate: true)
        try check(selected)
    }

    private func accepts(
        _ selected: ReaderExitPresentationContext, allowing controller: UIViewController? = nil,
        allowingMissingBook: Bool = false
    ) -> Bool {
        guard context === selected, let reader else { return false }
        return selected.matches(
            reader, revision: revision, allowing: controller,
            allowingMissingBook: allowingMissingBook || isCompletingPreview || dialog != nil)
    }

    private func finish(_ selected: ReaderExitPresentationContext) {
        guard context === selected else { return }
        context = nil
        monitor?.invalidate()
        monitor = nil
    }

    private func invalidate() {
        context = nil
        task?.cancel()
        monitor?.invalidate()
        monitor = nil
        dialog?.cancelPresentation()
        // Keep the dialog busy until actual detach, and a shared write until its callback returns.
        scheduleChapterLoadingResume()
    }

    private func scheduleChapterLoadingResume() {
        guard suspendedLoadURL != nil, !resumeScheduled else { return }
        resumeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resumeScheduled = false
            self.resumeChapterLoadingIfNeeded()
        }
    }

    private func resumeChapterLoadingIfNeeded() {
        guard suspendedLoadURL != nil, !isBusy, let reader, reader.canPerformNavigationAction,
            !reader.sourceChangeActions.isBusy, !reader.bookSettingsCoordinator.isSaving
        else { return }
        self.suspendedLoadURL = nil
        // The loader itself resolves a pending old URL against the reader's current binding.
        reader.chapterLoadCoordinator.resume(in: reader)
    }

    private func startMonitor() {
        monitor?.invalidate()
        let timer = Timer(
            timeInterval: 0.05, target: MonitorTarget(owner: self), selector: #selector(MonitorTarget.tick(_:)),
            userInfo: nil, repeats: true)
        monitor = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func checkPresentation() {
        guard let context else { return }
        if dialogContext === context, dialog == nil {
            dialogContext = nil
            invalidate()
            return
        }
        if !accepts(context, allowing: dialog) { invalidate() }
    }

    @objc private func presentationInterrupted(_ notification: Notification) {
        guard let selected = context else { return }
        if let scene = notification.object as? UIScene, scene !== selected.scene { return }
        if let window = notification.object as? UIWindow, window !== selected.hostWindow { return }
        invalidate()
    }

    @objc private func presentationActivated(_ notification: Notification) {
        if let scene = notification.object as? UIScene,
            scene !== reader?.viewIfLoaded?.window?.windowScene
        {
            return
        }
        if let window = notification.object as? UIWindow, window !== reader?.viewIfLoaded?.window { return }
        scheduleChapterLoadingResume()
    }

    private func exitError(_ message: String) -> NSError {
        NSError(domain: "io.legado.reader.exit", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    @MainActor
    private final class MonitorTarget: NSObject {
        private weak var owner: ReaderExitCoordinator?

        init(owner: ReaderExitCoordinator) { self.owner = owner }

        @objc func tick(_ timer: Timer) {
            guard let owner else {
                timer.invalidate()
                return
            }
            owner.checkPresentation()
        }
    }
}
