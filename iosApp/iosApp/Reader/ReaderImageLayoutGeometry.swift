import CoreGraphics

struct ReaderImageLayoutGeometry {
    let size: CGSize
    let occupiesWholePage: Bool
    let allowsVerticalOverflow: Bool
    private let contentSize: CGSize

    init(
        style: String, pixelSize: CGSize?, imageScale: CGFloat, contentSize: CGSize,
        bodyLineHeight: CGFloat, isScrollMode: Bool = false
    ) {
        let style = style.uppercased()
        let availableSize = CGSize(
            width: Self.positiveFinite(contentSize.width) ? contentSize.width : 1,
            height: Self.positiveFinite(contentSize.height) ? contentSize.height : 1
        )
        self.contentSize = availableSize
        occupiesWholePage = style == "SINGLE"
        allowsVerticalOverflow = style == "FULL" && isScrollMode
        let placeholder = Self.placeholderSize(style: style, contentSize: availableSize, bodyLineHeight: bodyLineHeight)
        // Legacy/caller-created TEXT layouts without paragraph hints retain a bounded fallback.
        guard style != "TEXT", let pixelSize,
            Self.positiveFinite(pixelSize.width), Self.positiveFinite(pixelSize.height)
        else {
            size = placeholder
            return
        }

        if allowsVerticalOverflow {
            size = Self.fullWidthSize(pixelSize, width: availableSize.width) ?? placeholder
            return
        }

        let bounds: CGSize
        switch style {
        case "FULL", "SINGLE":
            bounds = availableSize
        default:
            // DEFAULT keeps the native pixel-to-point size and only scales down.
            let scale = Self.positiveFinite(imageScale) ? imageScale : 1
            bounds = CGSize(
                width: min(pixelSize.width / scale, availableSize.width),
                height: min(pixelSize.height / scale, availableSize.height)
            )
        }
        size = Self.aspectFitSize(pixelSize, in: bounds) ?? placeholder
    }

    func frame(cursorY: CGFloat) -> CGRect {
        let y =
            occupiesWholePage
            ? max((contentSize.height - size.height) / 2, 0)
            : (cursorY.isFinite ? max(cursorY, 0) : 0)
        return CGRect(
            x: max((contentSize.width - size.width) / 2, 0),
            y: (y + size.height).isFinite ? y : 0,
            width: size.width,
            height: size.height
        )
    }

    private static func fullWidthSize(_ pixelSize: CGSize, width: CGFloat) -> CGSize? {
        let height = pixelSize.height / pixelSize.width * width
        if positiveFinite(height) { return CGSize(width: width, height: height) }
        // A different operation order can avoid intermediate overflow/underflow.
        let alternateHeight = width / pixelSize.width * pixelSize.height
        guard positiveFinite(alternateHeight) else { return nil }
        return CGSize(width: width, height: alternateHeight)
    }

    private static func aspectFitSize(_ pixelSize: CGSize, in bounds: CGSize) -> CGSize? {
        let aspectRatio = pixelSize.width / pixelSize.height
        guard positiveFinite(aspectRatio), positiveFinite(bounds.width), positiveFinite(bounds.height) else { return nil }
        let fitted: CGSize
        if bounds.width / bounds.height > aspectRatio {
            fitted = CGSize(width: bounds.height * aspectRatio, height: bounds.height)
        } else {
            fitted = CGSize(width: bounds.width, height: bounds.width / aspectRatio)
        }
        guard positiveFinite(fitted.width), positiveFinite(fitted.height) else { return nil }
        return fitted
    }

    private static func placeholderSize(style: String, contentSize: CGSize, bodyLineHeight: CGFloat) -> CGSize {
        let lineHeight = positiveFinite(bodyLineHeight) ? bodyLineHeight : 24
        let height: CGFloat
        switch style {
        case "TEXT":
            height = max(lineHeight, 24)
        case "FULL":
            height = min(contentSize.height, max(contentSize.height * 0.72, lineHeight * 8))
        case "SINGLE":
            height = contentSize.height
        default:
            height = min(max(lineHeight * 6, 120), contentSize.height)
        }
        let width = style == "TEXT" ? min(max(height * 1.4, 32), contentSize.width) : contentSize.width
        return CGSize(width: width, height: height)
    }

    private static func positiveFinite(_ value: CGFloat) -> Bool {
        value.isFinite && value > 0
    }
}
