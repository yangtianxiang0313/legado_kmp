import UIKit
import shared

enum AudioPlaybackMode: Int, CaseIterable {
    case listEndStop, singleLoop, random, listLoop

    var iconName: String { ["list.number", "repeat.1", "shuffle", "repeat"][rawValue] }
    var title: String { ["播完停止", "单曲循环", "随机播放", "列表循环"][rawValue] }
}

/// Playback belongs to the app session; a player page only observes and controls it.
@MainActor
final class AudioPlaybackSession: NSObject, AudioPlayerServiceDelegate {
    static let shared = AudioPlaybackSession()
    static let didChange = Notification.Name("AudioPlaybackSession.didChange")

    let player = AudioPlayerService()
    private let screen = AudioPlayScreenAdapter()
    private let progress = AudioPlaybackProgressWriter()
    private var loadTask: Task<Void, Never>?
    private var generation = UUID()
    private var catalogIdentity = UUID()
    private var catalogLoadID = UUID()
    private var catalogSelectionID = UUID()
    private var catalogSnapshot: AudioChapterListSnapshot?
    private var playbackChapter: BookChapter?
    private var pendingSeekPosition: Int?
    private var timerTask: Task<Void, Never>?
    private var hasPosition = false
    private var lastSavedSecond = -1
    private var savedDuration: Int64 = 0
    private var resumePosition = 0
    private var pausedIntent = false
    private var initialChapterIndex: Int?
    private var initialPosition: Int?
    private var durationTask: Task<Void, Never>?
    private struct SourceChangeRecovery {
        let token: UUID
        let paused: Bool
        let hadPosition: Bool
    }
    private var sourceChangeRecovery: SourceChangeRecovery?
    private(set) var book: Book?
    private(set) var bookURL: String?
    private(set) var chapters: [BookChapter] = []
    private(set) var currentChapterIndex = 0
    private(set) var totalChapters = 0
    private(set) var playMode: AudioPlaybackMode = .listEndStop
    private(set) var timerMinutes = 0
    private(set) var errorMessage: String?

    var recoveryGeneration: UUID { generation }
    var isChangingSource: Bool { sourceChangeRecovery != nil }
    var currentTime: TimeInterval {
        if let pendingSeekPosition { return Double(pendingSeekPosition) / 1000 }
        return hasPosition && player.state != .stopped ? player.currentTime : Double(resumePosition) / 1000
    }
    var duration: TimeInterval { max(player.duration, Double(savedDuration) / 1000) }
    var canSeek: Bool { hasPosition && !isChangingSource && player.state != .stopped }

    var chapterTitle: String {
        playbackChapter?.title ?? chapters.first(where: { Int($0.index) == currentChapterIndex })?.title ?? book?.name ?? ""
    }

    private override init() {
        super.init()
        player.delegate = self
        player.onPrevious = { [weak self] in self?.previous() }
        player.onNext = { [weak self] in self?.next() }
        player.onStop = { [weak self] in self?.stop() }
        player.onOwnershipLost = { [weak self] in
            guard let self else { return }
            saveProgress()
            hasPosition = false
            pausedIntent = true
            generation = UUID()
            invalidateCatalogIdentity()
            sourceChangeRecovery = nil
            loadTask?.cancel()
            durationTask?.cancel()
            setTimer(minutes: 0)
            publish()
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(saveForBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    func open(bookURL: String, chapterIndex: Int? = nil, position: Int? = nil) {
        guard !isChangingSource else { return }
        // Normal re-entry attaches to the existing player, including its paused state and timer.
        if self.bookURL == bookURL, book != nil, chapterIndex == nil, position == nil { publish(); return }
        if self.bookURL == bookURL, book != nil, chapterIndex == currentChapterIndex, position == nil {
            publish()
            return
        }
        saveProgress()
        if self.bookURL != bookURL || book == nil || !player.ownsPlayback { invalidateCatalogIdentity() }
        generation = UUID()
        let token = generation
        let prior = loadTask
        prior?.cancel()
        setTimer(minutes: 0)
        hasPosition = false
        playbackChapter = nil
        pendingSeekPosition = nil
        book = nil
        chapters = []
        totalChapters = 0
        self.bookURL = bookURL
        errorMessage = nil
        lastSavedSecond = -1
        savedDuration = 0
        resumePosition = max(position ?? 0, 0)
        initialChapterIndex = chapterIndex
        initialPosition = position
        currentChapterIndex = max(chapterIndex ?? 0, 0)
        pausedIntent = false
        player.beginLoading()
        publish()
        loadTask = makeLoadTask(prior: prior, token: token, reloadBook: true)
    }

    private func makeLoadTask(prior: Task<Void, Never>?, token: UUID, reloadBook: Bool) -> Task<Void, Never> {
        Task { [weak self] in
            await prior?.value
            guard let self else { return }
            do {
                try Task.checkCancellation()
                guard generation == token, player.ownsPlayback else { return }
                if reloadBook {
                    guard let bookURL else { return }
                    try screen.bootstrap().get()
                    let book = try await screen.loadBook(bookUrl: bookURL)
                    let chapters = try await screen.getChapters(bookUrl: bookURL)
                    let mode = try await screen.loadPlayMode()
                    try Task.checkCancellation()
                    guard generation == token, player.ownsPlayback else { return }
                    self.book = book
                    self.chapters = chapters
                    totalChapters = Int(
                        screen.computeSimulatedChapterSize(
                            readConfig: book.readConfig, realChapterSize: Int32(clamping: chapters.count)))
                    guard totalChapters > 0 else { throw playbackError("当前书籍没有可播放的章节") }
                    playMode = AudioPlaybackMode(rawValue: mode) ?? .listEndStop
                    currentChapterIndex = min(max(initialChapterIndex ?? Int(book.durChapterIndex), 0), totalChapters - 1)
                    resumePosition = max(
                        initialPosition ?? (currentChapterIndex == Int(book.durChapterIndex) ? Int(book.durChapterPos) : 0), 0)
                }
                try await prepareChapter(token: token, position: resumePosition)
            } catch {
                if !Task.isCancelled { fail(error, token: token) }
            }
        }
    }

    func togglePlayback() {
        guard !isChangingSource else { return }
        switch player.state {
        case .playing: player.pause(); saveProgress()
        case .paused: player.resume()
        case .loading: player.pause()
        case .stopped:
            pausedIntent = false
            retry()
        }
    }

    /// Reload only on an explicit gesture, preserving the anchor and the latest pause intent.
    func retry() {
        guard bookURL != nil, !isChangingSource else { return }
        saveProgress()
        let paused = pausedIntent
        generation = UUID()
        let token = generation
        let prior = loadTask
        prior?.cancel()
        hasPosition = false
        pendingSeekPosition = nil
        errorMessage = nil
        player.beginLoading()
        if paused { player.pause() }
        publish()
        loadTask = makeLoadTask(prior: prior, token: token, reloadBook: book == nil || totalChapters == 0)
    }

    func previous() { selectChapter(max(0, currentChapterIndex - 1)) }

    func next() {
        guard totalChapters > 0 else { return }
        guard
            let next = screen.computeNextChapterIndex(
                currentIndex: Int32(clamping: currentChapterIndex), totalChapters: Int32(clamping: totalChapters),
                modeValue: Int32(playMode.rawValue))
        else { return }
        selectChapter(Int(truncating: next))
    }

    func selectChapter(_ index: Int, position: Int = 0) {
        guard !isChangingSource, book != nil, index >= 0, index < totalChapters else { return }
        saveProgress()
        generation = UUID()
        let token = generation
        let prior = loadTask
        prior?.cancel()
        hasPosition = false
        playbackChapter = nil
        pendingSeekPosition = nil
        currentChapterIndex = index
        resumePosition = max(position, 0)
        lastSavedSecond = -1
        savedDuration = 0
        pausedIntent = false
        errorMessage = nil
        player.beginLoading()
        publish()
        loadTask = makeLoadTask(prior: prior, token: token, reloadBook: false)
    }

    func isCatalogCurrent(bookURL: String, origin: String, identity: UUID) -> Bool {
        catalogIdentity == identity && self.bookURL == bookURL && book?.bookUrl == bookURL
            && book?.origin == origin && !isChangingSource
            && (player.ownsPlayback || !MediaPlaybackOwnership.shared.hasOwner)
    }

    func loadCatalogSnapshot() async throws -> AudioChapterListSnapshot {
        guard let bookURL, let book else { throw playbackError("当前没有有声播放会话") }
        let origin = book.origin, identity = catalogIdentity, requestID = UUID()
        try requireCatalogCurrent(bookURL: bookURL, origin: origin, identity: identity)
        catalogLoadID = requestID
        saveProgress()
        await flushProgress()
        try requireCatalogCurrent(bookURL: bookURL, origin: origin, identity: identity)
        let snapshot = try await screen.loadCatalogSnapshot(bookURL: bookURL, origin: origin, identity: identity)
        try requireCatalogCurrent(bookURL: bookURL, origin: origin, identity: identity)
        guard catalogLoadID == requestID else { throw playbackError("目录请求已过期，请重新打开") }
        rebindCatalog(book: snapshot.book, chapters: snapshot.items.map(\.chapter))
        guard let currentBook = self.book else { throw playbackError("当前没有有声播放会话") }
        let items = snapshot.items.map { item in
            ReaderChapterListItem(
                chapter: item.chapter, displayTitle: item.displayTitle,
                isCurrent: Int(item.chapter.index) == currentChapterIndex,
                isCached: item.isCached)
        }
        let result = AudioChapterListSnapshot(book: currentBook, items: items, identity: identity)
        catalogSnapshot = result
        publish()
        try requireCatalogCurrent(bookURL: bookURL, origin: origin, identity: identity)
        return result
    }

    func selectCatalogChapter(
        _ index: Int, position: Int = 0, bookURL: String, origin: String, identity: UUID
    ) async throws {
        try requireCatalogCurrent(bookURL: bookURL, origin: origin, identity: identity)
        guard let snapshot = catalogSnapshot, snapshot.identity == identity,
            snapshot.book.bookUrl == bookURL, snapshot.book.origin == origin,
            let selected = snapshot.items.first(where: { Int($0.chapter.index) == index })?.chapter,
            index >= 0, Int32(exactly: index) != nil
        else { throw playbackError("章节不存在或目录已过期，请重新打开") }
        let requestID = UUID(), trackGeneration = generation
        catalogSelectionID = requestID
        let requireCurrent = {
            try self.requireCatalogCurrent(bookURL: bookURL, origin: origin, identity: identity)
            guard self.catalogSelectionID == requestID, self.generation == trackGeneration else {
                throw self.playbackError("播放章节已变化，请重新选择")
            }
        }
        let catalog = try await screen.loadPlaybackCatalog(bookURL: bookURL, origin: origin)
        try requireCurrent()
        rebindCatalog(book: catalog.book, chapters: catalog.chapters)
        publish()
        try requireCurrent()
        guard screen.sameCatalogAddresses(snapshot.items.map(\.chapter), catalog.chapters),
            let requested = catalog.chapters.first(where: { Int($0.index) == index }), requested.url == selected.url
        else {
            throw playbackError("目录顺序或章节已变化，请重新打开目录")
        }
        let target = try screen.catalogChapter(index: Int(requested.index), book: catalog.book, chapters: catalog.chapters)
        let milliseconds = requested.index == target.index ? min(max(position, 0), Int(Int32.max)) : 0
        if playbackChapter?.url == target.url, canSeek {
            rebindCatalog(book: catalog.book, chapters: catalog.chapters)
            seek(to: Double(milliseconds) / 1000)
            try requireCurrent()
            if position <= 0 { player.resume(); publish() }
            return
        }

        // Resolve media without disturbing the current item; only a fully checked selection may replace it.
        let result = try await screen.preparePlaybackRequest(
            bookUrl: bookURL, chapterIndex: requested.index,
            chapterSize: screen.computeSimulatedChapterSize(
                readConfig: catalog.book.readConfig, realChapterSize: Int32(clamping: catalog.chapters.count)))
        try requireCurrent()
        let request = try MediaPlaybackRequest.native(result.request)
        let latest = try await screen.loadPlaybackCatalog(bookURL: bookURL, origin: origin)
        try requireCurrent()
        rebindCatalog(book: latest.book, chapters: latest.chapters)
        publish()
        try requireCurrent()
        guard screen.sameCatalogAddresses(catalog.chapters, latest.chapters),
            let latestRequested = latest.chapters.first(where: { Int($0.index) == index }), latestRequested.url == selected.url
        else {
            throw playbackError("目录顺序或章节已变化，请重新打开目录")
        }
        let actual = try screen.catalogChapter(
            index: Int(latestRequested.index), book: latest.book, chapters: latest.chapters)
        guard result.actualChapterIndex == target.index, actual.index == target.index, actual.url == target.url else {
            throw playbackError("目录已变化，请重新选择章节")
        }
        saveProgress()
        generation = UUID()
        let committedGeneration = generation
        loadTask?.cancel()
        loadTask = nil
        durationTask?.cancel()
        rebindCatalog(book: latest.book, chapters: latest.chapters)
        currentChapterIndex = Int(actual.index)
        playbackChapter = actual
        resumePosition = milliseconds
        pendingSeekPosition = nil
        hasPosition = false
        savedDuration = 0
        lastSavedSecond = -1
        pausedIntent = false
        errorMessage = nil
        self.book = screen.catalogBook(
            latest.book, chapterCount: chapters.count, chapterIndex: currentChapterIndex,
            title: actual.title, position: resumePosition)
        player.beginLoading()
        try requireCatalogCurrent(bookURL: bookURL, origin: origin, identity: identity)
        guard generation == committedGeneration else { throw playbackError("播放章节已变化，请重新选择") }
        player.setNowPlayingMetadata(title: chapterTitle, artist: self.book?.name ?? "", album: self.book?.author ?? "")
        player.play(request: request, prepared: result.request, seekTo: Double(resumePosition) / 1000)
        publish()
    }

    private func requireCatalogCurrent(bookURL: String, origin: String, identity: UUID) throws {
        try Task.checkCancellation()
        guard isCatalogCurrent(bookURL: bookURL, origin: origin, identity: identity) else {
            throw playbackError("播放会话或书源已变化，请重新打开目录")
        }
    }

    private func invalidateCatalogIdentity() {
        catalogIdentity = UUID()
        catalogLoadID = UUID()
        catalogSelectionID = UUID()
        catalogSnapshot = nil
    }

    private func rebindCatalog(book: Book, chapters: [BookChapter]) {
        let anchor = playbackChapter ?? self.chapters.first(where: { Int($0.index) == currentChapterIndex })
        capturePosition()
        self.chapters = chapters.sorted { $0.index < $1.index }
        totalChapters = Int(
            screen.computeSimulatedChapterSize(
                readConfig: book.readConfig, realChapterSize: Int32(clamping: chapters.count)))
        if let anchor {
            let rebound = screen.uniqueChapter(url: anchor.url, in: chapters)
            currentChapterIndex = rebound.map { Int($0.index) } ?? -1
            if playbackChapter != nil, let rebound { playbackChapter = rebound }
        } else if !chapters.contains(where: { Int($0.index) == currentChapterIndex }) {
            currentChapterIndex = -1
        }
        self.book = screen.catalogBook(
            book, chapterCount: chapters.count, chapterIndex: currentChapterIndex,
            title: playbackChapter?.title ?? chapters.first(where: { Int($0.index) == currentChapterIndex })?.title,
            position: resumePosition)
    }

    private func prepareChapter(token: UUID, position: Int) async throws {
        guard generation == token, let bookURL, let book, !isChangingSource,
            let anchor = playbackChapter ?? chapters.first(where: { Int($0.index) == currentChapterIndex })
        else { return }
        let origin = book.origin
        let catalog = try await screen.loadPlaybackCatalog(bookURL: bookURL, origin: origin)
        try Task.checkCancellation()
        guard generation == token, player.ownsPlayback, !isChangingSource else { return }
        let requested =
            anchor.isVolume
            ? catalog.chapters.first(where: { $0.index == anchor.index && $0.url == anchor.url })
            : screen.uniqueChapter(url: anchor.url, in: catalog.chapters)
        guard let requested else { throw playbackError("章节已移除，请重新选择") }
        let target = try screen.catalogChapter(index: Int(requested.index), book: catalog.book, chapters: catalog.chapters)
        let result = try await screen.preparePlaybackRequest(
            bookUrl: bookURL, chapterIndex: requested.index,
            chapterSize: screen.computeSimulatedChapterSize(
                readConfig: catalog.book.readConfig, realChapterSize: Int32(clamping: catalog.chapters.count)))
        try Task.checkCancellation()
        guard generation == token, player.ownsPlayback, !isChangingSource else { return }
        let request = try MediaPlaybackRequest.native(result.request)
        let latest = try await screen.loadPlaybackCatalog(bookURL: bookURL, origin: origin)
        try Task.checkCancellation()
        guard generation == token, player.ownsPlayback, !isChangingSource else { return }
        let actual = try screen.catalogChapter(
            index: Int(result.actualChapterIndex), book: latest.book, chapters: latest.chapters)
        guard actual.index == result.actualChapterIndex, actual.index == target.index, actual.url == target.url,
            screen.uniqueChapter(url: actual.url, in: latest.chapters) != nil
        else { throw playbackError("目录已变化，请重新选择章节") }
        rebindCatalog(book: latest.book, chapters: latest.chapters)
        currentChapterIndex = Int(actual.index)
        playbackChapter = actual
        resumePosition = actual.index == requested.index ? min(max(position, 0), Int(Int32.max)) : 0
        self.book = screen.catalogBook(
            latest.book, chapterCount: chapters.count, chapterIndex: currentChapterIndex,
            title: actual.title, position: resumePosition)
        player.setNowPlayingMetadata(title: chapterTitle, artist: self.book?.name ?? "", album: self.book?.author ?? "")
        player.play(request: request, prepared: result.request, seekTo: Double(resumePosition) / 1000)
        publish()
    }

    func seek(to seconds: TimeInterval) {
        guard canSeek, seconds.isFinite else { return }
        let target = min(max(seconds, 0), Double(Int32.max) / 1000)
        let bounded = player.duration > 0 ? min(target, player.duration) : target
        pendingSeekPosition = Int(bounded * 1000)
        resumePosition = pendingSeekPosition ?? 0
        player.seek(to: bounded)
        saveProgress()
        publish()
    }

    func adjustSpeed(by delta: Float) {
        player.adjustSpeed(screen.adjustSpeed(currentSpeed: player.speed, delta: delta))
        publish()
    }

    func cycleMode() {
        playMode = AudioPlaybackMode(rawValue: (playMode.rawValue + 1) % 4) ?? .listEndStop
        let value = playMode.rawValue
        Task { [screen] in
            do { try await screen.savePlayMode(value) } catch { SharedRuntime.log("有声播放模式保存失败") }
        }
        publish()
    }

    func setTimer(minutes: Int) {
        timerTask?.cancel()
        timerTask = nil
        timerMinutes = max(0, minutes)
        publish()
        guard timerMinutes > 0 else { return }
        timerTask = Task { [weak self] in
            while let self, timerMinutes > 0 {
                do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                guard !Task.isCancelled else { return }
                if player.state == .playing {
                    timerMinutes -= 1
                    if timerMinutes == 0 { player.pause(); saveProgress() }
                    publish()
                }
            }
        }
    }

    func stop() {
        saveProgress()
        clearSession()
    }

    private func clearSession() {
        generation = UUID()
        invalidateCatalogIdentity()
        loadTask?.cancel()
        loadTask = nil
        durationTask?.cancel()
        sourceChangeRecovery = nil
        setTimer(minutes: 0)
        hasPosition = false
        playbackChapter = nil
        pendingSeekPosition = nil
        bookURL = nil
        book = nil
        chapters = []
        totalChapters = 0
        errorMessage = nil
        resumePosition = 0
        savedDuration = 0
        player.stop()
        publish()
    }

    func saveProgress() {
        guard !isChangingSource, let bookURL, let book,
            let chapter = playbackChapter ?? chapters.first(where: { Int($0.index) == currentChapterIndex }),
            chapter.bookUrl == bookURL, !chapter.isVolume
        else { return }
        capturePosition()
        let milliseconds = Int32(clamping: resumePosition)
        progress.save(
            screen: screen, bookURL: bookURL, origin: book.origin, chapterURL: chapter.url, position: milliseconds)
    }

    func flushProgress() async { await progress.flush() }

    func suspendForSourceChange(bookURL: String) -> UUID? {
        guard self.bookURL == bookURL, book != nil, !isChangingSource else { return nil }
        let paused = pausedIntent
        player.pause()
        saveProgress()
        let recovery = SourceChangeRecovery(token: UUID(), paused: paused, hadPosition: hasPosition)
        sourceChangeRecovery = recovery
        invalidateCatalogIdentity()
        generation = recovery.token
        loadTask?.cancel()
        durationTask?.cancel()
        hasPosition = false
        if !recovery.hadPosition { player.stop() }
        pausedIntent = paused
        publish()
        return recovery.token
    }

    func isSourceChangeCurrent(_ token: UUID) -> Bool {
        sourceChangeRecovery?.token == token && generation == token
    }

    func flushSourceChange(_ token: UUID) async {
        guard isSourceChangeCurrent(token) else { return }
        await loadTask?.value
        await durationTask?.value
        await progress.flush()
    }

    func restoreSourceChange(_ token: UUID) {
        guard isSourceChangeCurrent(token), let recovery = sourceChangeRecovery else { return }
        let retainedPlayer = recovery.hadPosition && player.ownsPlayback && player.state != .stopped
        if retainedPlayer {
            player.pause()
            player.seek(to: Double(resumePosition) / 1000)
        }
        sourceChangeRecovery = nil
        hasPosition = false
        pausedIntent = recovery.paused
        if retainedPlayer, !pausedIntent { player.resume() }
        publish()
    }

    func completeSourceChange(_ token: UUID) -> Bool {
        guard isSourceChangeCurrent(token) else { return false }
        // Preparation drained every old write; never save the retired identity after commit.
        clearSession()
        return true
    }

    func suspendForLogin(bookURL: String, generation token: UUID) {
        guard self.bookURL == bookURL, generation == token, !isChangingSource else { return }
        let paused = pausedIntent
        player.pause()
        saveProgress()
        generation = UUID()
        invalidateCatalogIdentity()
        loadTask?.cancel()
        hasPosition = false
        player.stop()
        pausedIntent = paused
        publish()
    }

    @objc private func saveForBackground() { saveProgress() }

    func audioPlayerDidChangeState(_ state: AudioPlayerService.PlaybackState) {
        guard bookURL != nil else { return }
        if isChangingSource {
            // Lock-screen play must not unfreeze the old asset during its source transaction.
            if state == .playing || state == .loading { player.pause() }
            return
        }
        if state == .playing { hasPosition = true; pausedIntent = false; capturePosition() }
        if state == .paused { pausedIntent = true; saveProgress() }
        if state == .stopped { capturePosition(); hasPosition = false }
        publish()
    }

    func audioPlayerDidUpdateProgress(current: TimeInterval, duration: TimeInterval) {
        guard bookURL != nil, !isChangingSource, player.ownsPlayback else { return }
        pendingSeekPosition = nil
        hasPosition = true
        capturePosition()
        if current.isFinite, hasPosition, Int(current) / 5 != lastSavedSecond {
            lastSavedSecond = Int(current) / 5
            saveProgress()
        }
        if duration.isFinite, duration > 0, savedDuration == 0, let bookURL, let book, let chapter = playbackChapter {
            savedDuration = Int64(min(duration * 1000, Double(Int64.max - 1024)))
            let origin = book.origin, chapterURL = chapter.url, value = savedDuration
            let token = generation, prior = durationTask
            durationTask = Task { [weak self, screen] in
                await prior?.value
                guard !Task.isCancelled, self?.generation == token else { return }
                try? await screen.saveDuration(bookURL: bookURL, origin: origin, chapterURL: chapterURL, milliseconds: value)
            }
        }
        publish()
    }

    func audioPlayerDidFinishPlaying() {
        guard bookURL != nil, !isChangingSource else { return }
        saveProgress(); next(); publish()
    }

    func audioPlayerDidFailWithError(_ error: Error) { fail(error, token: generation) }

    private func fail(_ error: Error, token: UUID) {
        guard generation == token, bookURL != nil, !isChangingSource else { return }
        saveProgress()
        hasPosition = false
        generation = UUID()
        loadTask?.cancel()
        errorMessage = "音频播放失败，请检查网络、书源或媒体格式后重试"
        player.stop()
        publish()
    }

    private func capturePosition() {
        guard pendingSeekPosition == nil, hasPosition, player.ownsPlayback, player.currentTime.isFinite else { return }
        resumePosition = Int(min(max(player.currentTime, 0), Double(Int32.max) / 1000) * 1000)
    }

    private func playbackError(_ message: String) -> NSError {
        NSError(domain: "AudioPlayback", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func publish() { NotificationCenter.default.post(name: Self.didChange, object: self) }
}
