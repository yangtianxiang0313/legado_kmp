import UIKit

enum ReaderSimulationRenderer {
    static func draw(
        _ geometry: ReaderSimulationGeometry, in context: CGContext,
        folding: UIImage, revealed: UIImage, background: UIColor
    ) {
        let rect = CGRect(origin: .zero, size: geometry.size)
        context.saveGState()
        clipOutside(geometry.foldPath, rect: rect, context: context)
        folding.draw(in: rect)
        context.restoreGState()

        context.saveGState()
        context.addPath(geometry.foldPath)
        context.clip()
        context.addPath(geometry.revealedPath)
        context.clip()
        revealed.draw(in: rect)
        let g = geometry
        let left = g.rightTopOrLeftBottom ? g.start1.x : g.start1.x - g.distance / 4
        let right = g.rightTopOrLeftBottom ? g.start1.x + g.distance / 4 : g.start1.x
        rotate(context, angle: g.angle, around: g.start1.cgPoint)
        gradient(
            context, rect: pixels(left, g.start1.y, right, g.start1.y + g.maxLength),
            horizontal: true, reversed: !g.rightTopOrLeftBottom, rgb: 17, from: 255, to: 0
        )
        context.restoreGState()

        drawFrontShadows(g, context: context, rect: rect)
        drawBack(g, context: context, rect: rect, folding: folding, background: background)
    }

    private static func drawBack(
        _ g: ReaderSimulationGeometry, context: CGContext, rect: CGRect,
        folding: UIImage, background: UIColor
    ) {
        guard let reflection = g.reflection else { return }
        context.saveGState()
        context.addPath(g.foldPath)
        context.clip()
        context.addPath(g.backPath)
        context.clip()
        context.setFillColor(background.cgColor)
        context.fill(rect)
        context.saveGState()
        context.concatenate(reflection)
        folding.draw(in: rect)
        context.restoreGState()
        let f1 = abs(truncated((g.start1.x + g.control1.x) / 2) - g.control1.x)
        let f2 = abs(truncated((g.start2.y + g.control2.y) / 2) - g.control2.y)
        let width = min(f1, f2)
        let left = g.rightTopOrLeftBottom ? g.start1.x - 1 : g.start1.x - width - 1
        let right = g.rightTopOrLeftBottom ? g.start1.x + width + 1 : g.start1.x + 1
        rotate(context, angle: g.angle, around: g.start1.cgPoint)
        gradient(
            context, rect: pixels(left, g.start1.y, right, g.start1.y + g.maxLength),
            horizontal: true, reversed: !g.rightTopOrLeftBottom, rgb: 51, from: 0, to: 176
        )
        context.restoreGState()
    }

    private static func drawFrontShadows(_ g: ReaderSimulationGeometry, context: CGContext, rect: CGRect) {
        let dy = g.rightTopOrLeftBottom ? g.control1.y - g.touch.y : g.touch.y - g.control1.y
        let angle = Double.pi / 4 - atan2(Double(dy), Double(g.touch.x - g.control1.x))
        let x = Float(Double(g.touch.x) + 25 * 1.414 * cos(angle))
        let offsetY = 25 * 1.414 * sin(angle)
        let y = Float(Double(g.touch.y) + (g.rightTopOrLeftBottom ? offsetY : -offsetY))
        let tip = ReaderSimulationGeometry.Point(x: x, y: y)
        context.saveGState()
        clipOutside(g.foldPath, rect: rect, context: context)
        context.addPath(g.polygon([tip, g.touch, g.control1, g.start1]))
        context.clip()
        let left = g.rightTopOrLeftBottom ? g.control1.x : g.control1.x - 25
        let right = g.rightTopOrLeftBottom ? g.control1.x + 25 : g.control1.x + 1
        rotate(
            context, angle: CGFloat(atan2(g.touch.x - g.control1.x, g.control1.y - g.touch.y)),
            around: g.control1.cgPoint
        )
        gradient(
            context, rect: pixels(left, g.control1.y - g.maxLength, right, g.control1.y),
            horizontal: true, reversed: !g.rightTopOrLeftBottom, rgb: 17, from: 128, to: 0
        )
        context.restoreGState()

        context.saveGState()
        clipOutside(g.foldPath, rect: rect, context: context)
        context.addPath(g.polygon([tip, g.touch, g.control2, g.start2]))
        context.clip()
        let top = g.rightTopOrLeftBottom ? g.control2.y : g.control2.y - 25
        let bottom = g.rightTopOrLeftBottom ? g.control2.y + 25 : g.control2.y + 1
        rotate(
            context, angle: CGFloat(atan2(g.control2.y - g.touch.y, g.control2.x - g.touch.x)),
            around: g.control2.cgPoint
        )
        let temp = g.control2.y < 0 ? Double(g.control2.y) - Double(rect.height) : Double(g.control2.y)
        let length = hypot(Double(g.control2.x), temp)
        let shadowLeft: Float
        let shadowRight: Float
        if length > Double(g.maxLength) {
            shadowLeft = Float(Double(g.control2.x) - 25 - length)
            shadowRight = Float(Double(g.control2.x) + Double(g.maxLength) - length)
        } else {
            shadowLeft = g.control2.x - g.maxLength
            shadowRight = g.control2.x
        }
        gradient(
            context, rect: pixels(shadowLeft, top, shadowRight, bottom),
            horizontal: false, reversed: !g.rightTopOrLeftBottom, rgb: 17, from: 128, to: 0
        )
        context.restoreGState()
    }

    private static func clipOutside(_ path: CGPath, rect: CGRect, context: CGContext) {
        let outside = CGMutablePath()
        outside.addRect(rect)
        outside.addPath(path)
        context.addPath(outside)
        context.clip(using: .evenOdd)
    }

    private static func rotate(_ context: CGContext, angle: CGFloat, around pivot: CGPoint) {
        context.translateBy(x: pivot.x, y: pivot.y)
        context.rotate(by: angle)
        context.translateBy(x: -pivot.x, y: -pivot.y)
    }

    private static func truncated(_ value: Float) -> Float { value.rounded(.towardZero) }

    private static func pixels(_ left: Float, _ top: Float, _ right: Float, _ bottom: Float) -> CGRect {
        CGRect(
            x: CGFloat(truncated(left)), y: CGFloat(truncated(top)),
            width: CGFloat(truncated(right) - truncated(left)),
            height: CGFloat(truncated(bottom) - truncated(top))
        )
    }

    private static func gradient(
        _ context: CGContext, rect: CGRect, horizontal: Bool, reversed: Bool,
        rgb: CGFloat, from: CGFloat, to: CGFloat
    ) {
        guard rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0 else { return }
        let value = rgb / 255
        let colors =
            [
                UIColor(red: value, green: value, blue: value, alpha: from / 255).cgColor,
                UIColor(red: value, green: value, blue: value, alpha: to / 255).cgColor,
            ] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])
        else { return }
        var start = CGPoint(x: rect.minX, y: rect.minY)
        var end = horizontal ? CGPoint(x: rect.maxX, y: rect.minY) : CGPoint(x: rect.minX, y: rect.maxY)
        if reversed { swap(&start, &end) }
        context.saveGState()
        context.clip(to: rect)
        context.drawLinearGradient(
            gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        context.restoreGState()
    }
}
