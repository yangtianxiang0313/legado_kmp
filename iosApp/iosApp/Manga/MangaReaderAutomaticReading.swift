import UIKit

@MainActor
final class MangaReaderAutomaticReading {
    private let driver = MangaAutoReadingController()
    private weak var collection: UICollectionView?
    private let layout: MangaReaderLayout
    private let canInteract: () -> Bool
    private let onStart: () -> Void
    private let onMoved: () -> Void
    private let onEnd: () -> Bool
    private var ownsIdleTimer = false
    private var animatesPages = true

    init(
        collection: UICollectionView, layout: MangaReaderLayout,
        canInteract: @escaping () -> Bool, onStart: @escaping () -> Void,
        onMoved: @escaping () -> Void, onEnd: @escaping () -> Bool
    ) {
        self.collection = collection
        self.layout = layout
        self.canInteract = canInteract
        self.onStart = onStart
        self.onMoved = onMoved
        self.onEnd = onEnd
        driver.onAdvance = { [weak self] mode, elapsed in self?.advance(mode, elapsed: elapsed) ?? false }
        driver.onStateChange = { [weak self] in
            guard let self else { return }
            self.layout.setAutomaticScrolling(self.driver.mode == .continuous)
            if self.driver.isRunning {
                UIApplication.shared.isIdleTimerDisabled = true
                self.ownsIdleTimer = true
            } else if self.ownsIdleTimer {
                UIApplication.shared.isIdleTimerDisabled = RestoredAppPreferences.keepScreenOn
                self.ownsIdleTimer = false
            }
        }
    }

    var mode: MangaAutoReadingController.Mode { driver.mode }
    var isRunning: Bool { driver.isRunning }

    func update(isEligible: Bool, speed: Int, animatesPages: Bool = true) {
        self.speed = max(1, speed)
        self.animatesPages = animatesPages
        driver.update(isEligible: isEligible, speed: speed)
    }

    func stop() { driver.stop() }

    func menuElements() -> [UIMenuElement] {
        let choices: [(String, String, MangaAutoReadingController.Mode)] = [
            ("关闭自动阅读", "stop.circle", .off),
            ("自动翻页", "rectangle.portrait.on.rectangle.portrait", .page),
            ("自动滚动", "arrow.down", .continuous),
        ]
        return choices.map { title, symbol, mode in
            UIAction(
                title: title, image: UIImage(systemName: symbol),
                identifier: UIAction.Identifier("manga.auto.\(mode)"), state: driver.mode == mode ? .on : .off
            ) { [weak self] _ in
                self?.setMode(mode)
            }
        }
    }

    func setMode(_ mode: MangaAutoReadingController.Mode) {
        guard canInteract() else { return }
        driver.setMode(mode)
        if mode != .off { onStart() }
    }

    private func advance(_ mode: MangaAutoReadingController.Mode, elapsed: TimeInterval) -> Bool {
        guard let collection else { return false }
        // Keep the timer alive while a visible bitmap loads, without scrolling through placeholders.
        let cells = collection.visibleCells.compactMap { $0 as? MangaPageCell }
        guard (!cells.isEmpty || layout.hasVisibleChapterTitle), cells.allSatisfy(\.hasLoadedImage) else { return true }
        let offset: CGPoint?
        if mode == .continuous {
            let scale = max(1, collection.window?.screen.scale ?? UIScreen.main.scale)
            offset = layout.autoOffset(distance: CGFloat(elapsed) * CGFloat(speed) * 62.5 / scale)
        } else {
            offset = layout.pageOffset(by: 1)
        }
        guard let offset else { return onEnd() }
        layout.releaseRestoredAnchor()
        let animated = mode == .page && animatesPages && !UIAccessibility.isReduceMotionEnabled
        collection.setContentOffset(offset, animated: animated)
        onMoved()
        return true
    }

    private var speed = 3

}
