import AVFoundation

/// Only registration/removal is actor-isolated; deallocation can arrive on any queue.
final class AudioPlayerRuntimeCleanup {
    private var actions: [@MainActor () -> Void] = []

    @MainActor
    func add(_ action: @escaping @MainActor () -> Void) {
        actions.append(action)
    }

    @MainActor
    func cancel() {
        let pending = actions
        actions.removeAll()
        for action in pending.reversed() { action() }
    }

    deinit {
        let pending = actions
        guard !pending.isEmpty else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                for action in pending.reversed() { action() }
            }
        } else {
            Task { @MainActor in
                for action in pending.reversed() { action() }
            }
        }
    }
}

@MainActor
final class AudioPlayerItemRuntime {
    let player: AVPlayer
    let item: AVPlayerItem
    let permitsSystemFallback: Bool
    var progressiveFailure: MediaAudioError? { progressive?.failure }
    var progressiveSource: ProgressiveAudioAsset? { progressive }
    private let cleanup = AudioPlayerRuntimeCleanup()
    private let progressive: ProgressiveAudioAsset?
    private let observesPlaybackURL: Bool
    private var invalidated = false

    static func needsHLSRelay(_ request: URLRequest) -> Bool {
        guard let url = request.url, ["m3u", "m3u8"].contains(url.pathExtension.lowercased()) else { return false }
        return !isPlainGET(request)
    }

    private static func isPlainGET(_ request: URLRequest) -> Bool {
        (request.httpMethod ?? "GET").uppercased() == "GET"
            && (request.allHTTPHeaderFields ?? [:]).keys.allSatisfy { $0.caseInsensitiveCompare("User-Agent") == .orderedSame }
            && request.httpBody == nil && request.httpBodyStream == nil
    }

    private static func isCacheableAudioFile(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            && ["mp3", "m4a", "m4b", "aac", "adts", "wav", "wave", "aif", "aiff", "aifc", "caf", "flac", "mp4"]
                .contains(url.pathExtension.lowercased())
    }

    init(
        request: URLRequest, relay: HLSAudioRelay? = nil, allowsFileCache: Bool = true,
        progressiveSource: ProgressiveAudioAsset? = nil, progressiveURL: URL? = nil
    ) throws {
        let asset: AVURLAsset
        let progressive: ProgressiveAudioAsset?
        if let progressiveSource, let progressiveURL {
            progressive = progressiveSource
            asset = AVURLAsset(url: progressiveURL)
            permitsSystemFallback = false
            observesPlaybackURL = false
        } else {
            guard let url = request.url else { throw URLError(.badURL) }
            let plainGET = Self.isPlainGET(request)
            permitsSystemFallback = allowsFileCache && plainGET && Self.isCacheableAudioFile(url)
            if plainGET && (!allowsFileCache || !Self.isCacheableAudioFile(url)) {
                progressive = nil
                var options: [String: Any] = [:]
                if let userAgent = request.value(forHTTPHeaderField: "User-Agent") {
                    options[AVURLAssetHTTPUserAgentKey] = userAgent
                }
                asset = AVURLAsset(url: url, options: options)
            } else {
                // Never retry a protected playlist as an uncredentialed system URL asset.
                guard !["m3u", "m3u8", "mpd"].contains(url.pathExtension.lowercased()) else {
                    throw NSError(
                        domain: "io.legado.audio", code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "此媒体请求需要 HLS 转发，或使用了暂不支持的 DASH 格式"])
                }
                let source = try ProgressiveAudioAsset(request: request, allowsRangeRequests: true)
                progressive = source
                asset = source.asset
            }
            observesPlaybackURL = progressive != nil
        }
        item = AVPlayerItem(asset: asset)
        self.progressive = progressive
        item.preferredForwardBufferDuration = 5
        player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        player.pause()
        let observedPlayer = self.player, observedItem = self.item
        cleanup.add {
            observedPlayer.pause()
            observedItem.cancelPendingSeeks()
            observedPlayer.replaceCurrentItem(with: nil)
            // A replacement runtime may still own the same upstream/spool through its source.
            asset.cancelLoading()
            if let relay { Task { await relay.cancel() } }
        }
    }

    func observe(
        status: @escaping @MainActor () -> Void,
        transport: @escaping @MainActor () -> Void,
        progress: @escaping @MainActor () -> Void,
        ended: @escaping @MainActor () -> Void,
        failed: @escaping @MainActor (Error?) -> Void,
        playbackURL: @escaping @MainActor (URL) -> Void
    ) {
        guard !invalidated else { return }
        progressive?.observeFailure { error in
            Task { @MainActor in failed(error) }
        }
        if observesPlaybackURL {
            progressive?.observePlaybackURL { [weak self] url in
                Task { @MainActor [weak self] in
                    guard let self, !self.invalidated else { return }
                    playbackURL(url)
                }
            }
        }
        let statusObservation = item.observe(\.status, options: [.initial, .new]) { _, _ in
            Task { @MainActor in status() }
        }
        cleanup.add { statusObservation.invalidate() }
        let transportObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { _, _ in
            Task { @MainActor in transport() }
        }
        cleanup.add { transportObservation.invalidate() }
        let interval = CMTime(seconds: 1, preferredTimescale: 1000)
        let observer = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { _ in
            MainActor.assumeIsolated { progress() }
        }
        let observedPlayer = player
        cleanup.add { observedPlayer.removeTimeObserver(observer) }
        observeNotification(AVPlayerItem.didPlayToEndTimeNotification) { _ in ended() }
        observeNotification(AVPlayerItem.failedToPlayToEndTimeNotification) { notification in
            failed(notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)
        }
        observeNotification(AVPlayerItem.playbackStalledNotification) { _ in transport() }
    }

    func invalidate() {
        invalidated = true
        cleanup.cancel()
    }

    private func observeNotification(_ name: Notification.Name, action: @escaping @MainActor (Notification) -> Void) {
        let observer = NotificationCenter.default.addObserver(forName: name, object: item, queue: .main) { notification in
            MainActor.assumeIsolated { action(notification) }
        }
        cleanup.add { NotificationCenter.default.removeObserver(observer) }
    }
}
