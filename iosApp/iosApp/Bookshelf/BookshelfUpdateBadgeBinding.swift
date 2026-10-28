import Foundation
import shared

@MainActor
final class BookshelfUpdateBadgeBinding {
    private let updates: BookshelfUpdateCoordinator
    private let onChange: (Int) -> Void
    private var updateObserver: UUID?
    private var preferencesSubscription: FlowSubscription?
    private var showsCount = false
    private(set) var displayedCount = 0

    init(updates: BookshelfUpdateCoordinator = .shared, onChange: @escaping (Int) -> Void) {
        self.updates = updates
        self.onChange = onChange
    }

    deinit {
        preferencesSubscription?.cancel()
        if let updateObserver {
            let updates = updates
            Task { @MainActor in updates.removeObserver(updateObserver) }
        }
    }

    func start() {
        if updateObserver == nil {
            updateObserver = updates.observe { [weak self] _ in self?.render() }
        }
        guard preferencesSubscription == nil else { return }
        do {
            preferencesSubscription = try SharedRuntime.settingsFacade().get().watchPreferences { [weak self] value in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.showsCount = value.showWaitUpCount
                    self.render()
                }
            }
        } catch {
            SharedRuntime.log("书架更新数量偏好加载失败: \(error.userFacingMessage)")
        }
    }

    private func render() {
        let count = showsCount ? updates.snapshot.pendingCount : 0
        guard count != displayedCount else { return }
        displayedCount = count
        onChange(count)
    }
}
