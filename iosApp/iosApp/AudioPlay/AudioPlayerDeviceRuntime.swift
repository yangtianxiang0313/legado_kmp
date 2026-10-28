import AVFoundation
import MediaPlayer

@MainActor
final class AudioPlayerDeviceRuntime {
    enum Event: Sendable {
        case interruptionBegan
        case interruptionEnded(shouldResume: Bool)
        case outputRemoved
        case mediaServicesLost
        case mediaServicesReset
    }

    enum RemoteAction: Sendable {
        case play, pause, toggle, previous, next, stop
        case seek(TimeInterval)
    }

    private let notifications = AudioPlayerRuntimeCleanup()
    private let commands = AudioPlayerRuntimeCleanup()

    init(event: @escaping @MainActor (Event) -> Void) {
        observe(AVAudioSession.interruptionNotification) { notification in
            guard let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                let type = AVAudioSession.InterruptionType(rawValue: value)
            else { return }
            switch type {
            case .began:
                event(.interruptionBegan)
            case .ended:
                let raw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                event(.interruptionEnded(shouldResume: AVAudioSession.InterruptionOptions(rawValue: raw).contains(.shouldResume)))
            @unknown default:
                break
            }
        }
        observe(AVAudioSession.routeChangeNotification) { notification in
            guard let value = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                AVAudioSession.RouteChangeReason(rawValue: value) == .oldDeviceUnavailable
            else { return }
            event(.outputRemoved)
        }
        observe(AVAudioSession.mediaServicesWereLostNotification) { _ in event(.mediaServicesLost) }
        observe(AVAudioSession.mediaServicesWereResetNotification) { _ in event(.mediaServicesReset) }
    }

    static func activateAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
    }

    func installRemoteCommands(handler: @escaping @MainActor (RemoteAction) -> MPRemoteCommandHandlerStatus) {
        commands.cancel()
        let center = MPRemoteCommandCenter.shared()
        addTarget(center.playCommand, action: .play, handler: handler)
        addTarget(center.pauseCommand, action: .pause, handler: handler)
        addTarget(center.togglePlayPauseCommand, action: .toggle, handler: handler)
        addTarget(center.previousTrackCommand, action: .previous, handler: handler)
        addTarget(center.nextTrackCommand, action: .next, handler: handler)
        addTarget(center.stopCommand, action: .stop, handler: handler)
        let target = center.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            return Self.onMainActor { handler(.seek(position)) }
        }
        let command = center.changePlaybackPositionCommand
        commands.add { command.removeTarget(target) }
    }

    func updateRemoteAvailability(
        canPlay: Bool, canPause: Bool, canStop: Bool, canPrevious: Bool, canNext: Bool, canSeek: Bool
    ) {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = canPlay
        center.pauseCommand.isEnabled = canPause
        center.togglePlayPauseCommand.isEnabled = canPlay || canPause
        center.stopCommand.isEnabled = canStop
        center.previousTrackCommand.isEnabled = canPrevious
        center.nextTrackCommand.isEnabled = canNext
        center.changePlaybackPositionCommand.isEnabled = canSeek
    }

    func invalidate() {
        // Remove our tokens only; never disable commands that a new owner may already use.
        commands.cancel()
        notifications.cancel()
    }

    private func addTarget(
        _ command: MPRemoteCommand, action: RemoteAction,
        handler: @escaping @MainActor (RemoteAction) -> MPRemoteCommandHandlerStatus
    ) {
        let target = command.addTarget { _ in Self.onMainActor { handler(action) } }
        commands.add { command.removeTarget(target) }
    }

    private func observe(_ name: Notification.Name, action: @escaping @MainActor (Notification) -> Void) {
        let observer = NotificationCenter.default.addObserver(
            forName: name, object: nil, queue: .main
        ) { notification in
            MainActor.assumeIsolated { action(notification) }
        }
        notifications.add { NotificationCenter.default.removeObserver(observer) }
    }

    // Remote handlers return synchronously; an async Task would report success before
    // ownership and seekability were checked, and could target an already-replaced engine.
    nonisolated static func onMainActor<Value: Sendable>(_ action: @MainActor () -> Value) -> Value {
        if Thread.isMainThread { return MainActor.assumeIsolated { action() } }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { action() } }
    }
}
