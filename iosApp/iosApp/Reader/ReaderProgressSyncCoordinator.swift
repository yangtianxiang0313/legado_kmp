import Network
import UIKit
import shared

/// ReadBook.syncProgress / ReadBookActivity lifecycle semantics at Android 5f5d314.
@MainActor
final class ReaderProgressSyncCoordinator: NSObject {
    enum Intent: Equatable { case automatic, merge, read, upload }
    private enum ConfirmationAction { case apply(BookProgress, Book), keepLocal }

    private struct Identity: Equatable {
        let url: String
        let origin: String
        let toc: String
        let name: String
        let author: String
        let reversed: Bool
        let preview: Bool

        init(_ book: Book) {
            url = book.bookUrl; origin = book.origin; toc = book.tocUrl
            name = book.name; author = book.author; reversed = book.config.reverseToc; preview = book.isNotShelf
        }
    }

    private struct Position: Equatable {
        let index: Int
        let offset: Int
    }

    private weak var reader: ReaderContainerViewController?
    private var visible = false
    private var sceneActive = true
    private var identity: Identity?
    private var configurationKey: [String] = []
    private var lastPosition: Position?
    private var revision = UUID()
    private var requestID: UUID?
    private var request: Task<Void, Never>?
    private var pauseID: UUID?
    private var pauseTask: Task<Void, Never>?
    private var needsActivationSync = true
    private var refreshScheduled = false
    private var pathMonitor: NWPathMonitor?
    private var networkAvailable: Bool?
    private weak var confirmation: UIAlertController?
    private var confirmationActionID: UUID?
    private(set) var lastAutomaticFailure: String?

    init(reader: ReaderContainerViewController) {
        self.reader = reader
        super.init()
        for name in [UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(deactivated(_:)), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(activated(_:)), name: UIScene.didActivateNotification, object: nil)
    }

    deinit {
        request?.cancel()
        pathMonitor?.cancel()
        NotificationCenter.default.removeObserver(self)
        // The bounded departure task owns only its captured progress dependencies, not the reader VC.
    }

    func resume() {
        visible = true
        sceneActive = reader?.viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive
        pauseTask?.cancel()
        pauseTask = nil
        pauseID = nil
        needsActivationSync = true
        if pathMonitor == nil {
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                let available = path.status == .satisfied
                Task { @MainActor [weak self] in self?.networkChanged(available: available) }
            }
            pathMonitor = monitor
            monitor.start(queue: DispatchQueue(label: "io.legado.readerProgressSync.network"))
        }
        refresh()
    }

    func suspend() {
        guard visible else { return }
        visible = false
        invalidate()
        flushOnPause()
        pathMonitor?.cancel()
        pathMonitor = nil
        networkAvailable = nil
    }

    func contextDidChange() {
        let next = reader?.book.map(Identity.init)
        guard identity != next else { return }
        identity = next
        lastPosition = nil
        revision = UUID()
        invalidate()
        pauseTask?.cancel()
        pauseTask = nil
        pauseID = nil
        needsActivationSync = true
        refresh()
    }

    func configurationDidChange() {
        guard let config = reader?.runtimeConfig else { return }
        let key = [
            String(config.syncBookProgress), String(config.syncBookProgressPlus), config.webDavUrl ?? "",
            config.webDavAccount ?? "", config.webDavPassword ?? "", config.webDavDir,
        ]
        guard key != configurationKey else { return }
        configurationKey = key
        invalidate()
        pauseTask?.cancel()
        pauseTask = nil
        pauseID = nil
        needsActivationSync = true
        refresh()
    }

    func didStageProgress(chapterIndex: Int, position: Int) {
        let next = Position(index: chapterIndex, offset: position)
        guard lastPosition != next else { return }
        lastPosition = next
        revision = UUID()
        // A confirmation for the old page cannot authorize a later rewind/advance.
        confirmation?.dismiss(animated: false)
        confirmation = nil
        confirmationActionID = nil
    }

    func refresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            guard self.needsActivationSync, self.request == nil, self.confirmation == nil,
                let reader = self.reader, self.canUseReader, self.networkAvailable != false,
                reader.runtimeConfig?.syncBookProgress == true, reader.runtimeConfig?.syncBookProgressPlus == true,
                reader.presentedViewController == nil
            else { return }
            self.needsActivationSync = false
            self.start(.automatic)
        }
    }

    /// Public internal entry points also let the main QA driver exercise the real lifecycle decisions.
    func synchronizeManually() { start(.merge) }
    func getCloudProgressManually() { start(.read) }
    func uploadCloudProgressManually() { start(.upload) }

    func networkChanged(available: Bool) {
        let wasAvailable = networkAvailable
        networkAvailable = available
        if !available {
            invalidate()
        } else if wasAvailable == false {
            needsActivationSync = true
            refresh()
        }
    }

    private var canUseReader: Bool {
        guard let reader, let book = reader.book else { return false }
        return visible && sceneActive && !book.isNotShelf && book.bookUrl == reader.bookURL
            && !reader.isMovingFromParent && !reader.isBeingDismissed
            && reader.navigationController?.isBeingDismissed != true
            && reader.navigationController?.topViewController === reader
            && reader.viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive
            && reader.canNavigateReaderPages && !reader.pages.isEmpty
            && !reader.sourceChangeActions.isCommitting && !reader.bookSettingsCoordinator.isSaving
            && !reader.chapterLoadCoordinator.isLoading && !reader.exitCoordinator.isBusy
    }

    private func start(_ intent: Intent) {
        guard let reader, canUseReader, let book = reader.book else { return }
        contextDidChange()
        invalidate()
        reader.stageProgress(immediate: true)
        let selected = Identity(book)
        let id = UUID()
        requestID = id
        request = Task { @MainActor [weak self, weak reader] in
            guard let self, let reader else { return }
            defer {
                if self.requestID == id { self.request = nil; self.requestID = nil }
            }
            do {
                let baseline = try await reader.screen.resolveBookForProgressSync()
                try self.check(id, selected: selected)
                guard Identity(baseline) == selected else { throw CancellationError() }
                let requestRevision = self.revision
                if intent == .upload {
                    try await reader.screen.uploadBookProgress(book: baseline)
                    try self.check(id, selected: selected)
                    reader.showToast(L10n.WebDav.uploadProgressSuccess)
                } else if intent == .read {
                    let remote = try await reader.screen.getBookProgress(bookName: baseline.name, bookAuthor: baseline.author)
                    try self.check(id, selected: selected)
                    if let remote {
                        if !self.applyUnchangedManualRead(remote, baseline: baseline, revision: requestRevision) {
                            try await self.confirm(remote, id: id, selected: selected, manual: true)
                        }
                    } else {
                        reader.showToast(L10n.WebDav.getProgressEmpty)
                    }
                } else {
                    let result = try await reader.screen.syncProgress()
                    try self.check(id, selected: selected)
                    if let remote = result as? SyncProgressResult.ServerAhead {
                        try await self.confirm(remote.progress, id: id, selected: selected, manual: intent != .automatic)
                    } else if let error = result as? SyncProgressResult.Error {
                        self.report(error.message, manual: intent != .automatic)
                    } else if intent != .automatic {
                        if result is SyncProgressResult.Disabled {
                            reader.showToast(L10n.Reader.syncProgressDisabled)
                        } else if result is SyncProgressResult.LocalAhead {
                            reader.showToast(L10n.Reader.syncProgressLocalAhead)
                        } else {
                            reader.showToast(L10n.Reader.syncProgressInSync)
                        }
                    }
                }
            } catch is CancellationError {
                // Cancellation invalidates both the native subscription and its UI generation.
            } catch {
                guard self.accepts(id, selected: selected) else { return }
                self.report(error.userFacingMessage, manual: intent != .automatic)
            }
        }
    }

    private func applyUnchangedManualRead(_ remote: BookProgress, baseline: Book, revision: UUID) -> Bool {
        guard let reader, reader.runtimeConfig?.syncBookProgressPlus != true,
            self.revision == revision, canUseReader, reader.presentedViewController == nil,
            remote.durChapterTime >= baseline.durChapterTime,
            Int(baseline.durChapterIndex) == reader.chapterIndex,
            Int(baseline.durChapterPos) == reader.currentCharacterOffset(), remote.durChapterPos >= 0
        else { return false }
        let index = Int(remote.durChapterIndex)
        let ahead =
            index > reader.chapterIndex
            || (index == reader.chapterIndex && Int(remote.durChapterPos) > reader.currentCharacterOffset())
        guard ahead, reader.chapters.indices.contains(index),
            index < ReaderSimulatedReadingPolicy.count(in: reader)
        else { return false }
        // Ordinary explicit GET retains its forward jump, but only if reading did not change during GET.
        reader.chapterLoadCoordinator.applyProgress(
            in: reader, progress: remote, successMessage: L10n.Reader.syncProgressAppliedServer, expectedBook: baseline)
        return true
    }

    private func confirm(_ remote: BookProgress, id: UUID, selected: Identity, manual: Bool) async throws {
        guard let reader else { throw CancellationError() }
        try check(id, selected: selected)
        let index = Int(remote.durChapterIndex)
        let readableCount = ReaderSimulatedReadingPolicy.count(book: reader.book, realCount: reader.chapters.count)
        guard reader.chapters.indices.contains(index), index < readableCount, remote.durChapterPos >= 0 else {
            report("云端进度无效或超出当前可读范围", manual: manual)
            return
        }
        guard reader.presentedViewController == nil else {
            needsActivationSync = true
            if manual { reader.showToast("请关闭当前弹窗后重新同步") }
            return
        }
        reader.stageProgress(immediate: true)
        let selectedRevision = revision
        let expected = try await reader.screen.resolveBookForProgressSync()
        try check(id, selected: selected)
        guard revision == selectedRevision, Identity(expected) == selected,
            Int(expected.durChapterIndex) == reader.chapterIndex,
            Int(expected.durChapterPos) == reader.currentCharacterOffset()
        else { throw CancellationError() }
        let local = L10n.Reader.syncProgressLocation(
            chapter: reader.chapterIndex + 1, title: reader.chapterTitle.nilIfEmpty ?? "-",
            position: reader.currentCharacterOffset())
        let cloud = L10n.Reader.syncProgressLocation(
            chapter: index + 1, title: remote.durChapterTitle?.nilIfEmpty ?? reader.chapters[index].title,
            position: Int(remote.durChapterPos))
        let date = Date(timeIntervalSince1970: Double(remote.durChapterTime) / 1000)
        let timestamp =
            remote.durChapterTime > 0 ? DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .short) : "未知"
        let message =
            L10n.Reader.syncProgressServerAheadMessage(local: local, server: cloud)
            + "\n\n云端记录时间：\(timestamp)\n不会自动更改本地进度，请选择要保留的位置。"
        let alert = UIAlertController(title: "确认阅读进度", message: message, preferredStyle: .alert)
        alert.addAction(
            UIAlertAction(title: L10n.Reader.syncProgressApplyServer, style: .default) { [weak self, weak alert] _ in
                guard let self, let alert else { return }
                self.afterConfirmationDismissal(
                    alert, selected: selected, revision: selectedRevision, action: .apply(remote, expected))
            })
        alert.addAction(
            UIAlertAction(title: L10n.Reader.syncProgressKeepLocal, style: .default) { [weak self, weak alert] _ in
                guard let self, let alert else { return }
                self.afterConfirmationDismissal(alert, selected: selected, revision: selectedRevision, action: .keepLocal)
            })
        alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel) { [weak self] _ in self?.confirmation = nil })
        confirmation = alert
        reader.present(alert, animated: true)
    }

    private func afterConfirmationDismissal(
        _ alert: UIAlertController, selected: Identity, revision: UUID, action: ConfirmationAction
    ) {
        guard confirmation === alert else { return }
        confirmation = nil
        let id = UUID()
        confirmationActionID = id
        let execute: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            guard self.confirmationActionID == id, self.identity == selected, self.revision == revision,
                self.canUseReader, let reader = self.reader
            else {
                if self.visible, self.sceneActive, self.reader?.viewIfLoaded?.window != nil {
                    self.reader?.showToast("阅读状态已改变，请重新同步后确认")
                }
                if self.confirmationActionID == id { self.confirmationActionID = nil }
                return
            }
            self.confirmationActionID = nil
            switch action {
            case .apply(let remote, let expected):
                reader.chapterLoadCoordinator.applyProgress(
                    in: reader, progress: remote, successMessage: L10n.Reader.syncProgressAppliedServer, expectedBook: expected)
            case .keepLocal:
                self.start(.upload)
            }
        }
        // UIKit also dismisses UIAlert automatically. Own the completion so neither action races that transition.
        if alert.presentingViewController != nil {
            alert.dismiss(animated: true) { DispatchQueue.main.async(execute: execute) }
        } else {
            DispatchQueue.main.async(execute: execute)
        }
    }

    private func accepts(_ id: UUID, selected: Identity) -> Bool {
        !Task.isCancelled && requestID == id && identity == selected && canUseReader
    }

    private func check(_ id: UUID, selected: Identity) throws {
        try Task.checkCancellation()
        guard accepts(id, selected: selected) else { throw CancellationError() }
    }

    private func invalidate() {
        requestID = nil
        request?.cancel()
        request = nil
        confirmation?.dismiss(animated: false)
        confirmation = nil
        confirmationActionID = nil
    }

    private func report(_ message: String, manual: Bool) {
        if manual {
            reader?.showToast(message)
        } else {
            lastAutomaticFailure = message; SharedRuntime.log("自动进度同步未完成：\(message)")
        }
    }

    private func flushOnPause() {
        guard pauseTask == nil, let reader, let book = reader.book, !book.isNotShelf,
            reader.runtimeConfig?.syncBookProgress == true
        else { return }
        reader.stageProgress(immediate: true)
        do {
            let work = try reader.screen.makeProgressSyncPauseWork(
                expected: book, enhanced: reader.runtimeConfig?.syncBookProgressPlus == true)
            let id = UUID()
            pauseID = id
            let lease = ReaderSyncBackgroundLease()
            pauseTask = Task { @MainActor [weak self] in
                lease.begin()
                defer {
                    lease.finish()
                    if self?.pauseID == id { self?.pauseTask = nil; self?.pauseID = nil }
                }
                do { try await work() } catch is CancellationError {} catch {
                    SharedRuntime.log("离开阅读页进度同步未完成：\(error.userFacingMessage)")
                }
            }
            lease.task = pauseTask
        } catch { SharedRuntime.log("无法准备阅读页进度同步：\(error.userFacingMessage)") }
    }

    @objc private func deactivated(_ notification: Notification) {
        guard let scene = notification.object as? UIScene, reader?.viewIfLoaded?.window?.windowScene === scene,
            visible, sceneActive
        else { return }
        sceneActive = false
        invalidate()
        flushOnPause()
    }

    @objc private func activated(_ notification: Notification) {
        guard let scene = notification.object as? UIScene, reader?.viewIfLoaded?.window?.windowScene === scene, visible else {
            return
        }
        sceneActive = true
        pauseTask?.cancel()
        pauseTask = nil
        pauseID = nil
        needsActivationSync = true
        refresh()
    }
}

/// The OS expiration must still cancel a departure after its view controller has deallocated.
@MainActor
private final class ReaderSyncBackgroundLease {
    var task: Task<Void, Never>?
    private var identifier = UIBackgroundTaskIdentifier.invalid

    func begin() {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Reader progress sync") { [weak self] in
            Task { @MainActor in
                self?.task?.cancel()
                self?.finish()
            }
        }
    }

    func finish() {
        task = nil
        if identifier != .invalid {
            UIApplication.shared.endBackgroundTask(identifier)
            identifier = .invalid
        }
    }
}
