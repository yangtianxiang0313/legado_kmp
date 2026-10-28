import UIKit

struct ReaderPageTurnGestureDecision {
    struct Context: Equatable {
        let bookURL: String
        let chapterIndex: Int
        let chapterURL: String?
        let pageIndex: Int
        let bounds: CGRect
        let style: Int
    }

    struct Update {
        let direction: Int
        let origin: CGPoint
        let offset: CGFloat
        let touch: CGPoint
    }

    private(set) var context: Context?
    private var direction: Int?
    private var origin = CGPoint.zero
    private var previousTouch = CGPoint.zero
    private var currentTouch = CGPoint.zero
    private var isCancelled = false

    mutating func begin(in context: Context) {
        reset()
        self.context = context
    }

    mutating func move(translation: CGPoint, touch: CGPoint, slop: CGFloat) -> Update? {
        guard let context, translation.x.isFinite, translation.y.isFinite,
            touch.x.isFinite, touch.y.isFinite, slop.isFinite, slop >= 0,
            context.bounds.width.isFinite, context.bounds.height.isFinite,
            context.bounds.width > 0, context.bounds.height > 0
        else {
            reset()
            return nil
        }
        let vertical = context.style == 3
        if direction == nil {
            guard hypot(translation.x, translation.y) > slop else { return nil }
            direction = (vertical ? translation.y : translation.x) > 0 ? -1 : 1
            // HorizontalPageDelegate rebases start/last/touch at the threshold crossing.
            origin = touch
            previousTouch = touch
            currentTouch = touch
        }
        guard let direction else { return nil }
        let primary = vertical ? touch.y : touch.x
        let previous = vertical ? previousTouch.y : previousTouch.x
        // ReadView advances lastTouch from the prior touch only after deciding cancellation.
        isCancelled = direction > 0 ? primary > previous : primary < previous
        previousTouch = currentTouch
        currentTouch = touch
        return Update(
            direction: direction, origin: origin,
            offset: primary - (vertical ? origin.y : origin.x), touch: touch)
    }

    mutating func finish(in context: Context) -> Int? {
        defer { reset() }
        guard self.context == context, !isCancelled else { return nil }
        return direction
    }

    mutating func reset() {
        context = nil
        direction = nil
        origin = .zero
        previousTouch = .zero
        currentTouch = .zero
        isCancelled = false
    }

    static func animationDuration(horizontalDistance: CGFloat, verticalDistance: CGFloat, bounds: CGSize) -> TimeInterval {
        guard horizontalDistance.isFinite, verticalDistance.isFinite,
            bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0
        else { return 0 }
        // PageDelegate.startScroll uses the 300ms default, scaled by remaining travel.
        return 0.3 * (horizontalDistance != 0 ? abs(horizontalDistance) / bounds.width : abs(verticalDistance) / bounds.height)
    }
}
