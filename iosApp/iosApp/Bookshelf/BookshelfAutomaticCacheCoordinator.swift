import UIKit
import shared

@MainActor
final class BookshelfAutomaticCacheCoordinator: NSObject, CacheAutomaticDownloadObserver {
    static let shared = BookshelfAutomaticCacheCoordinator(downloads: .shared)

    private final class Work {
        let id = UUID()
        let bookURL: String
        var task: Task<Void, Never>?
        var downloading = false
        var mayResume = true

        init(bookURL: String) { self.bookURL = bookURL }
    }

    private let downloads: CacheDownloadCoordinator
    private var detail: BookDetailFacade?
    private var settingsSubscription: FlowSubscription?
    private var downloadObserverID: UUID?
    private var configuredCount: Int?
    private var updating = false
    private var interruptedByLifecycle = false
    private var pending: [String] = []
    private var pendingSet: Set<String> = []
    private var work: Work?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    var pendingCount: Int { pending.count + (work == nil ? 0 : 1) }

    init(downloads: CacheDownloadCoordinator) {
        self.downloads = downloads
        super.init()
        downloads.automaticObserver = self
        downloadObserverID = downloads.observe { [weak self] _ in self?.pump() }
        for name in [
            UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
            UIApplication.protectedDataWillBecomeUnavailableNotification, .appLockWillCover,
        ] {
            NotificationCenter.default.addObserver(self, selector: #selector(interrupted), name: name, object: nil)
        }
        for name in [
            UIApplication.didBecomeActiveNotification, UIApplication.protectedDataDidBecomeAvailableNotification,
            .appLockStatusDidChange,
        ] {
            NotificationCenter.default.addObserver(self, selector: #selector(activated), name: name, object: nil)
        }
    }

    deinit {
        settingsSubscription?.cancel()
        work?.task?.cancel()
        NotificationCenter.default.removeObserver(self)
        let downloads = downloads, id = downloadObserverID
        Task { @MainActor in if let id { downloads.removeObserver(id) } }
    }

    func setUpdating(_ value: Bool) {
        prepareIfNeeded()
        updating = value
        if value { interrupt(requeue: true) } else { pump() }
    }

    // A directory replacement must not race the previous cache worker's final write.
    func waitUntilActiveCacheSettled() async {
        guard work != nil else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    func didUpdate(bookURL: String) {
        prepareIfNeeded()
        guard configuredCount != 0 else { return }
        enqueue(bookURL)
        pump()
    }

    private func prepareIfNeeded() {
        guard settingsSubscription == nil else { return }
        do {
            detail = try SharedRuntime.bookDetailFacade().get()
            let settings = try SharedRuntime.settingsFacade().get()
            settingsSubscription = settings.watchRuntimeConfig { [weak self] value in
                Task { @MainActor [weak self] in self?.configurationChanged(Int(value.preDownloadNum)) }
            }
        } catch {
            SharedRuntime.log("自动缓存暂不可用，请重新更新目录后重试")
        }
    }

    private func configurationChanged(_ value: Int) {
        let next = min(max(value, 0), 9999)
        guard configuredCount != next else { return }
        configuredCount = next
        if next == 0 {
            pending.removeAll()
            pendingSet.removeAll()
            work?.mayResume = false
            interrupt(requeue: false)
        } else {
            interrupt(requeue: true)
        }
        pump()
    }

    private func enqueue(_ bookURL: String) {
        guard !bookURL.isEmpty, pendingSet.insert(bookURL).inserted else { return }
        pending.append(bookURL)
    }

    private func removePending(_ bookURL: String) {
        pendingSet.remove(bookURL)
        pending.removeAll { $0 == bookURL }
    }

    private var canRun: Bool {
        guard !updating, !interruptedByLifecycle, UIApplication.shared.applicationState == .active,
            UIApplication.shared.isProtectedDataAvailable
        else { return false }
        return UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.contains { scene in
            scene.activationState == .foregroundActive
                && scene.windows.contains {
                    $0.isKeyWindow && AppLockManager.shared.isUnlocked(in: $0)
                }
        }
    }

    private func pump() {
        guard work == nil, canRun, let count = configuredCount, count > 0, let detail,
            let index = pending.firstIndex(where: { downloads.snapshots[$0]?.isActive != true })
        else { return }
        let url = pending.remove(at: index)
        pendingSet.remove(url)
        let current = Work(bookURL: url)
        work = current
        current.task = Task { @MainActor [weak self] in
            do {
                let book = try await detail.resolveBook(bookUrl: url)
                try Task.checkCancellation()
                guard let self, self.work?.id == current.id, self.canRun,
                    self.configuredCount == count, let book, book.shouldUpdate(), !book.isNotShelf,
                    !book.isLocal, book.totalChapterNum > 0
                else {
                    self?.finishPreparation(current)
                    return
                }
                let start = max(0, Int(book.durChapterIndex))
                let end = min(Int(book.totalChapterNum) - 1, start + count)
                current.downloading = true
                current.task = nil
                if !self.downloads.startAutomatic(book: book, startIndex: start, endIndex: end) {
                    current.downloading = false
                    self.finishPreparation(current)
                }
            } catch {
                self?.finishPreparation(current)
            }
        }
    }

    private func finishPreparation(_ current: Work) {
        guard work?.id == current.id else { return }
        current.task = nil
        work = nil
        settleWaiters()
        pump()
    }

    private func interrupt(requeue: Bool) {
        guard let work else { return }
        if requeue, work.mayResume, configuredCount != 0 { enqueue(work.bookURL) }
        if work.downloading {
            downloads.pauseAutomatic(bookURL: work.bookURL)
        } else {
            work.task?.cancel()
        }
    }

    private func settleWaiters() {
        guard work == nil else { return }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func cacheManualDownloadWillStart(bookURL: String) {
        removePending(bookURL)
        if let work, work.bookURL == bookURL {
            work.mayResume = false
            if !work.downloading { work.task?.cancel() }
        }
    }

    func cacheDownloadStopRequested(bookURL: String?) {
        if let bookURL {
            removePending(bookURL)
        } else {
            pending.removeAll()
            pendingSet.removeAll()
        }
        if let work, bookURL == nil || work.bookURL == bookURL {
            work.mayResume = false
            if !work.downloading { work.task?.cancel() }
        }
    }

    func cacheAutomaticDownloadDidFinish(bookURL: String) {
        guard let current = work, current.downloading, current.bookURL == bookURL else { return }
        finishPreparation(current)
    }

    @objc private func interrupted() {
        interruptedByLifecycle = true
        interrupt(requeue: true)
    }
    @objc private func activated() {
        interruptedByLifecycle = false
        pump()
    }
}
