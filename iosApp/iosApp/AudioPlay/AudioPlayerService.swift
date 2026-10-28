import AVFoundation
import MediaPlayer
import shared

@MainActor
protocol AudioPlayerServiceDelegate: AnyObject {
    func audioPlayerDidChangeState(_ state: AudioPlayerService.PlaybackState)
    func audioPlayerDidUpdateProgress(current: TimeInterval, duration: TimeInterval)
    func audioPlayerDidFinishPlaying()
    func audioPlayerDidFailWithError(_ error: Error)
}

@MainActor
final class AudioPlayerService: NSObject {
    enum PlaybackState {
        case stopped
        case loading
        case playing
        case paused
    }

    weak var delegate: AudioPlayerServiceDelegate?
    var onPrevious: (@MainActor () -> Void)? { didSet { updateRemoteAvailability() } }
    var onNext: (@MainActor () -> Void)? { didSet { updateRemoteAvailability() } }
    var onStop: (@MainActor () -> Void)?
    var onOwnershipLost: (@MainActor () -> Void)?

    private(set) var state: PlaybackState = .stopped
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var speed: Float = 1
    private(set) var needsMediaServicesRecovery = false
    var ownsPlayback: Bool { MediaPlaybackOwnership.shared.owns(self) }

    private var runtime: AudioPlayerItemRuntime?
    private var device: AudioPlayerDeviceRuntime?
    private var generation = UUID()
    private var seekGeneration = UUID()
    private var commandGeneration = UUID()
    private var deviceGeneration = UUID()
    private var intentRevision: UInt64 = 0
    private var wantsPlayback = false
    private var awaitingRequest = false
    private var request: URLRequest?
    private var preparedRequest: PreparedMediaRequest?
    private var preparationTask: Task<Void, Never>?
    private var preparationID = UUID()
    private var pendingPosition: TimeInterval = 0
    private var pendingSeekOverride: TimeInterval?
    private var itemReady = false
    private var initialSeekCompleted = false
    private var seeking = false
    private var finished = false
    private var audioSessionActive = false
    private var mediaServicesAvailable = true
    private var interrupted = false

    private struct InterruptionIntent {
        let generation: UUID
        let revision: UInt64
        let wantedPlayback: Bool
    }
    private var interruptionIntent: InterruptionIntent?

    private var nowPlayingTitle = ""
    private var nowPlayingArtist = ""
    private var nowPlayingAlbum = ""

    // Configuration alone must not take ownership or activate the app-wide audio session.
    func configureAudioSession() {
        prepareDeviceRuntime()
    }

    /// Reserve ownership before the session starts resolving a chapter URL.
    func beginLoading() {
        generation = UUID()
        intentRevision &+= 1
        interruptionIntent = nil
        wantsPlayback = true
        awaitingRequest = true
        request = nil
        preparedRequest = nil
        pendingPosition = 0
        pendingSeekOverride = nil
        needsMediaServicesRecovery = !mediaServicesAvailable
        clearItemRuntime()
        currentTime = 0
        duration = 0
        let token = generation
        claimOwnership()
        guard generation == token, ownsPlayback else { return }
        refreshState()
    }

    func play(url: URL, seekTo position: TimeInterval = 0) {
        play(request: URLRequest(url: url), seekTo: position)
    }

    func play(request newRequest: URLRequest, prepared: PreparedMediaRequest? = nil, seekTo position: TimeInterval = 0) {
        // Delivering the reserved chapter is not a new user play gesture. In particular,
        // pause/resume during URL resolution must survive delivery and item readiness.
        let deliveringReservedRequest = ownsPlayback && awaitingRequest
        if !deliveringReservedRequest {
            generation = UUID()
            intentRevision &+= 1
            interruptionIntent = nil
            wantsPlayback = true
            clearItemRuntime()
            pendingSeekOverride = nil
            needsMediaServicesRecovery = !mediaServicesAvailable
            currentTime = 0
            duration = 0
        }
        awaitingRequest = false
        request = newRequest
        preparedRequest = prepared
        pendingPosition = pendingSeekOverride ?? max(0, position)
        pendingSeekOverride = nil
        let token = generation
        claimOwnership()
        guard generation == token, ownsPlayback else { return }
        guard position.isFinite, pendingPosition.isFinite else {
            fail(playbackError("音频起播位置无效"))
            return
        }
        guard mediaServicesAvailable, !needsMediaServicesRecovery else {
            wantsPlayback = false
            refreshState()
            return
        }
        loadItem(generation: token)
    }

    func resume() {
        _ = requestResume()
    }

    private func requestResume() -> Bool {
        guard hasContent, mediaServicesAvailable, !interrupted else { return false }
        intentRevision &+= 1
        interruptionIntent = nil
        wantsPlayback = true
        audioSessionActive = false
        let token = generation
        claimOwnership()
        guard generation == token, ownsPlayback else { return false }
        if awaitingRequest {
            needsMediaServicesRecovery = false
            refreshState()
        } else if runtime == nil, request != nil {
            needsMediaServicesRecovery = false
            loadItem(generation: token)
        } else if finished {
            finished = false
            pendingPosition = 0
            performSeek(to: 0)
        } else {
            startPlaybackIfPossible()
        }
        return ownsPlayback && wantsPlayback
    }

    func pause() {
        guard hasContent else { return }
        intentRevision &+= 1
        interruptionIntent = nil
        wantsPlayback = false
        audioSessionActive = false
        runtime?.player.pause()
        capturePosition()
        if ownsPlayback {
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
        refreshState()
    }

    func stop() {
        generation = UUID()
        intentRevision &+= 1
        wantsPlayback = false
        interruptionIntent = nil
        interrupted = false
        awaitingRequest = false
        request = nil
        preparedRequest = nil
        pendingPosition = 0
        pendingSeekOverride = nil
        needsMediaServicesRecovery = false
        mediaServicesAvailable = true
        clearItemRuntime()
        clearDeviceRuntime()
        currentTime = 0
        duration = 0
        // Release and clear before notifying delegates, which may start another owner.
        if ownsPlayback {
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MediaPlaybackOwnership.shared.release(owner: self)
        }
        setState(.stopped)
    }

    func seek(to time: TimeInterval) {
        guard ownsPlayback, hasContent, time.isFinite, time >= 0 else { return }
        if !itemReady {
            pendingPosition = time
            pendingSeekOverride = time
            return
        }
        let target = duration > 0 ? min(time, duration) : time
        performSeek(to: target)
    }

    func adjustSpeed(_ newSpeed: Float) {
        guard newSpeed.isFinite else { return }
        speed = max(0.5, min(3, newSpeed))
        if ownsPlayback, wantsPlayback, initialSeekCompleted, !seeking, !interrupted,
            !needsMediaServicesRecovery
        {
            runtime?.player.rate = speed
        }
        updateNowPlayingInfo()
    }

    func setNowPlayingMetadata(title: String, artist: String, album: String) {
        nowPlayingTitle = title
        nowPlayingArtist = artist
        nowPlayingAlbum = album
        updateNowPlayingInfo()
    }

    // MARK: - Ownership and lifetime

    private var hasContent: Bool { awaitingRequest || request != nil || runtime != nil }

    private func claimOwnership() {
        MediaPlaybackOwnership.shared.claim(owner: self) { [weak self] in
            self?.ownershipWasLost()
        }
        guard ownsPlayback else { return }
        prepareDeviceRuntime()
        commandGeneration = UUID()
        let token = commandGeneration
        device?.installRemoteCommands { [weak self] action in
            guard let self, self.commandGeneration == token, self.ownsPlayback else { return .commandFailed }
            return self.handleRemoteCommand(action)
        }
        updateRemoteAvailability()
    }

    private func ownershipWasLost() {
        generation = UUID()
        let token = generation
        intentRevision &+= 1
        wantsPlayback = false
        interruptionIntent = nil
        runtime?.player.pause()
        capturePosition()
        // The session needs the old position and asset context to save progress first.
        onOwnershipLost?()
        guard generation == token, !ownsPlayback else { return }
        stop()
    }

    private func clearItemRuntime() {
        preparationID = UUID()
        preparationTask?.cancel()
        preparationTask = nil
        seekGeneration = UUID()
        runtime?.invalidate()
        runtime = nil
        itemReady = false
        initialSeekCompleted = false
        seeking = false
        finished = false
        audioSessionActive = false
    }

    private func clearDeviceRuntime() {
        commandGeneration = UUID()
        deviceGeneration = UUID()
        device?.invalidate()
        device = nil
    }

    // MARK: - Item loading and seek gating

    private func loadItem(generation token: UUID) {
        guard generation == token, ownsPlayback, let request, preparationTask == nil else { return }
        if AudioPlayerItemRuntime.needsHLSRelay(request) {
            preparationID = UUID()
            let preparationToken = preparationID
            let prepared = preparedRequest
            preparationTask = Task { [weak self] in
                do {
                    let intent = try prepared ?? Self.directIntent(request)
                    let (relay, url) = try await HLSAudioRelay.prepare(intent)
                    guard let self, self.generation == token, self.preparationID == preparationToken,
                        self.ownsPlayback, !Task.isCancelled
                    else { await relay.cancel(); return }
                    self.preparationTask = nil
                    self.installItem(request: URLRequest(url: url), relay: relay, generation: token)
                } catch {
                    guard let self, self.generation == token, self.preparationID == preparationToken,
                        self.ownsPlayback, !Task.isCancelled else { return }
                    self.preparationTask = nil
                    self.fail(error)
                }
            }
            refreshState()
            return
        }
        installItem(request: request, generation: token)
    }

    private static func directIntent(_ request: URLRequest) throws -> PreparedMediaRequest {
        guard let url = request.url, request.httpBodyStream == nil else { throw URLError(.badURL) }
        return PreparedMediaRequest(
            url: url.absoluteString, method: request.httpMethod ?? "GET", headers: request.allHTTPHeaderFields ?? [:],
            bodyBase64: request.httpBody?.base64EncodedString(), timeoutMillis: Int64(max(1, min(300, request.timeoutInterval)) * 1000),
            allowsSystemAsset: false, resourceContext: nil)
    }

    private func installItem(request: URLRequest, relay: HLSAudioRelay? = nil, generation token: UUID) {
        do {
            let itemRuntime = try AudioPlayerItemRuntime(request: request, relay: relay)
            runtime = itemRuntime
            itemRuntime.observe(
                status: { [weak self, weak itemRuntime] in
                    guard let self, let itemRuntime, self.isCurrent(itemRuntime, generation: token) else { return }
                    self.itemStatusChanged(itemRuntime)
                },
                transport: { [weak self, weak itemRuntime] in
                    guard let self, let itemRuntime, self.isCurrent(itemRuntime, generation: token) else { return }
                    self.refreshState()
                },
                progress: { [weak self, weak itemRuntime] in
                    guard let self, let itemRuntime, self.isCurrent(itemRuntime, generation: token) else { return }
                    self.updateProgress()
                },
                ended: { [weak self, weak itemRuntime] in
                    guard let self, let itemRuntime, self.isCurrent(itemRuntime, generation: token) else { return }
                    self.playbackEnded()
                },
                failed: { [weak self, weak itemRuntime] error in
                    guard let self, let itemRuntime, self.isCurrent(itemRuntime, generation: token) else { return }
                    self.fail(error ?? self.playbackError("音频播放失败"))
                }
            )
            refreshState()
        } catch {
            if let relay { Task { await relay.cancel() } }
            guard generation == token, ownsPlayback else { return }
            fail(error)
        }
    }

    private func isCurrent(_ itemRuntime: AudioPlayerItemRuntime, generation token: UUID) -> Bool {
        generation == token && runtime === itemRuntime && ownsPlayback
    }

    private func itemStatusChanged(_ itemRuntime: AudioPlayerItemRuntime) {
        switch itemRuntime.item.status {
        case .readyToPlay:
            guard !itemReady else { return }
            itemReady = true
            captureDuration()
            if pendingPosition > 0 {
                let target = duration > 0 ? min(pendingPosition, duration) : pendingPosition
                performSeek(to: target)
            } else {
                // Zero means the asset's default start, including the live edge of an HLS stream.
                initialSeekCompleted = true
                startPlaybackIfPossible()
            }
        case .failed:
            fail(itemRuntime.item.error ?? playbackError("无法加载音频"))
        default:
            break
        }
    }

    @discardableResult
    private func performSeek(to position: TimeInterval) -> Bool {
        guard ownsPlayback, itemReady, let itemRuntime = runtime, position.isFinite, position >= 0 else { return false }
        let token = generation
        seekGeneration = UUID()
        let seekToken = seekGeneration
        seeking = true
        finished = false
        pendingPosition = position
        itemRuntime.player.pause()
        itemRuntime.item.cancelPendingSeeks()
        refreshState()
        guard isCurrent(itemRuntime, generation: token), seekGeneration == seekToken else { return false }
        itemRuntime.player.seek(
            to: CMTime(seconds: position, preferredTimescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero
        ) { [weak self, weak itemRuntime] completed in
            Task { @MainActor [weak self, weak itemRuntime] in
                guard let self, let itemRuntime, self.isCurrent(itemRuntime, generation: token),
                    self.seekGeneration == seekToken
                else { return }
                self.seeking = false
                guard completed else {
                    self.fail(self.playbackError("音频定位失败，请重新播放"))
                    return
                }
                self.initialSeekCompleted = true
                self.capturePosition()
                self.pendingPosition = self.currentTime
                self.updateNowPlayingInfo()
                self.delegate?.audioPlayerDidUpdateProgress(current: self.currentTime, duration: self.duration)
                guard self.isCurrent(itemRuntime, generation: token), self.seekGeneration == seekToken else { return }
                self.startPlaybackIfPossible()
            }
        }
        return true
    }

    private func startPlaybackIfPossible() {
        guard ownsPlayback, wantsPlayback, !interrupted, mediaServicesAvailable, !needsMediaServicesRecovery,
            itemReady, initialSeekCompleted, !seeking, let itemRuntime = runtime
        else {
            refreshState()
            return
        }
        let token = generation
        let revision = intentRevision
        let seekToken = seekGeneration
        do {
            if !audioSessionActive {
                try AudioPlayerDeviceRuntime.activateAudioSession()
            }
            // Audio-session activation may synchronously deliver a route/interruption event.
            guard isCurrent(itemRuntime, generation: token), intentRevision == revision,
                seekGeneration == seekToken, wantsPlayback, !interrupted,
                mediaServicesAvailable, !needsMediaServicesRecovery, !seeking
            else { return }
            audioSessionActive = true
            itemRuntime.player.rate = speed
            refreshState()
        } catch {
            guard isCurrent(itemRuntime, generation: token), intentRevision == revision else { return }
            wantsPlayback = false
            audioSessionActive = false
            refreshState()
            if generation == token, ownsPlayback { delegate?.audioPlayerDidFailWithError(error) }
        }
    }

    private func playbackEnded() {
        guard !finished, !seeking else { return }
        let token = generation
        runtime?.player.pause()
        captureDuration()
        capturePosition()
        if duration > 0 { currentTime = duration }
        wantsPlayback = false
        interruptionIntent = nil
        finished = true
        setState(.stopped)
        guard generation == token, ownsPlayback, finished else { return }
        delegate?.audioPlayerDidUpdateProgress(current: currentTime, duration: duration)
        guard generation == token, ownsPlayback, finished else { return }
        delegate?.audioPlayerDidFinishPlaying()
    }

    private func captureDuration() {
        if let seconds = runtime?.item.duration.seconds, seconds.isFinite, seconds >= 0 { duration = seconds }
    }

    private func capturePosition() {
        guard initialSeekCompleted, !seeking, let seconds = runtime?.player.currentTime().seconds,
            seconds.isFinite, seconds >= 0
        else { return }
        currentTime = seconds
    }

    private func updateProgress() {
        captureDuration()
        capturePosition()
        if initialSeekCompleted, !seeking { pendingPosition = currentTime }
        let token = generation
        refreshState()
        guard generation == token, ownsPlayback, initialSeekCompleted, !seeking else { return }
        delegate?.audioPlayerDidUpdateProgress(current: currentTime, duration: duration)
    }

    private func refreshState() {
        if !hasContent || finished {
            setState(.stopped)
        } else if !wantsPlayback || interrupted || !mediaServicesAvailable || needsMediaServicesRecovery {
            setState(.paused)
        } else if itemReady, initialSeekCompleted, !seeking, runtime?.player.timeControlStatus == .playing {
            setState(.playing)
        } else {
            setState(.loading)
        }
    }

    private func setState(_ newState: PlaybackState) {
        let changed = state != newState
        state = newState
        updateNowPlayingInfo()
        updateRemoteAvailability()
        if changed { delegate?.audioPlayerDidChangeState(newState) }
    }

    private func fail(_ error: Error) {
        stop()
        // A stop delegate may already have started another request.
        guard state == .stopped, !hasContent else { return }
        delegate?.audioPlayerDidFailWithError(error)
    }

    private func playbackError(_ message: String) -> NSError {
        NSError(domain: "io.legado.audio", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: - Interruption, route and media-services recovery

    private func prepareDeviceRuntime() {
        guard device == nil else { return }
        deviceGeneration = UUID()
        let token = deviceGeneration
        device = AudioPlayerDeviceRuntime { [weak self] event in
            guard let self, self.deviceGeneration == token, self.ownsPlayback else { return }
            self.handleDeviceEvent(event)
        }
    }

    private func handleDeviceEvent(_ event: AudioPlayerDeviceRuntime.Event) {
        guard hasContent else { return }
        switch event {
        case .interruptionBegan:
            if !interrupted {
                interruptionIntent = InterruptionIntent(
                    generation: generation, revision: intentRevision, wantedPlayback: wantsPlayback)
            }
            interrupted = true
            audioSessionActive = false
            runtime?.player.pause()
            capturePosition()
            refreshState()
        case .interruptionEnded(let shouldResume):
            guard interrupted else { return }
            interrupted = false
            let saved = interruptionIntent
            interruptionIntent = nil
            guard let saved, saved.wantedPlayback, shouldResume, wantsPlayback,
                saved.generation == generation, saved.revision == intentRevision,
                !needsMediaServicesRecovery, mediaServicesAvailable
            else {
                wantsPlayback = false
                refreshState()
                return
            }
            let token = generation
            claimOwnership()
            guard generation == token, ownsPlayback else { return }
            startPlaybackIfPossible()
        case .outputRemoved:
            // Never continue on the loudspeaker after headphones/Bluetooth disappear.
            pause()
        case .mediaServicesLost:
            suspendForMediaServices(available: false)
        case .mediaServicesReset:
            suspendForMediaServices(available: true)
        }
    }

    private func suspendForMediaServices(available: Bool) {
        runtime?.player.pause()
        capturePosition()
        if initialSeekCompleted, !seeking { pendingPosition = currentTime }
        generation = UUID()
        intentRevision &+= 1
        interruptionIntent = nil
        interrupted = false
        wantsPlayback = false
        mediaServicesAvailable = available
        needsMediaServicesRecovery = true
        clearItemRuntime()
        // Keep the request/position, but only an explicit resume may rebuild after reset.
        refreshState()
    }

    // MARK: - Lock-screen commands and metadata

    private func handleRemoteCommand(_ action: AudioPlayerDeviceRuntime.RemoteAction) -> MPRemoteCommandHandlerStatus {
        guard ownsPlayback, hasContent else { return .noSuchContent }
        switch action {
        case .play:
            return requestResume() ? .success : .commandFailed
        case .pause:
            pause()
            return .success
        case .toggle:
            if wantsPlayback, !interrupted { pause(); return .success }
            return requestResume() ? .success : .commandFailed
        case .previous:
            guard let onPrevious else { return .noSuchContent }
            onPrevious()
            return .success
        case .next:
            guard let onNext else { return .noSuchContent }
            onNext()
            return .success
        case .stop:
            let token = generation
            onStop?()
            if generation == token, ownsPlayback { stop() }
            return .success
        case .seek(let position):
            guard canSeek(to: position) else { return .commandFailed }
            return performSeek(to: position) ? .success : .commandFailed
        }
    }

    private func canSeek(to position: TimeInterval) -> Bool {
        guard position.isFinite, position >= 0, itemReady, initialSeekCompleted, !seeking,
            !needsMediaServicesRecovery, let item = runtime?.item, item.status == .readyToPlay
        else { return false }
        if duration > 0, position > duration { return false }
        return item.seekableTimeRanges.contains { value in
            let range = value.timeRangeValue
            let start = range.start.seconds
            let end = CMTimeRangeGetEnd(range).seconds
            return start.isFinite && end.isFinite && start <= position && position <= end
        }
    }

    private func updateRemoteAvailability() {
        guard ownsPlayback else { return }
        device?.updateRemoteAvailability(
            canPlay: hasContent && mediaServicesAvailable && !interrupted,
            canPause: hasContent && wantsPlayback,
            canStop: hasContent,
            canPrevious: onPrevious != nil,
            canNext: onNext != nil,
            canSeek: itemReady && initialSeekCompleted && !seeking && !needsMediaServicesRecovery
                && !(runtime?.item.seekableTimeRanges.isEmpty ?? true)
        )
    }

    private func updateNowPlayingInfo() {
        guard ownsPlayback else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: nowPlayingTitle,
            MPMediaItemPropertyArtist: nowPlayingArtist,
            MPMediaItemPropertyAlbumTitle: nowPlayingAlbum,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: state == .playing ? Double(speed) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(speed),
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    deinit {
        // Runtime cleanup bags remove only this engine's observers/targets on the main actor.
        // Destroying an old service must not erase another owner's metadata.
        AudioPlayerDeviceRuntime.onMainActor {
            guard MediaPlaybackOwnership.shared.owns(self) else { return }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MediaPlaybackOwnership.shared.release(owner: self)
        }
    }
}
