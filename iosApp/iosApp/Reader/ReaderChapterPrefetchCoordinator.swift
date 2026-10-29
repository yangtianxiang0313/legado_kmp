import UIKit
import shared

@MainActor
final class ReaderChapterPrefetchCoordinator: NSObject {
    private struct DisplayedChapter: Equatable {
        let bookURL: String
        let origin: String
        let index: Int
        let url: String
    }

    private struct RequestKey: Equatable {
        let chapter: DisplayedChapter
        let tocURL: String
        let reversed: Bool
        let catalog: String
        let count: Int
    }

    private weak var reader: ReaderContainerViewController?
    private var visible = false
    private var sceneActive = false
    private var protectedDataAvailable = UIApplication.shared.isProtectedDataAvailable
    private var displayedChapter: DisplayedChapter?
    private var catalogSignature = ""
    private var selectedKey: RequestKey?
    private var activeKey: RequestKey?
    private var completedKey: RequestKey?
    private var failedKey: RequestKey?
    private var requestID: UUID?
    private var task: Task<Void, Never>?

    init(reader: ReaderContainerViewController) {
        self.reader = reader
        super.init()
        for name in [
            UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
            UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification,
            UIApplication.protectedDataWillBecomeUnavailableNotification,
            .appLockWillCover,
        ] {
            NotificationCenter.default.addObserver(self, selector: #selector(interrupted(_:)), name: name, object: nil)
        }
        for name in [
            UIApplication.didBecomeActiveNotification, UIScene.didActivateNotification,
            UIApplication.protectedDataDidBecomeAvailableNotification,
            .appLockStatusDidChange,
        ] {
            NotificationCenter.default.addObserver(self, selector: #selector(activated(_:)), name: name, object: nil)
        }
    }

    deinit {
        task?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    func resume() {
        visible = true
        sceneActive = reader?.viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive
        protectedDataAvailable = UIApplication.shared.isProtectedDataAvailable
        completedKey = nil
        failedKey = nil
        refresh()
    }

    func suspend() {
        visible = false
        cancel()
    }

    func chapterLoadingActivityDidChange(interrupted: Bool) {
        if interrupted {
            cancel()
        } else {
            refresh()
        }
    }

    func catalogDidChange() {
        catalogSignature = (reader?.chapters ?? []).map { chapter in
            // Content rules may fill titles/variables and cache writes fill word counts.
            // Only actual target changes replace a prefetch window.
            let fields = [
                chapter.bookUrl, String(chapter.index), chapter.url, chapter.baseUrl,
                chapter.resourceUrl ?? "", String(chapter.isVolume), String(chapter.isVip), String(chapter.isPay),
            ]
            return fields.map { "\($0.utf8.count):\($0)" }.joined()
        }.joined(separator: "|")
        contextDidChange()
    }

    func contextDidChange() {
        refresh()
    }

    func didRenderChapter(bookURL: String, origin: String?, index: Int, url: String?) {
        guard let reader, reader.loadFailureView.isHidden,
            reader.pages.indices.contains(reader.currentPageIndex), let chapter = currentChapter,
            chapter.bookURL == bookURL, chapter.origin == origin, chapter.index == index, chapter.url == url
        else { return }
        displayedChapter = chapter
        refresh()
    }

    private var currentChapter: DisplayedChapter? {
        guard let reader, let book = reader.book, book.bookUrl == reader.bookURL,
            let url = reader.currentChapterURL, !url.isEmpty
        else { return nil }
        return DisplayedChapter(bookURL: reader.bookURL, origin: book.origin, index: reader.chapterIndex, url: url)
    }

    private var currentKey: RequestKey? {
        guard let reader, let book = reader.book, !book.isLocal,
            let chapter = displayedChapter, chapter == currentChapter,
            let configuredCount = reader.runtimeConfig?.preDownloadNum,
            let entry = reader.chapters[safe: chapter.index],
            Int(entry.index) == chapter.index, entry.url == chapter.url
        else { return nil }
        let count = min(max(Int(configuredCount), 0), 100)
        guard count > 0 else { return nil }
        return RequestKey(
            chapter: chapter, tocURL: book.tocUrl, reversed: book.config.reverseToc,
            catalog: catalogSignature, count: count)
    }

    private var canUseReader: Bool {
        guard let reader, let window = reader.viewIfLoaded?.window, window.isKeyWindow,
            AppLockManager.shared.isUnlocked(in: window)
        else { return false }
        return visible && sceneActive && protectedDataAvailable
            && reader.viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive
            && !reader.isMovingFromParent && !reader.isBeingDismissed
            && reader.navigationController?.isBeingDismissed != true
            && reader.navigationController?.topViewController === reader
    }

    private var canStart: Bool {
        guard canUseReader, let reader else { return false }
        return reader.canNavigateReaderPages && reader.loadFailureView.isHidden
            && !reader.chapterLoadCoordinator.isLoading && !reader.sourceChangeActions.isBusy
            && !reader.bookSettingsCoordinator.isSaving && !reader.exitCoordinator.isBusy
    }

    func refresh() {
        let key = currentKey
        if selectedKey != key {
            selectedKey = key
            completedKey = nil
            failedKey = nil
            cancel()
        }
        if activeKey != nil && (activeKey != key || !canUseReader) { cancel() }
        guard canStart, let key, key != activeKey, key != completedKey, key != failedKey,
            let reader
        else { return }
        let id = UUID()
        requestID = id
        activeKey = key
        task = Task(priority: .background) { @MainActor [weak self, screen = reader.screen] in
            do {
                // Let the accepted page reach the screen and coalesce rapid chapter turns.
                try await Task.sleep(nanoseconds: 150_000_000)
                guard self?.accepts(id, key: key) == true else {
                    self?.finish(id, key: key, completed: nil)
                    return
                }
                let completed = try await screen.preloadDisplayedChapter(index: key.chapter.index)
                try Task.checkCancellation()
                self?.finish(id, key: key, completed: completed)
            } catch is CancellationError {
                self?.finish(id, key: key, completed: nil)
            } catch {
                // Prefetch must never publish a display error or replace the current chapter.
                self?.finish(id, key: key, completed: false)
            }
        }
    }

    private func accepts(_ id: UUID, key: RequestKey) -> Bool {
        !Task.isCancelled && requestID == id && activeKey == key && currentKey == key && canStart
    }

    private func finish(_ id: UUID, key: RequestKey, completed: Bool?) {
        // Cancelling an old subscription can synchronously deliver its terminal callback.
        guard requestID == id, activeKey == key else { return }
        requestID = nil
        activeKey = nil
        task = nil
        if completed == true {
            completedKey = key
            failedKey = nil
        } else if completed == false {
            failedKey = key
        }
    }

    private func cancel() {
        requestID = nil
        activeKey = nil
        task?.cancel()
        task = nil
    }

    private func matchesScene(_ notification: Notification) -> Bool {
        if let window = notification.object as? UIWindow { return reader?.viewIfLoaded?.window === window }
        guard let scene = notification.object as? UIScene else { return true }
        return reader?.viewIfLoaded?.window?.windowScene === scene
    }

    @objc private func interrupted(_ notification: Notification) {
        guard matchesScene(notification) else { return }
        if notification.name == UIApplication.protectedDataWillBecomeUnavailableNotification {
            protectedDataAvailable = false
        } else {
            sceneActive = false
        }
        cancel()
    }

    @objc private func activated(_ notification: Notification) {
        guard matchesScene(notification) else { return }
        sceneActive = reader?.viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive
        protectedDataAvailable = UIApplication.shared.isProtectedDataAvailable
        completedKey = nil
        failedKey = nil
        refresh()
    }
}

enum ReaderChapterPrefetchRequest {
    static func run(facade: ReaderFacade, bookURL: String, index: Int) async throws -> Bool {
        let request = ReaderPreloadRequest(facade: facade)
        let result: ReaderPreloadResult = try await SharedCancellableAsync.value { completion in
            request.preload(bookUrl: bookURL, chapterIndex: Int32(index), preDownloadNum: -1) { result in
                if result.isCancelled {
                    completion(nil, CancellationError())
                } else {
                    completion(result, nil)
                }
            }
        }
        try Task.checkCancellation()
        return result.completed && result.errorMessage == nil
    }
}
