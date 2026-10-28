import AVFoundation
import CallKit

/// iOS audio policy only; the service decides whether it still owns playback.
@MainActor
final class ReaderReadAloudAudioPolicy: NSObject {
    enum Event {
        case interruptionBegan
        case interruptionEnded(shouldResume: Bool)
        case outputUnavailable
        case mediaServicesReset
        case callActivityChanged
    }

    private struct Configuration: Equatable {
        let backgroundPlayback: Bool
        let ignoreAudioFocus: Bool
    }

    private let ownsPlayback: @MainActor () -> Bool
    private let onEvent: @MainActor (Event) -> Void
    private var callObserver: CXCallObserver?
    private var hasActiveCall = false
    private var configuration: Configuration?
    private(set) var isSessionActive = false
    private(set) var isInterrupted = false
    private var ignoreAudioFocus = false
    private var pauseWhilePhoneCalls = false

    var shouldPauseForCall: Bool {
        ignoreAudioFocus && pauseWhilePhoneCalls && hasActiveCall
    }

    init(
        ownsPlayback: @escaping @MainActor () -> Bool,
        onEvent: @escaping @MainActor (Event) -> Void
    ) {
        self.ownsPlayback = ownsPlayback
        self.onEvent = onEvent
        super.init()
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        center.addObserver(
            self, selector: #selector(interruption(_:)), name: AVAudioSession.interruptionNotification, object: session)
        center.addObserver(
            self, selector: #selector(routeChanged(_:)), name: AVAudioSession.routeChangeNotification, object: session)
        center.addObserver(
            self, selector: #selector(mediaServicesReset), name: AVAudioSession.mediaServicesWereResetNotification,
            object: session)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func update(ignoreAudioFocus: Bool, pauseWhilePhoneCalls: Bool) {
        let wasPausingForCall = shouldPauseForCall
        self.ignoreAudioFocus = ignoreAudioFocus
        self.pauseWhilePhoneCalls = pauseWhilePhoneCalls
        if ignoreAudioFocus && pauseWhilePhoneCalls {
            if callObserver == nil {
                let observer = CXCallObserver()
                callObserver = observer
                observer.setDelegate(self, queue: .main)
            }
            refreshCallActivity()
        } else {
            callObserver?.setDelegate(nil, queue: nil)
            callObserver = nil
            hasActiveCall = false
        }
        if wasPausingForCall != shouldPauseForCall {
            onEvent(.callActivityChanged)
        }
    }

    func activate(backgroundPlayback: Bool) throws {
        guard ownsPlayback(), !isInterrupted, !shouldPauseForCall else { return }
        let desired = Configuration(backgroundPlayback: backgroundPlayback, ignoreAudioFocus: ignoreAudioFocus)
        let session = AVAudioSession.sharedInstance()
        if configuration != desired {
            // Foreground-only speech is paused by the service on entering the background.
            let usesPlaybackCategory = backgroundPlayback || ignoreAudioFocus
            let category: AVAudioSession.Category = usesPlaybackCategory ? .playback : .soloAmbient
            let options: AVAudioSession.CategoryOptions = ignoreAudioFocus ? [.mixWithOthers] : []
            try session.setCategory(category, mode: usesPlaybackCategory ? .spokenAudio : .default, options: options)
            configuration = desired
        }
        if !isSessionActive {
            try session.setActive(true)
            isSessionActive = true
        }
    }

    func deactivateIfOwned() {
        guard ownsPlayback() else {
            invalidateSession()
            return
        }
        let shouldDeactivate = isSessionActive
        invalidateSession()
        if shouldDeactivate {
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }

    /// Forget our cache without touching the next owner's process-wide audio session.
    func invalidateSession() {
        configuration = nil
        isSessionActive = false
    }

    private func refreshCallActivity() {
        // CXCall exposes call state, not a phone number. Keep only the aggregate busy flag.
        hasActiveCall = callObserver?.calls.contains { !$0.hasEnded } == true
    }

    @objc nonisolated private func interruption(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else { return }
        let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        DispatchQueue.main.async { [weak self] in
            self?.handleInterruption(type: raw, options: rawOptions)
        }
    }

    private func handleInterruption(type raw: UInt, options rawOptions: UInt) {
        guard let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            isInterrupted = true
            invalidateSession()
            onEvent(.interruptionBegan)
        case .ended:
            isInterrupted = false
            invalidateSession()
            onEvent(
                .interruptionEnded(shouldResume: AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume))
            )
        @unknown default:
            break
        }
    }

    @objc nonisolated private func routeChanged(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
            AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable
        else { return }
        DispatchQueue.main.async { [weak self] in self?.onEvent(.outputUnavailable) }
    }

    @objc nonisolated private func mediaServicesReset() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            isInterrupted = false
            invalidateSession()
            onEvent(.mediaServicesReset)
        }
    }
}

extension ReaderReadAloudAudioPolicy: @preconcurrency CXCallObserverDelegate {
    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        guard callObserver === self.callObserver else { return }
        let wasActive = hasActiveCall
        refreshCallActivity()
        if wasActive != hasActiveCall {
            onEvent(.callActivityChanged)
        }
    }
}
