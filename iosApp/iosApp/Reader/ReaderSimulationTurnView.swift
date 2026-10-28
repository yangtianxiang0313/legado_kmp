import UIKit

final class ReaderSimulationTurnView: UIView {
    private let bitmaps: ReaderPageTurnBitmaps
    private let direction: Int
    private let origin: CGPoint
    private let pixelSize: CGSize
    private let corner: CGPoint
    private let pageBackground: UIColor
    private(set) var touch: CGPoint
    private var displayLink: CADisplayLink?
    private var animation: Animation?

    private struct Animation {
        let start: CGPoint
        let end: CGPoint
        let timestamp: CFTimeInterval
        let duration: CFTimeInterval
        let completion: (Bool) -> Void
    }

    init(
        frame: CGRect, bitmaps: ReaderPageTurnBitmaps, direction: Int,
        origin: CGPoint, touch: CGPoint, backgroundColor: UIColor
    ) {
        self.bitmaps = bitmaps
        self.direction = direction
        self.origin = CGPoint(x: origin.x * bitmaps.displayScale, y: origin.y * bitmaps.displayScale)
        pixelSize = CGSize(width: frame.width * bitmaps.displayScale, height: frame.height * bitmaps.displayScale)
        let cornerX = max(origin.x, frame.width - origin.x)
        corner = CGPoint(
            x: cornerX <= frame.width / 2 ? 0 : pixelSize.width,
            y: direction < 0 || origin.y > frame.height / 2 ? pixelSize.height : 0
        )
        self.touch = CGPoint(x: touch.x * bitmaps.displayScale, y: touch.y * bitmaps.displayScale)
        pageBackground = backgroundColor
        super.init(frame: frame)
        self.backgroundColor = backgroundColor
        contentScaleFactor = bitmaps.displayScale
        isOpaque = true
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { nil }

    func update(touch point: CGPoint) {
        guard animation == nil, point.x.isFinite, point.y.isFinite else { return }
        touch = CGPoint(x: point.x * bitmaps.displayScale, y: point.y * bitmaps.displayScale)
        if (origin.y > pixelSize.height / 3 && origin.y < pixelSize.height * 2 / 3) || direction < 0 {
            touch.y = pixelSize.height
        }
        if origin.y > pixelSize.height / 3 && origin.y < pixelSize.height / 2 && direction > 0 { touch.y = 1 }
        setNeedsDisplay()
    }

    func animate(commit: Bool, completion: @escaping (Bool) -> Void) {
        stop()
        let endX: CGFloat
        if commit {
            endX = corner.x > 0 && direction > 0 ? -pixelSize.width : pixelSize.width
        } else {
            endX = direction < 0 ? -pixelSize.width : (corner.x > 0 ? pixelSize.width : 0)
        }
        let endY = corner.y > 0 ? pixelSize.height : (commit ? 1 : 0)
        let duration = ReaderPageTurnGestureDecision.animationDuration(
            horizontalDistance: endX - touch.x, verticalDistance: endY - touch.y, bounds: pixelSize)
        animation = Animation(
            start: touch, end: CGPoint(x: endX, y: endY), timestamp: CACurrentMediaTime(),
            duration: duration, completion: completion
        )
        let proxy = DisplayLinkTarget(view: self)
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkTarget.tick(_:)))
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        animation = nil
    }

    fileprivate func tick(_ link: CADisplayLink) {
        guard let animation else {
            stop()
            return
        }
        let progress = animation.duration > 0 ? min(max((link.targetTimestamp - animation.timestamp) / animation.duration, 0), 1) : 1
        touch = CGPoint(
            x: animation.start.x + (animation.end.x - animation.start.x) * progress,
            y: animation.start.y + (animation.end.y - animation.start.y) * progress
        )
        setNeedsDisplay()
        if progress >= 1 {
            stop()
            animation.completion(true)
        }
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.scaleBy(x: 1 / bitmaps.displayScale, y: 1 / bitmaps.displayScale)
        let pixelRect = CGRect(origin: .zero, size: pixelSize)
        let folding = direction > 0 ? bitmaps.outgoing : bitmaps.incoming
        let revealed = direction > 0 ? bitmaps.incoming : bitmaps.outgoing
        // Always backfill the full viewport, including degenerate start/end frames.
        revealed.draw(in: pixelRect)
        if corner.x > 0 && touch.x <= -pixelSize.width { return }
        if (corner.x > 0 && touch.x >= pixelSize.width) || (corner.x == 0 && touch.x <= 0) {
            folding.draw(in: pixelRect)
            return
        }
        guard let geometry = ReaderSimulationGeometry(size: pixelSize, touch: touch, corner: corner) else {
            if direction > 0 { bitmaps.outgoing.draw(in: pixelRect) }
            return
        }
        ReaderSimulationRenderer.draw(
            geometry, in: context, folding: folding, revealed: revealed, background: pageBackground)
    }

    private final class DisplayLinkTarget: NSObject {
        weak var view: ReaderSimulationTurnView?
        init(view: ReaderSimulationTurnView) { self.view = view }
        @objc func tick(_ link: CADisplayLink) {
            guard let view else {
                link.invalidate()
                return
            }
            view.tick(link)
        }
    }
}
