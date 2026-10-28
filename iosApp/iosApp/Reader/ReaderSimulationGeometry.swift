import CoreGraphics
import Foundation

// Port of Legado SimulationPageDelegate.calcPoints; calculations stay in physical pixels.
struct ReaderSimulationGeometry {
    struct Point {
        var x: Float
        var y: Float
        var cgPoint: CGPoint { CGPoint(x: CGFloat(x), y: CGFloat(y)) }
        var isFinite: Bool { x.isFinite && y.isFinite }
    }

    let size: CGSize
    let touch: Point
    let corner: Point
    let start1: Point
    let control1: Point
    let end1: Point
    let vertex1: Point
    let start2: Point
    let control2: Point
    let end2: Point
    let vertex2: Point
    let distance: Float
    let maxLength: Float
    let angle: CGFloat
    let rightTopOrLeftBottom: Bool

    init?(size: CGSize, touch input: CGPoint, corner cornerInput: CGPoint) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
            input.x.isFinite, input.y.isFinite, cornerInput.x.isFinite, cornerInput.y.isFinite
        else { return nil }
        let width = Float(size.width)
        let height = Float(size.height)
        let corner = Point(x: Float(cornerInput.x), y: Float(cornerInput.y))
        var touch = Point(x: Float(input.x), y: Float(input.y))
        guard touch.x != corner.x else { return nil }
        var controls = Self.controls(touch: touch, corner: corner)
        var start1 = Point(x: controls.0.x - (corner.x - controls.0.x) / 2, y: corner.y)
        if touch.x > 0 && touch.x < width && (start1.x < 0 || start1.x > width) {
            if start1.x < 0 { start1.x = width - start1.x }
            let f1 = abs(corner.x - touch.x)
            let f2 = width * f1 / start1.x
            touch.x = abs(corner.x - f2)
            let f3 = abs(corner.x - touch.x) * abs(corner.y - touch.y) / f1
            touch.y = abs(corner.y - f3)
            controls = Self.controls(touch: touch, corner: corner)
            start1.x = controls.0.x - (corner.x - controls.0.x) / 2
        }
        let start2 = Point(x: corner.x, y: controls.1.y - (corner.y - controls.1.y) / 2)
        guard let end1 = Self.cross(touch, controls.0, start1, start2),
            let end2 = Self.cross(touch, controls.1, start1, start2)
        else { return nil }
        let vertex1 = Self.vertex(start1, controls.0, end1)
        let vertex2 = Self.vertex(start2, controls.1, end2)
        guard
            [touch, corner, start1, start2, controls.0, controls.1, end1, end2, vertex1, vertex2]
                .allSatisfy(\.isFinite)
        else { return nil }
        self.size = size
        self.touch = touch
        self.corner = corner
        self.start1 = start1
        self.control1 = controls.0
        self.end1 = end1
        self.vertex1 = vertex1
        self.start2 = start2
        self.control2 = controls.1
        self.end2 = end2
        self.vertex2 = vertex2
        distance = Float(hypot(Double(touch.x - corner.x), Double(touch.y - corner.y)))
        maxLength = Float(hypot(Double(width), Double(height)))
        angle = CGFloat(atan2(Double(controls.0.x - corner.x), Double(controls.1.y - corner.y)))
        rightTopOrLeftBottom = (corner.x == 0 && corner.y == height) || (corner.y == 0 && corner.x == width)
    }

    var foldPath: CGPath {
        let path = CGMutablePath()
        path.move(to: start1.cgPoint)
        path.addQuadCurve(to: end1.cgPoint, control: control1.cgPoint)
        path.addLine(to: touch.cgPoint)
        path.addLine(to: end2.cgPoint)
        path.addQuadCurve(to: start2.cgPoint, control: control2.cgPoint)
        path.addLine(to: corner.cgPoint)
        path.closeSubpath()
        return path
    }

    var revealedPath: CGPath { polygon([start1, vertex1, vertex2, start2, corner]) }
    var backPath: CGPath { polygon([vertex2, vertex1, end1, touch, end2]) }

    var reflection: CGAffineTransform? {
        let length = Float(hypot(Double(corner.x - control1.x), Double(control2.y - corner.y)))
        guard length.isFinite, length > 0 else { return nil }
        let f8 = (corner.x - control1.x) / length
        let f9 = (control2.y - corner.y) / length
        let a = CGFloat(1 - 2 * f9 * f9)
        let b = CGFloat(2 * f8 * f9)
        let d = CGFloat(1 - 2 * f8 * f8)
        let pivot = control1.cgPoint
        return CGAffineTransform(
            a: a, b: b, c: b, d: d,
            tx: pivot.x - a * pivot.x - b * pivot.y,
            ty: pivot.y - b * pivot.x - d * pivot.y
        )
    }

    func polygon(_ points: [Point]) -> CGPath {
        let path = CGMutablePath()
        if let first = points.first {
            path.move(to: first.cgPoint)
            for point in points.dropFirst() { path.addLine(to: point.cgPoint) }
            path.closeSubpath()
        }
        return path
    }

    private static func controls(touch: Point, corner: Point) -> (Point, Point) {
        let middleX = (touch.x + corner.x) / 2
        let middleY = (touch.y + corner.y) / 2
        let dx = corner.x - middleX
        let dy = corner.y - middleY
        return (
            Point(x: middleX - dy * dy / dx, y: corner.y),
            Point(x: corner.x, y: middleY - dx * dx / (dy == 0 ? 0.1 : dy))
        )
    }

    private static func vertex(_ start: Point, _ control: Point, _ end: Point) -> Point {
        Point(x: (start.x + 2 * control.x + end.x) / 4, y: (2 * control.y + start.y + end.y) / 4)
    }

    private static func cross(_ p1: Point, _ p2: Point, _ p3: Point, _ p4: Point) -> Point? {
        let a1 = (p2.y - p1.y) / (p2.x - p1.x)
        let b1 = (p1.x * p2.y - p2.x * p1.y) / (p1.x - p2.x)
        let a2 = (p4.y - p3.y) / (p4.x - p3.x)
        let b2 = (p3.x * p4.y - p4.x * p3.y) / (p3.x - p4.x)
        let x = (b2 - b1) / (a1 - a2)
        let point = Point(x: x, y: a1 * x + b1)
        if point.isFinite { return point }
        // The original slope formula is undefined for a vertical line at an edge.
        let rx = Double(p2.x) - Double(p1.x)
        let ry = Double(p2.y) - Double(p1.y)
        let sx = Double(p4.x) - Double(p3.x)
        let sy = Double(p4.y) - Double(p3.y)
        let denominator = rx * sy - ry * sx
        guard denominator.isFinite, abs(denominator) > Double.ulpOfOne else { return nil }
        let t = ((Double(p3.x) - Double(p1.x)) * sy - (Double(p3.y) - Double(p1.y)) * sx) / denominator
        let result = Point(x: Float(Double(p1.x) + t * rx), y: Float(Double(p1.y) + t * ry))
        return result.isFinite ? result : nil
    }
}
