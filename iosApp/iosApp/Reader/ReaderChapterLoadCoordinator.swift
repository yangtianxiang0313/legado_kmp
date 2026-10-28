import UIKit
import shared

@MainActor
final class ReaderChapterLoadCoordinator: NSObject {
    private enum Operation: Equatable {
        case chapter
        case applyProgress(BookProgress, Book?)
        case restoreProgress

        var isProgressReplacement: Bool {
            if case .chapter = self { return false }
            return true
        }
    }

    private struct Request: Equatable {
        let bookURL: String
        let index: Int
        let restorePosition: Int?
        let forceRefresh: Bool
        let successMessage: String?
        let stopsReadAloud: Bool
        let restoresBookProgress: Bool
        let operation: Operation

        func restoringPersistedProgress(forceRefresh: Bool) -> Request {
            Request(
                bookURL: bookURL, index: index, restorePosition: nil,
                forceRefresh: forceRefresh, successMessage: nil, stopsReadAloud: stopsReadAloud,
                restoresBookProgress: true, operation: .restoreProgress)
        }
    }

    private struct FailedContext {
        let request: Request
        let requestedIndex: Int
    }

    private var task: Task<Void, Never>?
    private var requestID: UUID?
    private var pendingRequest: Request?
    private var failedContext: FailedContext?
    private var isSuspended = false
    private weak var owner: ReaderContainerViewController?
    private var progressTask: Task<Void, Never>?
    private var progressRequestID: UUID?
    var isLoading: Bool { task != nil || progressTask != nil }

    override init() {
        super.init()
        for name in [
            UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
            UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification,
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(appearanceInterrupted(_:)), name: name, object: nil)
        }
        for name in [UIApplication.didBecomeActiveNotification, UIScene.didActivateNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(appearanceActivated(_:)), name: name, object: nil)
        }
    }

    deinit {
        task?.cancel()
        progressTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    func cancel(in controller: ReaderContainerViewController) {
        requestID = nil
        pendingRequest = nil
        failedContext = nil
        task?.cancel()
        progressTask?.cancel()
        task = nil
        controller.screen.cancelChapterLoading()
        controller.clearPendingReadAloudChapterRestart()
        controller.loadingIndicator.stopAnimating()
        controller.chapterMessageCoordinator.finishLoading(cancelled: true)
        controller.autoPageAdvanceInFlight = false
    }

    func suspend(in controller: ReaderContainerViewController) {
        isSuspended = true
        requestID = nil
        let request = pendingRequest
        if let request, request.operation.isProgressReplacement {
            pendingRequest = request.restoringPersistedProgress(forceRefresh: request.forceRefresh)
        }
        task?.cancel()
        progressTask?.cancel()
        task = nil
        controller.screen.suspendChapterLoading()
        controller.loadingIndicator.stopAnimating()
        if let request, request.operation.isProgressReplacement {
            // Keep old pages from staging after the cancelled write settles, without a synthetic busy flag.
            controller.chapterMessageCoordinator.loading(index: request.index)
        } else {
            controller.chapterMessageCoordinator.finishLoading(cancelled: true)
        }
        controller.autoPageAdvanceInFlight = false
    }

    func resume(in controller: ReaderContainerViewController) {
        if pendingRequest?.operation.isProgressReplacement == true {
            guard canUseProgressOwner(controller) else { return }
        }
        isSuspended = false
        controller.screen.resumeChapterLoading()
        guard task == nil, let request = pendingRequest else { return }
        // Auto source changes can replace the book before an in-flight request is suspended.
        guard request.bookURL == controller.bookURL else {
            load(in: controller, index: controller.chapterIndex, restorePosition: nil)
            return
        }
        start(
            request.operation.isProgressReplacement
                ? request.restoringPersistedProgress(forceRefresh: request.forceRefresh) : request,
            in: controller)
    }

    func retry(in controller: ReaderContainerViewController, fallbackIndex: Int) {
        let context = failedContext
        let recovery = context?.request.operation.isProgressReplacement == true ? context?.request : pendingRequest
        if let request = recovery, request.operation.isProgressReplacement, request.bookURL == controller.bookURL {
            guard canUseProgressOwner(controller), !controller.sourceChangeActions.isCommitting,
                !controller.bookSettingsCoordinator.isSaving
            else { return }
            isSuspended = false
            controller.screen.resumeChapterLoading()
            start(request.restoringPersistedProgress(forceRefresh: true), in: controller)
            return
        }
        failedContext = nil
        guard let context,
            context.request.bookURL == controller.bookURL,
            context.requestedIndex == max(fallbackIndex, 0)
        else {
            load(in: controller, index: fallbackIndex, restorePosition: nil, forceRefresh: true)
            return
        }
        let request = context.request
        load(
            in: controller, index: context.requestedIndex, restorePosition: request.restorePosition,
            forceRefresh: true, successMessage: request.successMessage,
            stopsReadAloud: request.stopsReadAloud, restoresBookProgress: request.restoresBookProgress
        )
    }

    func load(
        in controller: ReaderContainerViewController,
        index: Int,
        restorePosition: Int?,
        forceRefresh: Bool = false,
        successMessage: String? = nil,
        stopsReadAloud: Bool = false,
        restoresBookProgress: Bool = false
    ) {
        // Message presentation must not reenter viewDidLoad after assigning a request identity.
        controller.loadViewIfNeeded()
        let request = Request(
            bookURL: controller.bookURL, index: max(index, 0), restorePosition: restorePosition,
            forceRefresh: forceRefresh, successMessage: successMessage, stopsReadAloud: stopsReadAloud,
            restoresBookProgress: restoresBookProgress, operation: .chapter
        )
        start(request, in: controller)
    }

    func applyProgress(
        in controller: ReaderContainerViewController, progress: BookProgress, successMessage: String, expectedBook: Book? = nil
    ) {
        controller.loadViewIfNeeded()
        let request = Request(
            bookURL: controller.bookURL, index: max(Int(progress.durChapterIndex), 0), restorePosition: nil,
            forceRefresh: false, successMessage: successMessage, stopsReadAloud: false,
            restoresBookProgress: false, operation: .applyProgress(progress, expectedBook))
        start(request, in: controller)
    }

    private func start(_ request: Request, in controller: ReaderContainerViewController) {
        guard !controller.sourceChangeActions.isCommitting, !controller.bookSettingsCoordinator.isSaving else { return }
        guard task == nil || pendingRequest != request else { return }
        if case .applyProgress = request.operation {
            guard !isSuspended, canUseProgressOwner(controller) else { return }
            // Stage the outgoing page before loading blocks further page turns and staging.
            controller.stageProgress(immediate: true)
        }
        owner = controller
        failedContext = nil
        controller.autoPageCoordinator.chapterWillLoad(request.index)
        controller.cancelPageTurnForContentChange()
        controller.sourceChangeActions.cancelPreparation()
        controller.chapterListRefreshCoordinator.cancel(in: controller)
        let previousProgressTask = progressTask
        requestID = nil
        task?.cancel()
        progressTask?.cancel()
        task = nil
        controller.screen.cancelChapterLoading()
        pendingRequest = request
        guard !isSuspended else { return }
        let id = UUID()
        requestID = id
        controller.chapterMessageCoordinator.loading(index: request.index)
        #if DEBUG
            SharedRuntime.log("Reader chapter request started index=\(request.index) refresh=\(request.forceRefresh)")
        #endif
        task = Task { @MainActor [weak self, weak controller] in
            guard let self, let controller else { return }
            defer {
                if self.progressRequestID == id {
                    self.progressTask = nil
                    self.progressRequestID = nil
                }
                if self.requestID == id {
                    self.task = nil
                    self.requestID = nil
                    self.pendingRequest = nil
                    controller.loadingIndicator.stopAnimating()
                    controller.chapterMessageCoordinator.finishLoading()
                    controller.updateMenuState()
                    controller.autoPageAdvanceInFlight = false
                }
            }
            var requestedIndex = request.index
            var successMessage = request.successMessage
            do {
                // Shared progress writes may finish after Swift cancellation. Read only once they settle.
                if let previousProgressTask { await previousProgressTask.value }
                guard self.accepts(id, in: controller) else { return }
                if request.restoresBookProgress, !request.operation.isProgressReplacement {
                    let book = try await controller.screen.resolveCurrentBook()
                    guard self.accepts(id, in: controller) else { return }
                    requestedIndex = max(Int(book.durChapterIndex), 0)
                    if requestedIndex != request.index {
                        controller.chapterMessageCoordinator.loading(index: requestedIndex)
                    }
                }
                if request.stopsReadAloud {
                    try await controller.screen.stopReadAloud()
                    guard self.accepts(id, in: controller) else { return }
                }
                var payload: ReaderChapterPayload?
                if case .applyProgress(let progress, let expectedBook) = request.operation {
                    payload = try await controller.screen.setProgress(progress, expectedBook: expectedBook)
                    guard self.accepts(id, in: controller) else { return }
                    if payload == nil {
                        // A cancelled predecessor may have committed without presenting its page.
                        successMessage = L10n.Reader.syncProgressApplyNoop
                        payload = try await loadAllowedChapter(
                            in: controller, requestedIndex: &requestedIndex, forceRefresh: false,
                            requestID: id, restoresBookProgress: true)
                    }
                } else {
                    // Resolve the latest per-book schedule before a cached or network load.
                    payload = try await loadAllowedChapter(
                        in: controller, requestedIndex: &requestedIndex,
                        forceRefresh: request.forceRefresh, requestID: id,
                        restoresBookProgress: request.operation.isProgressReplacement)
                }
                guard let payload else {
                    if request.operation.isProgressReplacement {
                        self.rememberFailure(request, requestedIndex: requestedIndex, id: id, in: controller)
                    }
                    return
                }
                guard self.accepts(id, in: controller) else { return }
                if request.operation.isProgressReplacement {
                    guard payload.book.bookUrl == request.bookURL else { return }
                    requestedIndex = Int(payload.chapter.index)
                }
                #if DEBUG
                    SharedRuntime.log("Reader chapter request accepted index=\(requestedIndex)")
                #endif
                if request.stopsReadAloud, !payload.hasReadableContent {
                    throw NSError(
                        domain: "io.legado.kmp.ios", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: L10n.ContentState.emptyTable]
                    )
                }
                await controller.applyChapterPayloadOrAutoChange(
                    payload, requestedIndex: requestedIndex,
                    restorePosition: request.operation.isProgressReplacement
                        ? nil : (requestedIndex == request.index ? request.restorePosition : 0)
                )
                self.rememberFailure(request, requestedIndex: requestedIndex, id: id, in: controller)
                guard self.accepts(id, in: controller), controller.currentChapterURL == payload.chapter.url,
                    let message = successMessage
                else { return }
                if controller.loadFailureView.isShowingLoading {
                    controller.chapterMessageCoordinator.queueSuccessMessage(message)
                } else if controller.loadFailureView.isHidden {
                    controller.showToast(message)
                }
            } catch {
                #if DEBUG
                    SharedRuntime.log(
                        "Reader chapter request ended index=\(requestedIndex) cancelled=\(error is CancellationError || Task.isCancelled)"
                    )
                #endif
                if self.requestID == id, request.stopsReadAloud {
                    controller.clearPendingReadAloudChapterRestart()
                }
                guard !(error is CancellationError), self.accepts(id, in: controller) else { return }
                if request.stopsReadAloud, let sheet = controller.readAloudSheetController {
                    sheet.showNavigationFailure(error.userFacingMessage)
                    return
                }
                await controller.handleChapterLoadFailure(error, requestedIndex: requestedIndex)
                self.rememberFailure(request, requestedIndex: requestedIndex, id: id, in: controller)
            }
        }
        if case .applyProgress = request.operation {
            progressTask = task
            progressRequestID = id
        }
    }

    private func rememberFailure(
        _ request: Request, requestedIndex: Int, id: UUID, in controller: ReaderContainerViewController
    ) {
        guard accepts(id, in: controller), !controller.loadFailureView.isHidden,
            request.bookURL == controller.bookURL
        else { return }
        failedContext = FailedContext(
            request: request.operation.isProgressReplacement
                ? request.restoringPersistedProgress(forceRefresh: request.forceRefresh) : request,
            requestedIndex: requestedIndex)
    }

    private func loadAllowedChapter(
        in controller: ReaderContainerViewController, requestedIndex: inout Int, forceRefresh: Bool, requestID: UUID,
        restoresBookProgress: Bool = false
    ) async throws -> ReaderChapterPayload? {
        let latest = try await controller.screen.resolveCurrentBook()
        guard accepts(requestID, in: controller) else { return nil }
        if restoresBookProgress {
            let index = max(Int(latest.durChapterIndex), 0)
            if requestedIndex != index { controller.chapterMessageCoordinator.loading(index: index) }
            requestedIndex = index
        }
        if latest.config.readSimulating {
            let realCount = controller.chapters.isEmpty ? Int(latest.totalChapterNum) : controller.chapters.count
            let count = ReaderSimulatedReadingPolicy.count(book: latest, realCount: realCount)
            controller.book = latest
            guard count > 0 else {
                controller.chapterMessageCoordinator.failure(
                    message: ReaderSimulatedReadingPolicy.unavailableMessage, index: requestedIndex)
                return nil
            }
            requestedIndex = min(requestedIndex, count - 1)
        }
        return forceRefresh
            ? try await controller.screen.refreshChapter(index: requestedIndex)
            : try await controller.screen.loadChapter(index: requestedIndex)
    }

    private func accepts(_ id: UUID, in controller: ReaderContainerViewController) -> Bool {
        guard
            !Task.isCancelled && !isSuspended && requestID == id
                && !controller.isMovingFromParent && !controller.isBeingDismissed
                && controller.navigationController?.topViewController === controller
        else { return false }
        guard pendingRequest?.operation.isProgressReplacement == true else { return true }
        return owner === controller && pendingRequest?.bookURL == controller.bookURL
            && canUseProgressOwner(controller)
            && !controller.sourceChangeActions.isCommitting && !controller.bookSettingsCoordinator.isSaving
    }

    private func canUseProgressOwner(_ controller: ReaderContainerViewController) -> Bool {
        let scene = progressOwnerScene(controller)
        return !controller.isMovingFromParent && !controller.isBeingDismissed
            && controller.navigationController?.isBeingDismissed != true
            && controller.navigationController?.topViewController === controller
            && scene?.activationState == .foregroundActive
    }

    private func progressOwnerScene(_ controller: ReaderContainerViewController) -> UIWindowScene? {
        // A reader returning via viewWillAppear may not have rejoined its window yet.
        controller.viewIfLoaded?.window?.windowScene
            ?? controller.navigationController?.viewIfLoaded?.window?.windowScene
    }

    @objc private func appearanceInterrupted(_ notification: Notification) {
        guard let owner, pendingRequest?.operation.isProgressReplacement == true else { return }
        if let scene = notification.object as? UIScene, progressOwnerScene(owner) !== scene { return }
        suspend(in: owner)
    }

    @objc private func appearanceActivated(_ notification: Notification) {
        guard isSuspended, let owner, canUseProgressOwner(owner)
        else { return }
        if let scene = notification.object as? UIScene, progressOwnerScene(owner) !== scene { return }
        resume(in: owner)
    }

    func didRenderChapter(in controller: ReaderContainerViewController) {
        guard controller.loadFailureView.isHidden,
            failedContext?.request.bookURL == controller.bookURL,
            failedContext?.requestedIndex == controller.chapterIndex
        else { return }
        failedContext = nil
    }
}
