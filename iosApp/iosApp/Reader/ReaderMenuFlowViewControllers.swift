import shared
import SnapKit
import Then
import UIKit

class ReaderSettingsBoundViewController: UIViewController {
    let screen = ReaderAppearanceScreenAdapter()
    let stateView = ContentStateView()
    var state: ReaderAppearanceState?
    private var bootstrapTask: Task<Void, Never>?
    private var settingTasks: [Task<Void, Never>] = []

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        cancelBootstrapTask()
        cancelSettingTasks()
    }

    deinit {
        cancelBootstrapTask()
        cancelSettingTasks()
        screen.unbind()
    }

    func bootstrapReaderSettings() {
        screen.onStateChange = { [weak self] state in
            self?.state = state
            self?.apply(state)
        }
        switch screen.bootstrap() {
        case .success:
            stateView.hide()
            cancelBootstrapTask()
            bootstrapTask = Task { [weak self] in
                do {
                    try await self?.screen.bootstrapDefaultsIfNeeded()
                } catch is CancellationError {
                    return
                } catch {
                    await MainActor.run {
                        guard let self, self.view.window != nil else { return }
                        self.stateView.showMessage(
                            title: L10n.ReaderAppearance.unavailable,
                            message: error.userFacingMessage,
                            actionTitle: L10n.Common.retry
                        ) { [weak self] in
                            self?.bootstrapReaderSettings()
                        }
                    }
                }
            }
        case let .failure(error):
            stateView.showMessage(
                title: L10n.ReaderAppearance.unavailable,
                message: error.userFacingMessage,
                actionTitle: L10n.Common.retry
            ) { [weak self] in
                self?.bootstrapReaderSettings()
            }
        }
    }

    func apply(_: ReaderAppearanceState) {}

    func runSettingTask(_ operation: @escaping () async throws -> Void) {
        settingTasks.removeAll { $0.isCancelled }
        let task = Task { [weak self] in
            do {
                try await operation()
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    guard let self, self.view.window != nil else { return }
                    self.presentError(error)
                }
            }
        }
        settingTasks.append(task)
    }

    private func cancelSettingTasks() {
        settingTasks.forEach { $0.cancel() }
        settingTasks.removeAll()
    }

    private func cancelBootstrapTask() {
        bootstrapTask?.cancel()
        bootstrapTask = nil
    }
}
