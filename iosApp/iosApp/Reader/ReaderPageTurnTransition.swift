import UIKit

final class ReaderPageTurnTransition {
    let sourceIndex: Int
    let targetIndex: Int
    let bookURL: String
    let chapterIndex: Int
    let chapterURL: String?
    let bounds: CGRect
    let direction: Int
    let vertical: Bool
    let style: Int
    let outgoing: UIView
    let incoming: ReaderRenderView
    let coverViewport: UIView?
    var simulationView: ReaderSimulationTurnView?
    private var coverShadowLayer: CAGradientLayer?
    var isFinishing = false
    var commitsPage = false
    var progress: CGFloat = 0

    init(
        sourceIndex: Int, targetIndex: Int, bookURL: String, chapterIndex: Int, chapterURL: String?,
        bounds: CGRect, direction: Int, vertical: Bool, style: Int,
        outgoing: UIView, incoming: ReaderRenderView
    ) {
        self.sourceIndex = sourceIndex
        self.targetIndex = targetIndex
        self.bookURL = bookURL
        self.chapterIndex = chapterIndex
        self.chapterURL = chapterURL
        self.bounds = bounds
        self.direction = direction
        self.vertical = vertical
        self.style = style
        self.outgoing = outgoing
        self.incoming = incoming
        if style == 0 {
            let viewport = UIView(frame: incoming.frame)
            viewport.bounds = bounds
            viewport.clipsToBounds = true
            viewport.isUserInteractionEnabled = false
            viewport.accessibilityElementsHidden = true
            coverViewport = viewport
        } else {
            coverViewport = nil
        }
    }

    var travel: CGFloat { vertical ? bounds.height : bounds.width }

    var coverIncomingAboveOutgoing: Bool { style == 0 && direction < 0 }

    func outgoingTransform(progress: CGFloat) -> CGAffineTransform {
        // Android CoverPageDelegate.PREV moves only the previous page over the current page.
        guard !coverIncomingAboveOutgoing else { return .identity }
        let distance = -CGFloat(direction) * travel * boundedProgress(progress)
        return vertical
            ? CGAffineTransform(translationX: 0, y: distance) : CGAffineTransform(translationX: distance, y: 0)
    }

    func incomingTransform(progress: CGFloat) -> CGAffineTransform {
        guard style == 1 || style == 3 || coverIncomingAboveOutgoing else { return .identity }
        let remaining = CGFloat(direction) * travel * (1 - boundedProgress(progress))
        return vertical
            ? CGAffineTransform(translationX: 0, y: remaining) : CGAffineTransform(translationX: remaining, y: 0)
    }

    func installCoverShadow(displayScale: CGFloat) {
        guard style == 0 else { return }
        removeCoverShadow()
        let coveringPage: UIView = coverIncomingAboveOutgoing ? incoming : outgoing
        let shadow = CAGradientLayer()
        let scale = displayScale.isFinite && displayScale > 0 ? displayScale : 1
        shadow.contentsScale = scale
        // Android uses a 30-pixel LEFT_RIGHT gradient from 0x66111111 to transparent.
        shadow.frame = CGRect(
            x: coveringPage.bounds.maxX, y: coveringPage.bounds.minY,
            width: 30 / scale, height: coveringPage.bounds.height
        )
        shadow.colors = [
            UIColor(red: 17 / 255, green: 17 / 255, blue: 17 / 255, alpha: 102 / 255).cgColor,
            UIColor.clear.cgColor,
        ]
        shadow.startPoint = CGPoint(x: 0, y: 0.5)
        shadow.endPoint = CGPoint(x: 1, y: 0.5)
        coveringPage.clipsToBounds = false
        coveringPage.layer.addSublayer(shadow)
        coverShadowLayer = shadow
    }

    func removeCoverShadow() {
        coverShadowLayer?.removeAllAnimations()
        coverShadowLayer?.removeFromSuperlayer()
        coverShadowLayer = nil
    }

    private func boundedProgress(_ progress: CGFloat) -> CGFloat {
        progress.isFinite ? min(max(progress, 0), 1) : 0
    }
}
