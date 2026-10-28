import AVFoundation
import shared

/// Owns a block across loading, pauses and late callbacks. Audio session policy belongs to the service.
@MainActor
final class ReaderHttpSpeechPlayer: NSObject, @preconcurrency AVAudioPlayerDelegate {
    private struct Chunk { let text: String; let start: Int; let end: Int }
    private struct Input { let state: ReadAloudState; let engine: String?; let text: String? }
    private struct Identity: Equatable {
        let engine: String?
        let book: String?
        let chapter: Int32
        let block: Int32
        let rate: Float
        let stream: Bool
        let text: String
    }

    private let callbacks: ReaderReadAloudService.Callbacks
    private let bindings = ScreenBindingController(owner: "HttpSpeechConfiguration")
    private var input: Input?
    private var streamMode: Bool?
    private var configuredEngine: String?
    private var hasConfiguration = false
    private var request: Task<Void, Never>?
    private var generation = UUID()
    private var identity: Identity?
    private var bufferedPlayer: AVAudioPlayer?
    private var streamPlayer: AVPlayer?
    private var progressiveAsset: ProgressiveAudioAsset?
    private var itemObservation: NSKeyValueObservation?
    private var notifications: [NSObjectProtocol] = []
    private var chunks: [Chunk] = []
    private var chunkIndex = 0
    private var wantsPlayback = false
    private var chunkCompleted = false
    private var finished = false
    private var failed = false
    private var advancePending = false
    private var advanced = false
    private var reportedGeneration: UUID?

    init(callbacks: ReaderReadAloudService.Callbacks) {
        self.callbacks = callbacks
        super.init()
        if case let .success(facade) = SharedRuntime.settingsFacade() {
            hasConfiguration = true
            bindings.bind(
                facade.watchRuntimeConfig { [weak self] config in
                    let stream = config.streamReadAloudAudio
                    let engine = config.ttsEngine
                    DispatchQueue.main.async { self?.updateConfiguration(stream: stream, engine: engine) }
                })
        }
    }

    func apply(state: ReadAloudState, engineIdentifier: String?, text: String?) {
        guard state.engine == .httpTts, state.status == .running || state.status == .paused else { stop(); return }
        input = Input(state: state, engine: engineIdentifier, text: text)
        wantsPlayback = state.status == .running
        if !wantsPlayback { pause() }
        guard hasConfiguration else { reportFailure("无法读取 HTTP 朗读配置，请重试"); return }
        reconcile()
    }

    private func updateConfiguration(stream: Bool, engine: String?) {
        let normalized = engine?.replacingOccurrences(of: "httpTts:", with: "").nilIfEmpty
        guard streamMode != stream || configuredEngine != normalized else { return }
        streamMode = stream
        configuredEngine = normalized
        // A direct loading-time pause must survive a late configuration callback.
        reconcile()
    }

    private func reconcile() {
        guard let input, let stream = streamMode else { return }
        let engine = input.engine?.replacingOccurrences(of: "httpTts:", with: "").nilIfEmpty
        guard engine == configuredEngine else { invalidatePlayback(); return }
        let state = input.state
        let key = Identity(
            engine: input.engine, book: state.bookUrl, chapter: state.progress.chapterIndex,
            block: state.progress.blockIndex, rate: state.progress.speechRate,
            stream: stream, text: input.text ?? "")
        if identity != key {
            let sameBlock =
                identity.map {
                    $0.engine == key.engine && $0.book == key.book && $0.chapter == key.chapter && $0.block == key.block
                        && $0.text == key.text
                } ?? false
            let completedLastChunk = chunkCompleted && chunkIndex + 1 >= chunks.count
            let alreadyFinished = sameBlock && ((finished && !failed) || completedLastChunk)
            let pendingAdvance = alreadyFinished && (advancePending || completedLastChunk) && !advanced
            let didAdvance = alreadyFinished && advanced
            let nextOffset =
                sameBlock && chunkCompleted && chunks.indices.contains(chunkIndex + 1)
                ? chunks[chunkIndex + 1].start : Int(state.progress.utteranceRangeStart)
            invalidatePlayback()
            identity = key
            finished = alreadyFinished
            failed = false
            advancePending = pendingAdvance
            advanced = didAdvance
            chunkCompleted = false
            chunkIndex = 0
            chunks = Self.split(key.text, startOffset: nextOffset)
            guard !chunks.isEmpty else { reportFailure("当前段落没有可朗读的正文"); return }
        }
        if finished { scheduleAdvanceIfNeeded(); return }
        guard wantsPlayback else { return }
        if chunkCompleted { consumeCompletedChunk(); return }
        if request == nil, bufferedPlayer == nil, streamPlayer == nil {
            loadCurrentChunk()
        } else {
            playIfWanted(token: generation)
        }
    }

    private static func split(_ text: String, startOffset: Int) -> [Chunk] {
        let full = text as NSString
        guard full.length > 0 else { return [] }
        var start = full.rangeOfComposedCharacterSequence(at: min(max(startOffset, 0), full.length - 1)).location
        var output: [Chunk] = []
        let punctuation = CharacterSet(charactersIn: "。！？；.!?;\n")
        while start < full.length {
            var end = min(start + 300, full.length)
            if end < full.length {
                end = full.rangeOfComposedCharacterSequence(at: end).location
                let boundary = full.rangeOfCharacter(from: punctuation, options: .backwards,
                                                     range: NSRange(location: start, length: end - start))
                if boundary.location != NSNotFound, boundary.location > start + 80 { end = NSMaxRange(boundary) }
            }
            if end <= start { end = NSMaxRange(full.rangeOfComposedCharacterSequence(at: start)) }
            output.append(Chunk(text: full.substring(with: NSRange(location: start, length: end - start)), start: start, end: end))
            start = end
        }
        return output
    }

    private func loadCurrentChunk() {
        guard wantsPlayback, request == nil, let identity, chunks.indices.contains(chunkIndex) else { return }
        let chunk = chunks[chunkIndex]
        let token = generation
        request = Task { [weak self] in
            guard let self else { return }
            var preparing = true
            do {
                let facade = try BootstrapApiKt.sharedHttpSpeechFacade()
                if identity.stream {
                    let prepared: PreparedMediaRequest = try await SharedAsync.value { completion in
                        facade.prepare(text: chunk.text, speechRate: identity.rate, completionHandler: completion)
                    }
                    guard !Task.isCancelled, token == generation else { return }
                    preparing = false
                    let native = try MediaPlaybackRequest.native(prepared)
                    let source = try ProgressiveAudioAsset(request: native)
                    guard !Task.isCancelled, token == generation else { source.cancel(); return }
                    progressiveAsset = source
                    installStream(source.asset, token: token)
                } else {
                    // Keep the full legacy transport: cookies, proxy/WebView capabilities and source rate limiting.
                    // Its cap is post-response, not a streaming/network allocation bound.
                    let encoded: String = try await SharedAsync.value { completion in
                        facade.synthesize(text: chunk.text, speechRate: identity.rate, completionHandler: completion)
                    }
                    guard !Task.isCancelled, token == generation else { return }
                    preparing = false
                    guard encoded.utf8.count <= 22_369_624 else { throw MediaAudioError.tooLarge }
                    guard let data = Data(base64Encoded: encoded), !data.isEmpty else { throw MediaAudioError.unsupportedFormat }
                    guard data.count <= 16 * 1024 * 1024 else { throw MediaAudioError.tooLarge }
                    let player = try AVAudioPlayer(data: data)
                    player.delegate = self
                    bufferedPlayer = player
                }
                request = nil
                playIfWanted(token: token)
            } catch {
                guard !Task.isCancelled, token == generation else { return }
                // Native errors may contain signed URLs. Shared preparation errors are already scrubbed.
                let message =
                    error is MediaAudioError || preparing
                    ? error.userFacingMessage : "HTTP 朗读音频加载失败，请检查引擎或重试"
                reportFailure(message)
            }
        }
    }

    private func installStream(_ asset: AVURLAsset, token: UUID) {
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 1
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        streamPlayer = player
        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, token == generation, item === streamPlayer?.currentItem else { return }
                if item.status == .failed {
                    reportFailure("HTTP 朗读流加载失败，音频格式或网络响应不受支持")
                } else if item.status == .readyToPlay {
                    playIfWanted(token: token)
                }
            }
        }
        notifications.append(
            NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) {
                [weak self] _ in
                Task { @MainActor [weak self] in self?.didCompleteChunk(token: token) }
            })
        notifications.append(
            NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) {
                [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, token == generation else { return }
                    reportFailure("HTTP 朗读流播放中断，请重试")
                }
            })
    }

    private func playIfWanted(token: UUID) {
        guard token == generation, wantsPlayback, !finished, !chunkCompleted else { return }
        if let player = bufferedPlayer {
            if !player.isPlaying {
                guard authorizePlayback(token: token) else { return }
                guard player.prepareToPlay(), player.play() else { reportFailure("无法继续播放朗读音频"); return }
            }
        } else if let player = streamPlayer, player.currentItem?.status == .readyToPlay {
            if player.rate == 0 {
                guard authorizePlayback(token: token) else { return }
                player.play()
            }
        } else {
            return
        }
        guard reportedGeneration != token, chunks.indices.contains(chunkIndex) else { return }
        reportedGeneration = token
        let chunk = chunks[chunkIndex]
        Task { [weak self] in
            guard let self, token == generation, wantsPlayback, !finished else { return }
            await callbacks.updateCurrentRange(chunk.start, chunk.end)
        }
    }

    private func authorizePlayback(token: UUID) -> Bool {
        // The service may synchronously pause/stop us when ownership or interruption policy denies playback.
        guard callbacks.prepareAudioPlayback() else {
            if token == generation { pause() }
            return false
        }
        guard token == generation, wantsPlayback, !finished, !chunkCompleted else {
            callbacks.audioPlaybackDidStop()
            return false
        }
        return true
    }

    func pause() {
        wantsPlayback = false
        bufferedPlayer?.pause()
        streamPlayer?.pause()
        callbacks.audioPlaybackDidStop()
    }

    func stop() {
        input = nil
        wantsPlayback = false
        invalidatePlayback()
        identity = nil
        chunks = []
        chunkIndex = 0
        chunkCompleted = false
        finished = false
        failed = false
        advancePending = false
        advanced = false
    }

    private func invalidatePlayback() {
        generation = UUID()
        request?.cancel()
        request = nil
        itemObservation?.invalidate()
        itemObservation = nil
        notifications.forEach { NotificationCenter.default.removeObserver($0) }
        notifications = []
        bufferedPlayer?.delegate = nil
        bufferedPlayer?.stop()
        bufferedPlayer = nil
        streamPlayer?.pause()
        streamPlayer?.replaceCurrentItem(with: nil)
        streamPlayer = nil
        progressiveAsset?.cancel()
        progressiveAsset = nil
        reportedGeneration = nil
        callbacks.audioPlaybackDidStop()
    }

    private func reportFailure(_ message: String) {
        invalidatePlayback()
        finished = true
        failed = true
        advancePending = false
        advanced = false
        let token = generation
        Task { [weak self] in
            guard let self, token == generation else { return }
            await callbacks.fail(message)
        }
    }

    private func didCompleteChunk(token: UUID) {
        guard token == generation, !chunkCompleted, !finished else { return }
        callbacks.audioPlaybackDidStop()
        chunkCompleted = true
        consumeCompletedChunk()
    }

    private func consumeCompletedChunk() {
        guard wantsPlayback, chunkCompleted, !finished else { return }
        chunkCompleted = false
        invalidatePlayback()
        chunkIndex += 1
        if chunkIndex < chunks.count { loadCurrentChunk(); return }
        finished = true
        advancePending = true
        scheduleAdvanceIfNeeded()
    }

    private func scheduleAdvanceIfNeeded() {
        guard wantsPlayback, advancePending, !advanced else { return }
        let token = generation
        Task { [weak self] in
            guard let self, token == generation, wantsPlayback, advancePending, !advanced else { return }
            advanced = true
            advancePending = false
            await callbacks.advanceToNextBlock()
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard player === bufferedPlayer else { return }
        guard flag else { reportFailure("朗读音频播放失败"); return }
        didCompleteChunk(token: generation)
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        guard player === bufferedPlayer else { return }
        reportFailure("朗读音频格式不受支持")
    }

    deinit {
        bindings.cancelAll()
        request?.cancel()
        itemObservation?.invalidate()
        notifications.forEach { NotificationCenter.default.removeObserver($0) }
        bufferedPlayer?.delegate = nil
        bufferedPlayer?.stop()
        streamPlayer?.pause()
        progressiveAsset?.cancel()
    }
}
