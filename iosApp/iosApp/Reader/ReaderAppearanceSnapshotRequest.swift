import Foundation
import shared

/// Subscribe after an awaited command so a transition never opens from an older UI echo.
@MainActor
final class ReaderAppearanceSnapshotRequest {
    private var continuation: CheckedContinuation<ReaderAppearanceState, Error>?
    private var preferences: AppUiPreferences?
    private var runtime: AppRuntimeConfig?
    private var subscriptions: [FlowSubscription] = []
    private var cancelled = false

    static func read(facade: SettingsFacade) async throws -> ReaderAppearanceState {
        let request = ReaderAppearanceSnapshotRequest()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { request.start(facade: facade, continuation: $0) }
        } onCancel: {
            Task { @MainActor in request.cancel() }
        }
    }

    private func start(facade: SettingsFacade, continuation: CheckedContinuation<ReaderAppearanceState, Error>) {
        guard !cancelled else {
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        subscriptions.append(
            facade.watchPreferences { [weak self] value in
                DispatchQueue.main.async {
                    self?.preferences = value
                    self?.finishIfReady()
                }
            })
        subscriptions.append(
            facade.watchRuntimeConfig { [weak self] value in
                DispatchQueue.main.async {
                    self?.runtime = value
                    self?.finishIfReady()
                }
            })
    }

    private func finishIfReady() {
        guard let preferences, let runtime, let continuation else { return }
        self.continuation = nil
        stop()
        continuation.resume(returning: ReaderAppearanceState(preferences: preferences, runtimeConfig: runtime))
    }

    private func cancel() {
        cancelled = true
        let pending = continuation
        continuation = nil
        stop()
        pending?.resume(throwing: CancellationError())
    }

    private func stop() {
        for subscription in subscriptions { subscription.cancel() }
        subscriptions.removeAll()
    }
}
