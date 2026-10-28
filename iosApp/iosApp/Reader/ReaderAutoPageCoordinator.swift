import UIKit
import shared

@MainActor
final class ReaderAutoPageCoordinator {
    private weak var reader: ReaderContainerViewController?
    private weak var panel: ReaderAutoReadSheetViewController?
    private var startTask: Task<Void, Never>?
    private var startID: UUID?
    private lazy var motion = reader.map { reader in
        ReaderAutoPageMotion(reader: reader, speed: { [weak self] in self?.currentSpeed ?? 20 })
    }
    private var isConfiguringAnimation = false
    private var isInteracting = false
    private var speedSaveTask: Task<Void, Never>?
    private var pendingSpeed: Int?
    private var sceneObserver: NSObjectProtocol?

    init(reader: ReaderContainerViewController) {
        self.reader = reader
        sceneObserver = NotificationCenter.default.addObserver(
            forName: UIScene.willDeactivateNotification, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let scene = notification.object as? UIScene,
                    scene === self.reader?.viewIfLoaded?.window?.windowScene
                else { return }
                self.stop(showMessage: false)
            }
        }
    }

    deinit {
        startTask?.cancel()
        if let sceneObserver { NotificationCenter.default.removeObserver(sceneObserver) }
    }

    var currentSpeed: Int {
        guard let reader else { return 20 }
        return min(
            120,
            max(
                1,
                reader.autoReadSpeedOverride
                    ?? UserDefaults.standard.object(
                        forKey: ReaderContainerViewController.autoReadSpeedUserDefaultsKey) as? Int
                    ?? Int(reader.runtimeConfig?.reader.autoReadSpeed ?? 20)))
    }

    func toggleFromMenu() {
        guard let reader else { return }
        reader.setMenuVisible(false)
        if reader.isAutoPageRunning || startID != nil {
            stop(showMessage: true)
        } else {
            start()
        }
    }

    func start() {
        guard let reader, canUse(reader), reader.presentedViewController == nil,
            !reader.isAutoPageRunning, startID == nil
        else { return }
        guard !reader.pages.isEmpty else {
            reader.showToast(L10n.BookDetail.emptyChapters)
            return
        }
        let id = UUID()
        let bookURL = reader.bookURL
        let origin = reader.book?.origin
        startID = id
        startTask = Task { @MainActor [weak self, weak reader] in
            guard let self, let reader else { return }
            defer {
                if self.startID == id {
                    self.startID = nil
                    self.startTask = nil
                }
            }
            do {
                if reader.readAloudState?.status == .running || reader.readAloudState?.status == .paused {
                    try await reader.screen.stopReadAloud()
                }
                try Task.checkCancellation()
                guard self.startID == id, self.canUse(reader), reader.presentedViewController == nil,
                    reader.bookURL == bookURL, reader.book?.origin == origin, !reader.pages.isEmpty
                else { return }
                reader.dismissTextSelectionMenu(clearSelection: true)
                reader.isAutoPageRunning = true
                reader.readMenu.setAutoPageRunning(true)
                reader.applyReaderScreenTimeout(.always)
                self.motion?.start()
                self.updatePausedState()
            } catch {
                if !(error is CancellationError), self.startID == id, self.canUse(reader) {
                    reader.showToast(error.userFacingMessage)
                }
            }
        }
    }

    func stop(showMessage: Bool) {
        startID = nil
        startTask?.cancel()
        startTask = nil
        motion?.stop()
        isConfiguringAnimation = false
        isInteracting = false
        guard let reader else { return }
        let wasRunning = reader.isAutoPageRunning
        reader.isAutoPageRunning = false
        reader.autoPageAdvanceInFlight = false
        reader.readMenu.setAutoPageRunning(false)
        if let panel, panel.presentingViewController?.presentedViewController === panel {
            panel.dismiss(animated: true)
        }
        if wasRunning {
            if canUse(reader) {
                reader.resetReaderScreenTimeoutTimer()
            } else {
                reader.cancelReaderScreenTimeout()
            }
            if showMessage { reader.showToast(L10n.Reader.autoPageStop) }
        }
    }

    func presentPanel() {
        guard let reader, reader.isAutoPageRunning, canUse(reader),
            reader.presentedViewController == nil
        else { return }
        reader.setMenuVisible(false)
        let bookURL = reader.bookURL
        let origin = reader.book?.origin
        let accepts: () -> Bool = { [weak self, weak reader] in
            guard let self, let reader else { return false }
            return self.canUse(reader) && reader.isAutoPageRunning && reader.bookURL == bookURL
                && reader.book?.origin == origin
        }
        let controller = ReaderAutoReadSheetViewController(
            currentSpeed: currentSpeed,
            onStop: { [weak self] in if accepts() { self?.stop(showMessage: false) } },
            onOpenChapterList: { [weak self, weak reader] in
                guard accepts() else { return }
                self?.stop(showMessage: false)
                reader?.showChapterPicker()
            },
            onOpenMainMenu: { [weak reader] in if accepts() { reader?.setMenuVisible(true) } },
            onOpenPageAnimation: { [weak self, weak reader] in
                guard accepts(), let panel = self?.panel else { return }
                reader?.pageAnimationSelectionCoordinator.present(from: panel)
            },
            onSpeedSelected: { [weak self] speed in if accepts() { self?.saveSpeed(speed) } })
        controller.overrideUserInterfaceStyle = reader.traitCollection.userInterfaceStyle
        panel = controller
        controller.onClose = { [weak self, weak controller] in
            if self?.panel === controller { self?.panel = nil }
        }
        reader.present(controller, animated: true)
    }

    func ownsPanel(_ controller: UIViewController) -> Bool {
        guard let panel, panel === controller,
            panel.presentingViewController?.presentedViewController === panel,
            !panel.isBeingDismissed, panel.viewIfLoaded?.window != nil
        else { return false }
        return true
    }

    func menuVisibilityDidChange(_ visible: Bool) {
        guard reader?.isAutoPageRunning == true else { return }
        updatePausedState()
    }

    func setConfiguringAnimation(_ configuring: Bool) {
        isConfiguringAnimation = configuring
        updatePausedState()
    }

    func setGestureInteracting(_ interacting: Bool) {
        isInteracting = interacting
        updatePausedState()
    }

    func contentWillChange() { motion?.contentWillChange() }
    func chapterWillLoad(_ index: Int) { motion?.chapterWillLoad(index) }
    func contentDidRender() { motion?.contentDidRender() }

    private func updatePausedState() {
        motion?.setPaused(reader?.isMenuVisible == true || isConfiguringAnimation || isInteracting)
    }

    func saveSpeed(_ speed: Int) {
        guard let reader else { return }
        let value = min(120, max(1, speed))
        reader.autoReadSpeedOverride = value
        pendingSpeed = value
        motion?.speedDidChange()
        guard speedSaveTask == nil else { return }
        let screen = reader.screen
        // Release events are serialized; leaving the panel cannot discard an accepted save.
        speedSaveTask = Task { @MainActor [self] in
            defer { speedSaveTask = nil }
            while let value = pendingSpeed {
                pendingSpeed = nil
                do {
                    try await screen.setAutoReadSpeed(value: Int32(value))
                    UserDefaults.standard.set(
                        value, forKey: ReaderContainerViewController.autoReadSpeedUserDefaultsKey)
                } catch {
                    guard let reader = self.reader else { continue }
                    if reader.autoReadSpeedOverride == value, pendingSpeed == nil {
                        reader.autoReadSpeedOverride = nil
                        panel?.updateSpeed(currentSpeed)
                        motion?.speedDidChange()
                    }
                    if canUse(reader) { reader.showToast(error.userFacingMessage) }
                }
            }
        }
    }

    private func canUse(_ reader: ReaderContainerViewController) -> Bool {
        !reader.isMovingFromParent && !reader.isBeingDismissed
            && reader.navigationController?.isBeingDismissed != true
            && reader.navigationController?.topViewController === reader
            && reader.viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive
    }
}

extension ReaderContainerViewController {
    static var autoReadSpeedUserDefaultsKey: String { "reader.autoRead.speed" }

    func showAutoPageSheet() { autoPageCoordinator.presentPanel() }
    func toggleAutoPageFromMenu() { autoPageCoordinator.toggleFromMenu() }
    func stopAutoPage(showMessage: Bool) { autoPageCoordinator.stop(showMessage: showMessage) }

    func showReaderActionMenu() {
        if isMenuVisible {
            setMenuVisible(false)
        } else if isAutoPageRunning {
            showAutoPageSheet()
        } else if jumpNavigationCoordinator.isShowingSearchResults && searchMenu.hasResults {
            searchMenu.setVisible(true, currentChapterIndex: chapterIndex)
        } else {
            setMenuVisible(!isMenuVisible)
        }
    }
}
