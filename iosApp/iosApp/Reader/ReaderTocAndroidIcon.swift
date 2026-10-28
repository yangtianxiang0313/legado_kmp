import UIKit

/// Unchanged Legado VectorDrawable geometry at 5f5d31404af9957684703747ecee2b91e7161f1d.
/// Asset source paths and SHA-256 hashes are recorded in LegadoMenuIcons-NOTICE.txt.
enum ReaderTocAndroidIcon: String, CaseIterable {
    case top = "ReaderTocAndroidTop"  // ic_arrow_drop_up
    case bottom = "ReaderTocAndroidBottom"  // ic_arrow_drop_down
    case down = "ReaderTocAndroidDown"  // ic_arrow_down, rendered from its original path below
    case check = "ReaderTocAndroidCheck"  // ic_check
    case cloud = "ReaderTocAndroidCloud"  // ic_outline_cloud_24
    case lock = "ReaderTocAndroidLock"  // ic_lock_outline

    func image(size: CGFloat = 24) -> UIImage? {
        guard size.isFinite, size > 0 else { return nil }
        if self == .down { return Self.arrowDownImage(size: size) }
        guard let source = UIImage(named: rawValue) else { return nil }

        let targetSize = CGSize(width: size, height: size)
        let image: UIImage
        if source.size == targetSize {
            image = source
        } else {
            let format = UIGraphicsImageRendererFormat()
            format.opaque = false
            image = UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
                source.withRenderingMode(.alwaysOriginal).draw(
                    in: CGRect(origin: .zero, size: targetSize))
            }
        }

        // None of these source drawables declares android:autoMirrored.
        return image.withRenderingMode(.alwaysTemplate)
    }

    // Legado 5f5d314 app/src/main/res/drawable/ic_arrow_down.xml (GPL-3.0).
    // Original 64dp drawable, 1024 x 1024 viewport, nonzero fill, no autoMirrored.
    // M512,685.25l-278.62,-278.62 45.25,-45.25L512,594.75l233.38,-233.38 45.25,45.25z
    private static func arrowDownImage(size: CGFloat) -> UIImage {
        let path = CGMutablePath()
        func relativeLine(_ x: CGFloat, _ y: CGFloat) {
            let start = path.currentPoint
            path.addLine(to: CGPoint(x: start.x + x, y: start.y + y))
        }
        path.move(to: CGPoint(x: 512, y: 685.25))
        relativeLine(-278.62, -278.62)
        relativeLine(45.25, -45.25)
        path.addLine(to: CGPoint(x: 512, y: 594.75))
        relativeLine(233.38, -233.38)
        relativeLine(45.25, 45.25)
        path.closeSubpath()

        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { renderer in
            let context = renderer.cgContext
            context.scaleBy(x: size / 1024, y: size / 1024)
            context.setFillColor(UIColor(white: 24.0 / 255, alpha: 1).cgColor)
            context.addPath(path)
            context.fillPath()
        }.withRenderingMode(.alwaysTemplate)
    }
}
