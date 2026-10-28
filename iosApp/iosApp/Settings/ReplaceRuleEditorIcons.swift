import UIKit

enum ReplaceRuleEditorIcons {
    static let checked = checkbox(checked: true)
    static let unchecked = checkbox(checked: false)

    // AppCompat 1.7.1 btn_checkbox_{checked,unchecked}_mtrl.xml, original geometry.
    // Copyright 2018 The Android Open Source Project, Apache-2.0.
    // License and disclaimer: Resources/LegadoMenuIcons-NOTICE.txt.
    private static func checkbox(checked: Bool) -> UIImage {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 7, y: -9))
        path.addLine(to: CGPoint(x: -7, y: -9))
        path.addCurve(
            to: CGPoint(x: -9, y: -7),
            control1: CGPoint(x: -8.1044921875, y: -9),
            control2: CGPoint(x: -9, y: -8.1044921875))
        path.addLine(to: CGPoint(x: -9, y: 7))
        path.addCurve(
            to: CGPoint(x: -7, y: 9),
            control1: CGPoint(x: -9, y: 8.1044921875),
            control2: CGPoint(x: -8.1044921875, y: 9))
        path.addLine(to: CGPoint(x: 7, y: 9))
        path.addCurve(
            to: CGPoint(x: 9, y: 7),
            control1: CGPoint(x: 8.1044921875, y: 9),
            control2: CGPoint(x: 9, y: 8.1044921875))
        path.addLine(to: CGPoint(x: 9, y: -7))
        path.addCurve(
            to: CGPoint(x: 7, y: -9),
            control1: CGPoint(x: 9, y: -8.1044921875),
            control2: CGPoint(x: 8.1044921875, y: -9))
        path.closeSubpath()
        let innerPoints: [CGPoint] =
            checked
            ? [
                CGPoint(x: -2, y: 5.00001525879), CGPoint(x: -7, y: 0),
                CGPoint(x: -5.58590698242, y: -1.41409301758), CGPoint(x: -2, y: 2.17192077637),
                CGPoint(x: 5.58590698242, y: -5.41409301758), CGPoint(x: 7, y: -4),
            ]
            : [
                CGPoint(x: -7, y: -7), CGPoint(x: 7, y: -7),
                CGPoint(x: 7, y: 7), CGPoint(x: -7, y: 7),
            ]
        if let first = innerPoints.first {
            path.move(to: first)
            for point in innerPoints.dropFirst() { path.addLine(to: point) }
        }
        path.closeSubpath()
        return UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { renderer in
            let context = renderer.cgContext
            context.scaleBy(x: 32 / 48, y: 32 / 48)
            context.translateBy(x: 24, y: 24)
            context.scaleBy(x: 1.5, y: 1.5)
            context.setFillColor(UIColor.black.cgColor)
            context.addPath(path)
            context.fillPath()
        }.withRenderingMode(.alwaysTemplate)
    }

    // Legado 5f5d314 drawable/ic_help.xml (GPL-3.0); original 1024 viewport paths.
    // Toolbar back/overflow/save use the existing original Android template assets.
    static let help: UIImage = {
        let glyph = CGMutablePath()
        func move(_ x: CGFloat, _ y: CGFloat) { glyph.move(to: CGPoint(x: x, y: y)) }
        func curve(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat, _ x: CGFloat, _ y: CGFloat) {
            let start = glyph.currentPoint
            glyph.addCurve(
                to: CGPoint(x: start.x + x, y: start.y + y),
                control1: CGPoint(x: start.x + x1, y: start.y + y1),
                control2: CGPoint(x: start.x + x2, y: start.y + y2)
            )
        }
        func vertical(_ offset: CGFloat) {
            let start = glyph.currentPoint
            glyph.addLine(to: CGPoint(x: start.x, y: start.y + offset))
        }
        move(474.84, 721.55)
        curve(0, 21.68, 17.55, 38.71, 38.71, 38.71)
        curve(21.68, 0, 38.71, -17.55, 38.71, -38.71)
        curve(0, -13.94, -7.23, -26.84, -19.61, -33.55)
        curve(-11.87, -6.71, -26.84, -6.71, -38.71, 0)
        curve(-11.87, 6.71, -19.1, 19.61, -19.1, 33.55)
        glyph.closeSubpath()
        move(509.94, 263.74)
        curve(-76.39, 0, -138.33, 61.42, -138.33, 137.29)
        curve(0, 17.03, 13.94, 31.48, 31.48, 31.48)
        curve(17.03, 0, 30.97, -13.94, 31.48, -31.48)
        curve(0, -41.81, 33.03, -74.32, 75.87, -74.32)
        curve(41.81, 0, 75.87, 34.06, 75.87, 76.39)
        curve(0, 16, -22.71, 38.71, -42.84, 58.84)
        curve(-29.94, 29.94, -64, 64, -64, 109.94)
        vertical(45.42)
        curve(0.52, 16.52, 14.45, 29.94, 31.48, 29.94)
        curve(17.03, 0, 30.45, -13.42, 30.97, -29.94)
        vertical(-45.42)
        curve(0, -19.61, 24.26, -44.39, 45.94, -65.55)
        curve(29.94, -29.94, 60.9, -60.9, 60.9, -102.71)
        curve(-1.03, -77.42, -62.97, -139.87, -138.84, -139.87)
        glyph.closeSubpath()
        move(512, 157.42)
        curve(195.61, 0, 354.06, 158.97, 354.58, 354.58)
        curve(0, 195.61, -158.97, 354.58, -354.58, 354.58)
        curve(-195.61, 0, -354.58, -158.97, -354.58, -354.58)
        curve(0, -195.61, 159.48, -354.58, 354.58, -354.58)
        move(512, 88.77)
        curve(-233.81, 0, -423.23, 189.42, -423.23, 423.23)
        curve(0, 233.81, 189.42, 423.23, 423.23, 423.23)
        curve(233.81, 0, 423.23, -189.42, 423.23, -423.23)
        curve(0, -233.81, -189.42, -423.23, -423.23, -423.23)
        glyph.closeSubpath()
        return UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { context in
            context.cgContext.scaleBy(x: 24 / 1024, y: 24 / 1024)
            context.cgContext.setFillColor(UIColor.black.cgColor)
            context.cgContext.addPath(glyph)
            context.cgContext.fillPath()
        }.withRenderingMode(.alwaysTemplate)
    }()
}
