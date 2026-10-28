import UIKit
import AVFoundation
import shared

struct ReaderReadAloudVoiceOption: Equatable {
    let identifier: String
    let displayName: String
}

private struct ReaderReadAloudSpeechIdentity: Equatable {
    let chapterIndex: Int
    let blockIndex: Int
}

@MainActor
final class ReaderReadAloudService: NSObject {
    struct Callbacks {
        let advanceToNextBlock: @Sendable () async -> Void
        let updateCurrentRange: @Sendable (Int, Int) async -> Void
        let updatePlaybackState: @Sendable (Bool) async -> Void
        let pausePlayback: @Sendable () async -> Void
        let fail: @Sendable (String) async -> Void
        let resumePlayback: @Sendable () async -> Void
        let prepareAudioPlayback: @MainActor @Sendable () -> Bool
        let audioPlaybackDidStop: @MainActor @Sendable () -> Void

        init(
            advanceToNextBlock: @escaping @Sendable () async -> Void,
            updateCurrentRange: @escaping @Sendable (Int, Int) async -> Void,
            updatePlaybackState: @escaping @Sendable (Bool) async -> Void,
            pausePlayback: @escaping @Sendable () async -> Void,
            fail: @escaping @Sendable (String) async -> Void,
            resumePlayback: @escaping @Sendable () async -> Void = {},
            prepareAudioPlayback: @escaping @MainActor @Sendable () -> Bool = { true },
            audioPlaybackDidStop: @escaping @MainActor @Sendable () -> Void = {}
        ) {
            self.advanceToNextBlock = advanceToNextBlock
            self.updateCurrentRange = updateCurrentRange
            self.updatePlaybackState = updatePlaybackState
            self.pausePlayback = pausePlayback
            self.fail = fail
            self.resumePlayback = resumePlayback
            self.prepareAudioPlayback = prepareAudioPlayback
            self.audioPlaybackDidStop = audioPlaybackDidStop
        }
    }

    private var synthesizer = AVSpeechSynthesizer()
    private let engineBindings = ScreenBindingController(owner: "ReadAloudEngine")
    private var engineIdentifier: String?
    private let callbacks: Callbacks
    private lazy var httpPlayer = ReaderHttpSpeechPlayer(callbacks: httpCallbacks)
    private lazy var audioPolicy = ReaderReadAloudAudioPolicy(
        ownsPlayback: { [weak self] in
            guard let self else { return false }
            return MediaPlaybackOwnership.shared.owns(self)
        },
        onEvent: { [weak self] event in self?.handleAudioPolicyEvent(event) }
    )
    private var httpCallbacks: Callbacks {
        Callbacks(
            advanceToNextBlock: callbacks.advanceToNextBlock,
            updateCurrentRange: callbacks.updateCurrentRange,
            updatePlaybackState: callbacks.updatePlaybackState,
            pausePlayback: callbacks.pausePlayback,
            fail: callbacks.fail,
            resumePlayback: callbacks.resumePlayback,
            prepareAudioPlayback: { [weak self] in self?.prepareHTTPPlayback() ?? false },
            audioPlaybackDidStop: { [weak self] in self?.isHTTPPlaybackActive = false }
        )
    }
    private var blocksByIndex: [Int: String] = [:]
    private var currentState: ReadAloudState?
    private var currentSpeakingIdentity: ReaderReadAloudSpeechIdentity?
    private var currentManagedUtterance: AVSpeechUtterance?
    private var hasFinishedManagedUtterance = false
    private var isManagedSpeechPaused = false
    private var currentUtteranceTextOffset = 0
    private var currentSpeechRate: Float = 1.0
    private var currentPitchMultiplier: Float = 1.0
    private var preferredVoiceIdentifier: String?
    private var selectedTextUtterance: AVSpeechUtterance?
    private var isPlaybackBlocked = true
    private var mayClaimAudioOwnership = false
    private var playbackGeneration = UUID()
    private var automaticResumeGeneration: UUID?
    private var waitsForInterruptionEnd = false
    private var pauseSynchronization: Task<Void, Never>?
    private var automaticResumeTask: Task<Void, Never>?
    private var isHTTPPlaybackActive = false

    private static let pitchKey = "reader.readAloud.pitchMultiplier"

    var pitchMultiplier: Float {
        get { currentPitchMultiplier }
        set {
            let clamped = min(max(newValue, 0.5), 2.0)
            guard currentPitchMultiplier != clamped else { return }
            currentPitchMultiplier = clamped
            UserDefaults.standard.set(clamped, forKey: Self.pitchKey)
            applySpeechConfigurationChange()
        }
    }

    init(callbacks: Callbacks) {
        self.callbacks = callbacks
        let savedPitch = UserDefaults.standard.float(forKey: Self.pitchKey)
        self.currentPitchMultiplier = savedPitch > 0 ? min(max(savedPitch, 0.5), 2.0) : 1.0
        super.init()
        synthesizer.delegate = self
        if case let .success(facade) = SharedRuntime.settingsFacade() {
            engineBindings.bind(facade.watchRuntimeConfig { [weak self] config in
                    DispatchQueue.main.async { self?.updateRuntimeConfig(config) }
                })
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        _ = audioPolicy
    }

    deinit {
        engineBindings.cancelAll()
        pauseSynchronization?.cancel()
        automaticResumeTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    /// Call before an intentional start/resume, never from a state-observation callback.
    func prepareForPlayback() {
        cancelAutomaticResume()
        pauseSynchronization?.cancel()
        pauseSynchronization = nil
        playbackGeneration = UUID()
        pauseLocalPlayback()
        isPlaybackBlocked = false
        mayClaimAudioOwnership = true
    }

    /// User intent cannot be inferred from the shared echo of a system-initiated pause.
    func pauseForUser() {
        cancelAutomaticResume()
        playbackGeneration = UUID()
        isPlaybackBlocked = true
        mayClaimAudioOwnership = false
        pauseLocalPlayback()
        releaseAudioOwnership()
    }

    private func updateRuntimeConfig(_ config: AppRuntimeConfig) {
        audioPolicy.update(
            ignoreAudioFocus: config.ignoreAudioFocus,
            pauseWhilePhoneCalls: config.pauseReadAloudWhilePhoneCalls
        )
        if ownsAudioPlayback, hasActiveSpeech, !isPlaybackBlocked, audioPolicy.isSessionActive {
            _ = activateAudioSession(backgroundPlayback: currentBackgroundPlayback)
        }
        updateEngineIdentifier(config.ttsEngine)
    }

    private func updateEngineIdentifier(_ identifier: String?) {
        let normalized = identifier?.replacingOccurrences(of: "httpTts:", with: "").nilIfEmpty
        guard normalized != engineIdentifier else { return }
        let wasOwned = ownsAudioPlayback
        engineIdentifier = normalized
        httpPlayer.stop()
        isHTTPPlaybackActive = false
        cancelCurrentSpeech()
        guard wasOwned, !isPlaybackBlocked, let currentState else { return }
        let expected: ReadAloudEngineKind = normalized == nil ? .systemTts : .httpTts
        if currentState.engine == expected { apply(state: currentState) }
    }

    func updateBlocks(_ blocks: [ReaderContentBlock]) {
        blocksByIndex = Dictionary(
            uniqueKeysWithValues: blocks
                .filter { ($0.type == .heading || $0.type == .paragraph) && $0.text.isEmpty == false }
                .map { (Int($0.blockIndex), $0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        )
    }

    var availableVoiceOptions: [ReaderReadAloudVoiceOption] {
        AVSpeechSynthesisVoice.speechVoices()
            .sorted { lhs, rhs in
                let lhsIsChinese = lhs.language.localizedCaseInsensitiveHasPrefixCompat("zh")
                let rhsIsChinese = rhs.language.localizedCaseInsensitiveHasPrefixCompat("zh")
                if lhsIsChinese != rhsIsChinese {
                    return lhsIsChinese
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            .map {
                let localeTitle = Locale.current.localizedString(forIdentifier: $0.language)
                    ?? Locale(identifier: $0.language).localizedString(forIdentifier: $0.language)
                    ?? $0.language
                return ReaderReadAloudVoiceOption(
                    identifier: $0.identifier,
                    displayName: "\($0.name) · \(localeTitle)"
                )
            }
    }

    /// Speak arbitrary text (used by text selection F54).
    func speakText(_ text: String) {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedText.isEmpty == false else {
            Task { await callbacks.fail("选中的内容为空，无法朗读") }
            return
        }
        prepareForPlayback()
        httpPlayer.stop()
        isHTTPPlaybackActive = false
        cancelCurrentSpeech()
        let utterance = AVSpeechUtterance(string: normalizedText)
        utterance.rate = currentSpeechRate > 0 ? avSpeechRate(from: currentSpeechRate) : AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = currentPitchMultiplier
        utterance.voice = resolveVoice()
        guard prepareAudioPlayback(backgroundPlayback: false) else { return }
        selectedTextUtterance = utterance
        synthesizer.speak(utterance)
    }

    func updateVoiceIdentifier(_ identifier: String?) {
        let normalized = identifier?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard preferredVoiceIdentifier != normalized else { return }
        preferredVoiceIdentifier = normalized
        applySpeechConfigurationChange()
    }

    func updateSpeechRate(_ value: Float) {
        let normalizedValue = normalizedSpeechRate(value)
        guard abs(currentSpeechRate - normalizedValue) > 0.001 else { return }
        currentSpeechRate = normalizedValue
        applySpeechConfigurationChange()
    }

    func apply(state: ReadAloudState?) {
        let wasPaused = currentState?.status == .paused
        let previousBookURL = currentState?.bookUrl
        currentState = state
        if previousBookURL != state?.bookUrl {
            cancelAutomaticResume()
        }
        guard let state else {
            stopSynthesizer()
            return
        }
        if state.status == .running, !ownsAudioPlayback, !mayClaimAudioOwnership { return }
        // A shared snapshot is not a new playback command after replacement or suspension.
        if state.status == .running, isPlaybackBlocked || audioPolicy.isInterrupted || audioPolicy.shouldPauseForCall {
            if !isPlaybackBlocked {
                suspendPlayback(automaticallyResume: ownsAudioPlayback && hasActiveSpeech)
            }
            return
        }
        if state.engine == .httpTts {
            cancelCurrentSpeech()
            if state.status == .idle || state.status == .stopped || state.status == .error {
                stopSynthesizer()
                return
            }
            // The HTTP player calls prepareAudioPlayback at its actual play/resume boundary.
            httpPlayer.apply(state: state, engineIdentifier: engineIdentifier, text: blocksByIndex[Int(state.progress.blockIndex)])
            if state.status == .paused {
                isHTTPPlaybackActive = false
                if automaticResumeGeneration == nil { releaseAudioOwnership() }
            }
            return
        }
        httpPlayer.stop()
        isHTTPPlaybackActive = false
        let previousSpeechRate = currentSpeechRate
        currentSpeechRate = normalizedSpeechRate(state.progress.speechRate)
        switch state.status {
        case .idle, .stopped:
            stopSynthesizer()
        case .error:
            stopSynthesizer()
        case .paused:
            pauseSynthesizer()
            if automaticResumeGeneration == nil { releaseAudioOwnership() }
        case .running:
            if wasPaused, currentManagedUtterance == nil {
                cancelCurrentSpeech(forceFreshQueue: true)
            }
            if abs(previousSpeechRate - currentSpeechRate) > 0.001, currentSpeakingIdentity != nil {
                restartCurrentBlock(from: state)
            } else {
                speakCurrentBlockIfNeeded(from: state)
            }
        default:
            break
        }
    }

    private func speakCurrentBlockIfNeeded(from state: ReadAloudState) {
        let blockIndex = Int(state.progress.blockIndex)
        let identity = ReaderReadAloudSpeechIdentity(chapterIndex: Int(state.progress.chapterIndex), blockIndex: blockIndex)
        guard let text = blocksByIndex[blockIndex], text.isEmpty == false else {
            Task { await callbacks.fail("当前页没有可朗读的正文段落，请换页或刷新章节后重试") }
            return
        }
        let isResuming = (isManagedSpeechPaused || synthesizer.isPaused) && currentSpeakingIdentity == identity
        // A queued utterance is already owned even before isSpeaking becomes true.
        if !isResuming, currentSpeakingIdentity == identity, currentManagedUtterance != nil {
            return
        }
        let fullText = text as NSString
        let requestedOffset = Int(state.progress.utteranceRangeStart)
        let boundedOffset = min(max(requestedOffset, 0), max(fullText.length - 1, 0))
        let textOffset = fullText.rangeOfComposedCharacterSequence(at: boundedOffset).location
        cancelCurrentSpeech(forceFreshQueue: isResuming)
        currentSpeakingIdentity = identity
        currentUtteranceTextOffset = textOffset
        let utterance = AVSpeechUtterance(string: fullText.substring(from: textOffset))
        let speechRate = currentSpeechRate > 0 ? currentSpeechRate : state.progress.speechRate
        utterance.rate = avSpeechRate(from: speechRate)
        utterance.pitchMultiplier = currentPitchMultiplier
        utterance.prefersAssistiveTechnologySettings = speechRate == 1.0
        utterance.voice = resolveVoice()
        guard prepareAudioPlayback(backgroundPlayback: state.isBackgroundPlaybackEnabled) else {
            currentSpeakingIdentity = nil
            return
        }
        currentManagedUtterance = utterance
        #if DEBUG
        SharedRuntime.log("Read aloud enqueue chapter=\(identity.chapterIndex) block=\(identity.blockIndex) offset=\(textOffset)")
        #endif
        synthesizer.speak(utterance)
    }

    private func pauseSynthesizer() {
        isManagedSpeechPaused = currentManagedUtterance != nil
        if synthesizer.isSpeaking {
            _ = synthesizer.pauseSpeaking(at: .immediate)
        } else if currentManagedUtterance != nil || selectedTextUtterance != nil {
            cancelCurrentSpeech(forceFreshQueue: true)
        }
    }

    private func stopSynthesizer() {
        httpPlayer.stop()
        isHTTPPlaybackActive = false
        cancelCurrentSpeech()
        cancelAutomaticResume()
        playbackGeneration = UUID()
        if !mayClaimAudioOwnership { isPlaybackBlocked = true }
        releaseAudioOwnership()
    }

    private func cancelCurrentSpeech(forceFreshQueue: Bool = false) {
        let isPending = (currentManagedUtterance != nil && !hasFinishedManagedUtterance) || selectedTextUtterance != nil
        let needsFreshQueue = forceFreshQueue || isPending || synthesizer.isSpeaking || synthesizer.isPaused
        currentSpeakingIdentity = nil
        currentManagedUtterance = nil
        selectedTextUtterance = nil
        hasFinishedManagedUtterance = false
        isManagedSpeechPaused = false
        currentUtteranceTextOffset = 0
        guard needsFreshQueue else { return }
        // Replacing interrupted speech needs a fresh queue; a paused queue can otherwise stall its replacement.
        synthesizer.delegate = nil
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = self
    }

    private var ownsAudioPlayback: Bool { MediaPlaybackOwnership.shared.owns(self) }

    private var hasActiveSpeech: Bool {
        isHTTPPlaybackActive || selectedTextUtterance != nil
            || (currentManagedUtterance != nil && !hasFinishedManagedUtterance && !isManagedSpeechPaused)
    }

    private var currentBackgroundPlayback: Bool {
        selectedTextUtterance == nil && currentState?.isBackgroundPlaybackEnabled == true
    }

    private func prepareHTTPPlayback() -> Bool {
        guard let state = currentState, state.engine == .httpTts, state.status == .running else { return false }
        guard prepareAudioPlayback(backgroundPlayback: state.isBackgroundPlaybackEnabled) else { return false }
        isHTTPPlaybackActive = true
        return true
    }

    private func prepareAudioPlayback(backgroundPlayback: Bool) -> Bool {
        guard !isPlaybackBlocked, ownsAudioPlayback || mayClaimAudioOwnership else { return false }
        guard !audioPolicy.isInterrupted, !audioPolicy.shouldPauseForCall else {
            suspendPlayback(automaticallyResume: false)
            return false
        }
        if !ownsAudioPlayback {
            MediaPlaybackOwnership.shared.claim(owner: self) { [weak self] in
                self?.handleOwnershipReplaced()
            }
        }
        guard ownsAudioPlayback, !isPlaybackBlocked else { return false }
        mayClaimAudioOwnership = false
        guard activateAudioSession(backgroundPlayback: backgroundPlayback) else {
            releaseAudioOwnership()
            return false
        }
        return true
    }

    @discardableResult
    private func activateAudioSession(backgroundPlayback: Bool) -> Bool {
        guard ownsAudioPlayback else { return false }
        do {
            try audioPolicy.activate(backgroundPlayback: backgroundPlayback)
            return audioPolicy.isSessionActive
        } catch {
            let message = audioSessionErrorMessage(error, backgroundPlayback: backgroundPlayback)
            isPlaybackBlocked = true
            pauseLocalPlayback()
            releaseAudioOwnership()
            let generation = playbackGeneration
            Task { [weak self] in
                guard let self, generation == playbackGeneration, isPlaybackBlocked else { return }
                await callbacks.fail(message)
            }
            return false
        }
    }

    private func releaseAudioOwnership() {
        audioPolicy.deactivateIfOwned()
        MediaPlaybackOwnership.shared.release(owner: self)
    }

    private func handleOwnershipReplaced() {
        cancelAutomaticResume()
        playbackGeneration = UUID()
        isPlaybackBlocked = true
        mayClaimAudioOwnership = false
        httpPlayer.stop()
        isHTTPPlaybackActive = false
        cancelCurrentSpeech(forceFreshQueue: true)
        // The replacement is synchronous; do not deactivate its process-wide session.
        audioPolicy.invalidateSession()
        synchronizePause()
    }

    private func pauseLocalPlayback() {
        httpPlayer.pause()
        isHTTPPlaybackActive = false
        cancelCurrentSpeech(forceFreshQueue: true)
    }

    private func cancelAutomaticResume() {
        automaticResumeGeneration = nil
        waitsForInterruptionEnd = false
        automaticResumeTask?.cancel()
        automaticResumeTask = nil
    }

    private func synchronizePause() {
        pauseSynchronization?.cancel()
        let generation = playbackGeneration
        pauseSynchronization = Task { [weak self] in
            guard let self, !Task.isCancelled, generation == playbackGeneration else { return }
            await callbacks.pausePlayback()
        }
    }

    private func suspendPlayback(automaticallyResume: Bool) {
        let wasBlocked = isPlaybackBlocked
        let canResumeManagedSpeech =
            automaticallyResume && currentState?.status == .running
            && selectedTextUtterance == nil && ownsAudioPlayback
        if !wasBlocked {
            playbackGeneration = UUID()
            if canResumeManagedSpeech {
                automaticResumeGeneration = playbackGeneration
            } else {
                cancelAutomaticResume()
            }
        } else if !automaticallyResume {
            cancelAutomaticResume()
        }
        isPlaybackBlocked = true
        pauseLocalPlayback()
        audioPolicy.deactivateIfOwned()
        if automaticResumeGeneration == nil { MediaPlaybackOwnership.shared.release(owner: self) }
        if !wasBlocked { synchronizePause() }
    }

    private func handleAudioPolicyEvent(_ event: ReaderReadAloudAudioPolicy.Event) {
        switch event {
        case .interruptionBegan:
            guard ownsAudioPlayback else { return }
            let shouldResume = hasActiveSpeech || automaticResumeGeneration != nil
            suspendPlayback(automaticallyResume: shouldResume)
            if automaticResumeGeneration != nil { waitsForInterruptionEnd = true }
        case let .interruptionEnded(shouldResume):
            guard ownsAudioPlayback, automaticResumeGeneration != nil else { return }
            guard shouldResume else {
                cancelAutomaticResume()
                return
            }
            waitsForInterruptionEnd = false
            resumeAfterSystemPauseIfAllowed()
        case .callActivityChanged:
            guard ownsAudioPlayback else { return }
            if audioPolicy.shouldPauseForCall {
                suspendPlayback(automaticallyResume: hasActiveSpeech || automaticResumeGeneration != nil)
                if audioPolicy.isInterrupted, automaticResumeGeneration != nil { waitsForInterruptionEnd = true }
            } else {
                resumeAfterSystemPauseIfAllowed()
            }
        case .outputUnavailable, .mediaServicesReset:
            guard ownsAudioPlayback else { return }
            suspendPlayback(automaticallyResume: false)
        }
    }

    private func resumeAfterSystemPauseIfAllowed() {
        guard let generation = automaticResumeGeneration, automaticResumeTask == nil,
            ownsAudioPlayback, !waitsForInterruptionEnd,
            !audioPolicy.isInterrupted, !audioPolicy.shouldPauseForCall
        else { return }
        let pendingPause = pauseSynchronization
        automaticResumeTask = Task { [weak self] in
            await pendingPause?.value
            guard let self else { return }
            defer {
                if automaticResumeGeneration == generation { automaticResumeTask = nil }
            }
            guard canAutomaticallyResume(generation) else { return }
            // This is the shared resume command, not updatePlaybackState(false).
            await callbacks.resumePlayback()
            guard canAutomaticallyResume(generation) else {
                if automaticResumeGeneration == generation { automaticResumeTask = nil }
                return
            }
            automaticResumeGeneration = nil
            automaticResumeTask = nil
            isPlaybackBlocked = false
            if let state = currentState, state.status == .running { apply(state: state) }
        }
    }

    private func canAutomaticallyResume(_ generation: UUID) -> Bool {
        !Task.isCancelled && playbackGeneration == generation && automaticResumeGeneration == generation
            && ownsAudioPlayback && !waitsForInterruptionEnd
            && !audioPolicy.isInterrupted && !audioPolicy.shouldPauseForCall
            && (currentState?.status == .paused || currentState?.status == .running)
    }

    private func applySpeechConfigurationChange() {
        guard let currentState, currentState.engine == .systemTts else { return }
        switch currentState.status {
        case .running:
            guard ownsAudioPlayback, !isPlaybackBlocked else { return }
            restartCurrentBlock(from: currentState)
        case .paused:
            cancelManagedSpeechForConfigurationChange()
        default:
            break
        }
    }

    private func restartCurrentBlock(from state: ReadAloudState) {
        cancelManagedSpeechForConfigurationChange()
        speakCurrentBlockIfNeeded(from: state)
    }

    private func cancelManagedSpeechForConfigurationChange() {
        cancelCurrentSpeech()
    }

    private func avSpeechRate(from sharedRate: Float) -> Float {
        let normalizedRate = normalizedSpeechRate(sharedRate)
        guard abs(normalizedRate - 1.0) > 0.001 else {
            return AVSpeechUtteranceDefaultSpeechRate
        }
        if normalizedRate < 1.0 {
            let progress = (normalizedRate - 0.5) / 0.5
            return AVSpeechUtteranceMinimumSpeechRate
                + (AVSpeechUtteranceDefaultSpeechRate - AVSpeechUtteranceMinimumSpeechRate) * min(max(progress, 0), 1)
        }
        let progress = (normalizedRate - 1.0) / 4.0
        return AVSpeechUtteranceDefaultSpeechRate
            + (AVSpeechUtteranceMaximumSpeechRate - AVSpeechUtteranceDefaultSpeechRate) * min(max(progress, 0), 1)
    }

    private func normalizedSpeechRate(_ value: Float) -> Float {
        min(max(value, 0.5), 5.0)
    }

    private func resolveVoice() -> AVSpeechSynthesisVoice? {
        if let preferredVoiceIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: preferredVoiceIdentifier) {
            return voice
        }
        return AVSpeechSynthesisVoice(language: Locale.preferredLanguages.first)
    }

    private func audioSessionErrorMessage(_ error: Error, backgroundPlayback: Bool) -> String {
        let reason = error.userFacingMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let modeText = backgroundPlayback ? "后台朗读" : "朗读"
        if reason.isEmpty {
            return "\(modeText)音频通道启动失败，请检查静音模式、蓝牙或耳机连接后重试"
        }
        return "\(modeText)音频通道启动失败：\(reason)"
    }

    @objc private func handleDidEnterBackground() {
        guard ownsAudioPlayback else { return }
        if !currentBackgroundPlayback {
            suspendPlayback(automaticallyResume: false)
            releaseAudioOwnership()
            return
        }
        Task { await callbacks.updatePlaybackState(true) }
    }

    @objc private func handleWillEnterForeground() {
        guard ownsAudioPlayback else { return }
        Task { await callbacks.updatePlaybackState(false) }
    }
}

extension ReaderReadAloudService: @preconcurrency AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        guard synthesizer === self.synthesizer else { return }
        if !ownsAudioPlayback || isPlaybackBlocked || audioPolicy.isInterrupted || audioPolicy.shouldPauseForCall {
            pauseLocalPlayback()
            return
        }
        guard utterance === currentManagedUtterance else { return }
        #if DEBUG
        if let identity = currentSpeakingIdentity {
            SharedRuntime.log("Read aloud started chapter=\(identity.chapterIndex) block=\(identity.blockIndex) paused=\(synthesizer.isPaused)")
        }
        #endif
        if currentState?.status == .paused {
            pauseSynthesizer()
        }
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        guard synthesizer === self.synthesizer, ownsAudioPlayback, !isPlaybackBlocked,
            utterance === currentManagedUtterance
        else { return }
        let offset = currentUtteranceTextOffset
        let generation = playbackGeneration
        Task { [weak self] in
            guard let self, ownsAudioPlayback, !isPlaybackBlocked,
                generation == playbackGeneration,
                utterance === currentManagedUtterance
            else { return }
            await callbacks.updateCurrentRange(offset + characterRange.location, offset + NSMaxRange(characterRange))
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard synthesizer === self.synthesizer, ownsAudioPlayback, !isPlaybackBlocked else { return }
        if utterance === selectedTextUtterance {
            selectedTextUtterance = nil
            releaseAudioOwnership()
            return
        }
        guard utterance === currentManagedUtterance else { return }
        // Keep ownership until the shared state advances, so late range events cannot requeue this block.
        hasFinishedManagedUtterance = true
        #if DEBUG
        if let identity = currentSpeakingIdentity {
            SharedRuntime.log("Read aloud finished chapter=\(identity.chapterIndex) block=\(identity.blockIndex)")
        }
        #endif
        let generation = playbackGeneration
        Task { [weak self] in
            guard let self, ownsAudioPlayback, !isPlaybackBlocked,
                generation == playbackGeneration,
                utterance === currentManagedUtterance
            else { return }
            await callbacks.advanceToNextBlock()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        guard synthesizer === self.synthesizer, ownsAudioPlayback, !isPlaybackBlocked else { return }
        if utterance === selectedTextUtterance {
            selectedTextUtterance = nil
            releaseAudioOwnership()
            return
        }
        guard utterance === currentManagedUtterance else { return }
        currentManagedUtterance = nil
        Task { await callbacks.updateCurrentRange(0, 0) }
    }

}

private extension String {
    func localizedCaseInsensitiveHasPrefixCompat(_ prefix: String) -> Bool {
        range(
            of: prefix,
            options: [.anchored, .caseInsensitive, .diacriticInsensitive],
            range: startIndex ..< endIndex,
            locale: .current
        ) != nil
    }
}
