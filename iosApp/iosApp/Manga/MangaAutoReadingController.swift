import UIKit

@MainActor
final class MangaAutoReadingController {
    enum Mode: Equatable {
        case off, continuous, page
    }

    private(set) var mode: Mode = .off
    private(set) var isRunning = false
    var onStateChange: (() -> Void)?
    // Continuous mode supplies seconds; its caller advances by speed * dt / 0.016.
    var onAdvance: ((Mode, TimeInterval) -> Bool)?

    private var isEligible = false
    private var speed = 3
    private var displayLink: CADisplayLink?
    private var displayTarget: DisplayTarget?
    private var previousTimestamp: CFTimeInterval?
    private var pageElapsed: TimeInterval = 0

    deinit { displayLink?.invalidate() }

    func setMode(_ mode: Mode) {
        guard self.mode != mode else { return }
        self.mode = mode
        resetTiming()
        synchronizeRunningState(modeChanged: true)
    }

    func update(isEligible: Bool, speed: Int) {
        let speed = max(1, speed)
        guard self.isEligible != isEligible || self.speed != speed else { return }
        self.isEligible = isEligible
        self.speed = speed
        resetTiming()
        synchronizeRunningState()
    }

    func stop() { setMode(.off) }

    private func synchronizeRunningState(modeChanged: Bool = false) {
        let wasRunning = isRunning
        isRunning = mode != .off && isEligible
        if isRunning {
            if displayLink == nil {
                let target = DisplayTarget(owner: self)
                let link = CADisplayLink(target: target, selector: #selector(DisplayTarget.tick(_:)))
                displayTarget = target
                displayLink = link
                link.add(to: .main, forMode: .common)
            }
        } else {
            displayLink?.invalidate()
            displayLink = nil
            displayTarget = nil
            resetTiming()
        }
        if modeChanged || wasRunning != isRunning { onStateChange?() }
    }

    private func resetTiming() {
        previousTimestamp = nil
        pageElapsed = 0
    }

    private func tick(_ link: CADisplayLink) {
        guard isRunning, link === displayLink else { return }
        let timestamp = link.timestamp
        guard timestamp.isFinite else {
            resetTiming()
            return
        }
        guard let previousTimestamp else {
            self.previousTimestamp = timestamp
            return
        }
        self.previousTimestamp = timestamp
        let elapsed = timestamp - previousTimestamp
        // Discard suspension gaps rather than jumping or replaying queued page turns.
        guard elapsed > 0, elapsed <= 0.25 else {
            resetTiming()
            return
        }

        switch mode {
        case .off:
            return
        case .continuous:
            if onAdvance?(.continuous, min(elapsed, 0.05)) != true { stop() }
        case .page:
            pageElapsed += elapsed
            guard pageElapsed >= TimeInterval(speed) else { return }
            pageElapsed = 0
            if onAdvance?(.page, 0) != true { stop() }
        }
    }

    @MainActor private final class DisplayTarget: NSObject {
        weak var owner: MangaAutoReadingController?

        init(owner: MangaAutoReadingController) { self.owner = owner }

        @objc func tick(_ link: CADisplayLink) {
            guard let owner else {
                link.invalidate()
                return
            }
            owner.tick(link)
        }
    }
}
