import UIKit
import shared

@MainActor
final class ExploreSourceActionCoordinator {
    private weak var presenter: UIViewController?
    private let screen: SourceManagementScreenAdapter
    private let canStart: () -> Bool
    private let onBusyChange: (Bool) -> Void
    private var task: Task<Void, Never>?
    private var presentationID = UUID()

    init(
        presenter: UIViewController, screen: SourceManagementScreenAdapter,
        canStart: @escaping () -> Bool, onBusyChange: @escaping (Bool) -> Void
    ) {
        self.presenter = presenter
        self.screen = screen
        self.canStart = canStart
        self.onBusyChange = onBusyChange
    }

    func invalidatePresentation() { presentationID = UUID() }

    func moveToTop(sourceURL: String) {
        perform { [screen] in
            let sources = try await screen.loadSources()
            let plan = try SourceManagementOrderPlan.make(sources: sources, sourceURLs: [sourceURL], toStart: true)
            for item in plan { try await screen.updateSourceOrder(sourceUrl: item.sourceURL, order: item.order) }
        }
    }

    func login(sourceURL: String) {
        let id = presentationID
        perform { [self] in
            guard let source = try await screen.getSource(sourceUrl: sourceURL), source.hasManagementLoginURL else {
                throw Self.missingSource()
            }
            guard id == presentationID, canStart(), let presenter, presenter.presentedViewController == nil else {
                return
            }
            SourceLoginEntry.open(sourceURL: sourceURL, from: presenter)
        }
    }

    func confirmDelete(sourceURL: String, name: String) {
        guard task == nil, canStart(), let presenter, presenter.presentedViewController == nil,
            let window = presenter.viewIfLoaded?.window, let scene = window.windowScene
        else { return }
        let id = presentationID
        let dialog = ReaderRestoreProgressDialogViewController(
            title: "提醒", message: "是否确认删除？\n" + name,
            accessibilityIdentifierPrefix: "discovery.source.delete"
        ) { [weak self, weak presenter] confirmed in
            guard confirmed, let self, let presenter, self.presenter === presenter,
                id == self.presentationID, self.canStart(), presenter.presentedViewController == nil
            else { return }
            self.delete(sourceURL: sourceURL, id: id)
        }
        dialog.canConfirm = { [weak self, weak presenter, weak dialog, weak window, weak scene] in
            guard let self, let presenter, let dialog, let window, let scene,
                self.presenter === presenter, id == self.presentationID, self.task == nil,
                presenter.viewIfLoaded?.window === window, window.isKeyWindow, !window.isHidden,
                window.alpha > 0.01, window.windowScene === scene, scene.activationState == .foregroundActive,
                UIApplication.shared.applicationState == .active
            else { return false }
            if dialog.presentingViewController == nil {
                return presenter.presentedViewController == nil && self.canStart()
            }
            // canStart deliberately rejects attached modals; recheck it after actual detach instead.
            return presenter.presentedViewController === dialog
                && dialog.presentingViewController?.presentedViewController === dialog
                && dialog.viewIfLoaded?.window === window
        }
        presenter.present(dialog, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    private func delete(sourceURL: String, id: UUID) {
        guard id == presentationID else { return }
        perform { [screen] in
            guard try await screen.getSource(sourceUrl: sourceURL) != nil else { throw Self.missingSource() }
            try await screen.deleteSource(sourceUrl: sourceURL)
        }
    }

    private func perform(_ operation: @escaping () async throws -> Void) {
        guard task == nil, canStart(), presenter?.presentedViewController == nil else { return }
        let id = presentationID
        onBusyChange(true)
        task = Task { @MainActor [self] in
            var failure: Error?
            do { try await operation() } catch { failure = error }
            task = nil
            onBusyChange(false)
            if let failure, id == presentationID, canStart(), presenter?.presentedViewController == nil {
                presenter?.showTransientMessage(failure.userFacingMessage)
            }
        }
    }

    private static func missingSource() -> NSError {
        NSError(domain: "io.legado.discovery", code: 1, userInfo: [NSLocalizedDescriptionKey: "书源列表已更新，请重新选择"])
    }
}
