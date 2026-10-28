import Network
import UIKit
import shared

struct MangaProgressSyncContext: Equatable {
    let chapter: MangaReaderChapter
    let position: Int
    private let directory: MangaChapterWindowIdentity

    init(chapter: MangaReaderChapter, position: Int) {
        self.chapter = chapter
        self.position = position
        directory = MangaChapterWindowIdentity(chapter)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.directory == rhs.directory && lhs.chapter.book.tocUrl == rhs.chapter.book.tocUrl
            && lhs.chapter.book.name == rhs.chapter.book.name && lhs.chapter.book.author == rhs.chapter.book.author
            && lhs.chapter.book.config.reverseToc == rhs.chapter.book.config.reverseToc
            && lhs.chapter.book.isNotShelf == rhs.chapter.book.isNotShelf
            && lhs.chapter.chapterIndex == rhs.chapter.chapterIndex && lhs.position == rhs.position
    }
}

/// ReadManga's chapter/image progress stays separate from text offsets and is never applied by a cloud callback alone.
@MainActor
final class MangaProgressSyncCoordinator {
    enum Intent { case automatic, merge, read, upload }

    private weak var owner: UIViewController?
    private let adapter: MangaReaderAdapter
    private let context: () -> MangaProgressSyncContext?
    private let canInteract: () -> Bool
    private let stage: () -> Void
    private let apply: (MangaReaderChapter) -> Void
    private var visible = false
    private var needsSync = true
    private var scheduled = false
    private var observation: FlowSubscription?
    private var config: AppRuntimeConfig?
    private var configKey: [String] = []
    private var observedContext: MangaProgressSyncContext?
    private var revision = UUID()
    private var request: Task<Void, Never>?
    private var requestID: UUID?
    private var departure: Task<Void, Never>?
    private var departureID: UUID?
    private var monitor: NWPathMonitor?
    private var networkAvailable: Bool?
    private weak var confirmation: UIAlertController?
    var onPresentationChanged: (() -> Void)?
    private(set) var lastAutomaticFailure: String?

    init(
        owner: UIViewController, adapter: MangaReaderAdapter,
        context: @escaping () -> MangaProgressSyncContext?, canInteract: @escaping () -> Bool,
        stage: @escaping () -> Void, apply: @escaping (MangaReaderChapter) -> Void
    ) {
        self.owner = owner
        self.adapter = adapter
        self.context = context
        self.canInteract = canInteract
        self.stage = stage
        self.apply = apply
    }

    deinit {
        observation?.cancel()
        request?.cancel()
        monitor?.cancel()
    }

    func resume() {
        if !visible { needsSync = true }
        visible = true
        departure?.cancel()
        departure = nil
        departureID = nil
        if observation == nil {
            do {
                observation = try SharedRuntime.settingsFacade().get().watchRuntimeConfig { [weak self] config in
                    DispatchQueue.main.async { self?.configurationChanged(config) }
                }
            } catch { report(error.userFacingMessage, manual: false) }
        }
        if monitor == nil {
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                let available = path.status == .satisfied
                Task { @MainActor [weak self] in self?.networkChanged(available: available) }
            }
            self.monitor = monitor
            monitor.start(queue: DispatchQueue(label: "io.legado.mangaProgress.network"))
        }
        contextDidChange()
        refresh()
    }

    func suspend(upload: Bool = true) {
        let wasVisible = visible
        visible = false
        invalidateContext()
        monitor?.cancel()
        monitor = nil
        networkAvailable = nil
        if upload, wasVisible { flushOnPause() }
    }

    func contextDidChange() {
        let next = context()
        guard next != observedContext else { return }
        observedContext = next
        invalidateContext()
        refresh()
    }

    func invalidateContext() {
        revision = UUID()
        requestID = nil
        request?.cancel()
        request = nil
        if let confirmation {
            self.confirmation = nil
            confirmation.dismiss(animated: false) { [weak self] in self?.onPresentationChanged?() }
        }
    }

    func refresh() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            guard self.needsSync, self.request == nil, self.confirmation == nil,
                self.config?.syncBookProgress == true, self.networkAvailable != false, self.usableContext != nil
            else { return }
            self.needsSync = false
            self.start(.automatic)
        }
    }

    func menuElements() -> [UIMenuElement] {
        [
            action("同步阅读进度", icon: "arrow.triangle.2.circlepath", intent: .merge),
            action("获取云端进度", icon: "icloud.and.arrow.down", intent: .read),
            action("上传本地进度", icon: "icloud.and.arrow.up", intent: .upload),
        ]
    }

    func synchronizeManually() { start(.merge) }
    func getCloudProgressManually() { start(.read) }
    func uploadCloudProgressManually() { start(.upload) }

    private func action(_ title: String, icon: String, intent: Intent) -> UIAction {
        UIAction(title: title, image: UIImage(systemName: icon)) { [weak self] _ in self?.start(intent) }
    }

    private var usableContext: MangaProgressSyncContext? {
        guard visible, canInteract(), let owner, owner.presentedViewController == nil,
            let window = owner.viewIfLoaded?.window, window.windowScene?.activationState == .foregroundActive,
            AppLockManager.shared.isUnlocked(in: window), let selected = context(), !selected.chapter.book.isNotShelf,
            selected.chapter.pages.indices.contains(selected.position), !adapter.isRetired
        else { return nil }
        return selected
    }

    private func start(_ intent: Intent) {
        guard let selected = usableContext else { return }
        contextDidChange()
        invalidateContext()
        stage()
        let selectedRevision = revision
        let id = UUID()
        requestID = id
        request = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.requestID == id { self.requestID = nil; self.request = nil } }
            do {
                let baseline = try await self.adapter.progressSyncSnapshot()
                try self.check(id, selected: selected, revision: selectedRevision)
                guard self.matches(baseline, selected) else { throw CancellationError() }
                switch intent {
                case .upload:
                    try await self.adapter.uploadCloudProgress(book: baseline)
                    try self.check(id, selected: selected, revision: selectedRevision)
                    self.feedback(L10n.WebDav.uploadProgressSuccess)
                case .read:
                    let remote = try await self.adapter.readCloudProgress(book: baseline)
                    try self.check(id, selected: selected, revision: selectedRevision)
                    if let remote {
                        try self.confirm(remote, baseline: baseline, selected: selected, revision: selectedRevision)
                    } else {
                        self.feedback(L10n.WebDav.getProgressEmpty)
                    }
                case .automatic where self.config?.syncBookProgressPlus != true:
                    let remote = try await self.adapter.readCloudProgress(book: baseline)
                    try self.check(id, selected: selected, revision: selectedRevision)
                    if let remote, self.isAhead(remote, baseline) {
                        try await self.prepareAndApply(remote, baseline: baseline, selected: selected, revision: selectedRevision)
                    }
                case .automatic, .merge:
                    let result = try await self.adapter.syncProgress()
                    try self.check(id, selected: selected, revision: selectedRevision)
                    if let ahead = result as? SyncProgressResult.ServerAhead {
                        try self.confirm(ahead.progress, baseline: baseline, selected: selected, revision: selectedRevision)
                    } else if let error = result as? SyncProgressResult.Error {
                        self.report(error.message, manual: intent != .automatic)
                    } else if intent != .automatic {
                        self.feedback(
                            result is SyncProgressResult.Disabled
                                ? L10n.Reader.syncProgressDisabled
                                : result is SyncProgressResult.LocalAhead
                                    ? L10n.Reader.syncProgressLocalAhead
                                    : L10n.Reader.syncProgressInSync)
                    }
                }
            } catch is CancellationError {
            } catch {
                guard self.revision == selectedRevision, self.usableContext == selected else { return }
                self.report(error.userFacingMessage, manual: intent != .automatic)
            }
        }
    }

    private func confirm(
        _ remote: BookProgress, baseline: Book, selected: MangaProgressSyncContext, revision: UUID
    ) throws {
        guard let owner, usableContext == selected, self.revision == revision else { throw CancellationError() }
        let index = Int(remote.durChapterIndex)
        guard remote.name == baseline.name, remote.author == baseline.author, remote.durChapterPos >= 0,
            selected.chapter.chapters.indices.contains(index), !selected.chapter.chapters[index].isVolume
        else { throw failure("云端进度无效或超出当前可读范围") }
        let alert = UIAlertController(
            title: "确认阅读进度",
            message: "本地：第\(Int(baseline.durChapterIndex) + 1)章，第\(Int(baseline.durChapterPos) + 1)张\n"
                + "云端：第\(index + 1)章，第\(Int(remote.durChapterPos) + 1)张\n\n选择要保留的位置。",
            preferredStyle: .alert)
        for (title, keepLocal) in [(L10n.Reader.syncProgressApplyServer, false), (L10n.Reader.syncProgressKeepLocal, true)] {
            alert.addAction(
                UIAlertAction(title: title, style: .default) { [weak self, weak alert] _ in
                    guard let self, let alert, self.confirmation === alert else { return }
                    self.confirmation = nil
                    alert.dismiss(animated: true) { [weak self] in
                        self?.onPresentationChanged?()
                        self?.finishConfirmation(
                            remote, baseline: baseline, selected: selected, revision: revision, keepLocal: keepLocal)
                    }
                })
        }
        alert.addAction(
            UIAlertAction(title: L10n.Common.cancel, style: .cancel) { [weak self, weak alert] _ in
                guard let self, let alert, self.confirmation === alert else { return }
                self.confirmation = nil
                alert.dismiss(animated: true) { [weak self] in self?.onPresentationChanged?() }
            })
        confirmation = alert
        owner.present(alert, animated: !UIAccessibility.isReduceMotionEnabled) { [weak self] in
            self?.onPresentationChanged?()
        }
    }

    private func finishConfirmation(
        _ remote: BookProgress, baseline: Book, selected: MangaProgressSyncContext, revision: UUID, keepLocal: Bool
    ) {
        guard self.revision == revision, usableContext == selected else { return }
        if keepLocal { start(.upload); return }
        let id = UUID()
        requestID = id
        request = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.requestID == id { self.requestID = nil; self.request = nil } }
            do {
                try await self.prepareAndApply(remote, baseline: baseline, selected: selected, revision: revision)
            } catch is CancellationError {
            } catch {
                guard self.revision == revision, self.usableContext == selected else { return }
                self.report(error.userFacingMessage, manual: true)
            }
        }
    }

    private func prepareAndApply(
        _ remote: BookProgress, baseline: Book, selected: MangaProgressSyncContext, revision: UUID
    ) async throws {
        let prepared = try await adapter.prepareCloudProgress(remote, expected: baseline)
        try Task.checkCancellation()
        guard self.revision == revision, usableContext == selected else { throw CancellationError() }
        apply(prepared)
        feedback(L10n.Reader.syncProgressAppliedServer)
    }

    private func matches(_ book: Book, _ selected: MangaProgressSyncContext) -> Bool {
        ReaderSyncClient.sameIdentity(book, selected.chapter.book) && !book.isNotShelf
            && book.durChapterIndex == selected.chapter.chapterIndex && Int(book.durChapterPos) == selected.position
    }

    private func check(_ id: UUID, selected: MangaProgressSyncContext, revision: UUID) throws {
        try Task.checkCancellation()
        guard requestID == id, self.revision == revision, usableContext == selected else { throw CancellationError() }
    }

    private func isAhead(_ remote: BookProgress, _ book: Book) -> Bool {
        remote.durChapterIndex > book.durChapterIndex
            || (remote.durChapterIndex == book.durChapterIndex && remote.durChapterPos > book.durChapterPos)
    }

    private func configurationChanged(_ config: AppRuntimeConfig) {
        self.config = config
        let key = [
            String(config.syncBookProgress), String(config.syncBookProgressPlus), config.webDavUrl ?? "",
            config.webDavAccount ?? "", config.webDavPassword ?? "", config.webDavDir,
        ]
        guard key != configKey else { return }
        configKey = key
        invalidateContext()
        departure?.cancel()
        departure = nil
        departureID = nil
        needsSync = true
        refresh()
    }

    func networkChanged(available: Bool) {
        let previous = networkAvailable
        networkAvailable = available
        if !available { invalidateContext() } else if previous == false { needsSync = true; refresh() }
    }

    private func flushOnPause() {
        guard departure == nil, config?.syncBookProgress == true, let selected = context(),
            !selected.chapter.book.isNotShelf, !adapter.isRetired
        else { return }
        stage()
        do {
            let work = try adapter.makeProgressSyncPauseWork(
                expected: selected.chapter.book, enhanced: config?.syncBookProgressPlus == true)
            let id = UUID()
            departureID = id
            let lease = MangaProgressSyncBackgroundLease()
            departure = Task { @MainActor [weak self] in
                lease.begin()
                defer {
                    lease.finish()
                    if self?.departureID == id { self?.departure = nil; self?.departureID = nil }
                }
                do { try await work() } catch is CancellationError {} catch {
                    SharedRuntime.log("离开漫画阅读页同步未完成：\(error.userFacingMessage)")
                }
            }
            lease.task = departure
        } catch { report(error.userFacingMessage, manual: false) }
    }

    private func feedback(_ message: String) { owner?.showTransientMessage(message, duration: 3) }

    private func report(_ message: String, manual: Bool) {
        if manual { feedback(message) } else { lastAutomaticFailure = message; SharedRuntime.log("漫画自动进度同步未完成：\(message)") }
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "io.legado.mangaProgressSync", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

@MainActor
private final class MangaProgressSyncBackgroundLease {
    var task: Task<Void, Never>?
    private var identifier = UIBackgroundTaskIdentifier.invalid

    func begin() {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Manga cloud progress") { [weak self] in
            Task { @MainActor in
                self?.task?.cancel(); self?.finish()
            }
        }
    }

    func finish() {
        task = nil
        if identifier != .invalid { UIApplication.shared.endBackgroundTask(identifier); identifier = .invalid }
    }
}
