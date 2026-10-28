import UIKit

@MainActor
struct ReaderPageTurnBitmaps {
    let outgoing: UIImage
    let incoming: UIImage
    let displayScale: CGFloat

    /// Captures visible, alpha-1 roots in local coordinates, not presentation animations.
    static func capture(
        outgoing: UIView,
        incoming: UIView,
        displayScale: CGFloat,
        backgroundColor: UIColor
    ) -> ReaderPageTurnBitmaps? {
        let outgoingBounds = outgoing.bounds
        let incomingBounds = incoming.bounds
        guard validBounds(outgoingBounds, scale: displayScale),
            validBounds(incomingBounds, scale: displayScale),
            outgoingBounds.size == incomingBounds.size,
            let raster = RasterSize(size: outgoingBounds.size, scale: displayScale),
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            canCapture(outgoing), canCapture(incoming)
        else { return nil }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        layoutSubtree(outgoing)
        layoutSubtree(incoming)
        guard outgoing.bounds == outgoingBounds, incoming.bounds == incomingBounds else { return nil }

        // Detached CoreText views must draw before their backing layers can be rendered.
        invalidateViewSubtree(outgoing)
        invalidateViewSubtree(incoming)
        outgoing.traitCollection.performAsCurrent {
            displaySubtree(outgoing.layer)
        }
        incoming.traitCollection.performAsCurrent {
            displaySubtree(incoming.layer)
        }
        guard outgoing.bounds == outgoingBounds, incoming.bounds == incomingBounds,
            canCapture(outgoing), canCapture(incoming)
        else { return nil }

        let fillColor = backgroundColor.resolvedColor(with: outgoing.traitCollection).cgColor
        guard
            let outgoingImage = rasterize(
                outgoing, bounds: outgoingBounds, raster: raster, scale: displayScale,
                fillColor: fillColor, colorSpace: colorSpace
            ),
            let incomingImage = rasterize(
                incoming, bounds: incomingBounds, raster: raster, scale: displayScale,
                fillColor: fillColor, colorSpace: colorSpace
            ), outgoing.bounds == outgoingBounds, incoming.bounds == incomingBounds
        else { return nil }

        return ReaderPageTurnBitmaps(
            outgoing: outgoingImage, incoming: incomingImage, displayScale: displayScale
        )
    }

    private struct RasterSize {
        let width: Int
        let height: Int

        init?(size: CGSize, scale: CGFloat) {
            let pixelWidth = (size.width * scale).rounded(.up)
            let pixelHeight = (size.height * scale).rounded(.up)
            guard pixelWidth.isFinite, pixelHeight.isFinite,
                pixelWidth >= 1, pixelHeight >= 1,
                pixelWidth <= 8192, pixelHeight <= 8192,
                (pixelWidth / scale).isFinite, (pixelHeight / scale).isFinite
            else { return nil }

            let width = Int(pixelWidth)
            let height = Int(pixelHeight)
            // Two RGBA8 images together are limited to 64 MiB, excluding layer caches.
            guard width * height <= (16 * 1024 * 1024) / 2 else { return nil }
            self.width = width
            self.height = height
        }
    }

    private static func validBounds(_ bounds: CGRect, scale: CGFloat) -> Bool {
        scale.isFinite && scale > 0
            && (scale * scale).isFinite && scale * scale > 0
            && bounds.origin.x.isFinite && bounds.origin.y.isFinite
            && bounds.width.isFinite && bounds.height.isFinite
            && bounds.width > 0 && bounds.height > 0
            && bounds.maxX.isFinite && bounds.maxY.isFinite
            && bounds.maxX > bounds.minX && bounds.maxY > bounds.minY
            && (bounds.origin.x * scale).isFinite && (bounds.origin.y * scale).isFinite
    }

    private static func canCapture(_ view: UIView) -> Bool {
        // Do not manufacture a background-only image for a hidden or faded page.
        !view.isHidden && view.alpha == 1 && canRender(view.layer)
            && !containsVisualEffect(view)
    }

    private static func containsVisualEffect(_ view: UIView) -> Bool {
        guard !view.isHidden, view.alpha > 0 else { return false }
        return view is UIVisualEffectView || view.subviews.contains { containsVisualEffect($0) }
    }

    private static func canRender(_ layer: CALayer) -> Bool {
        guard !layer.isHidden, layer.opacity > 0 else { return true }
        guard !(layer is CAMetalLayer), !(layer is CAEAGLLayer), !(layer is CATiledLayer),
            !(layer is CATransformLayer), !layer.drawsAsynchronously,
            CATransform3DIsAffine(layer.transform), CATransform3DIsAffine(layer.sublayerTransform)
        else { return false }
        if let mask = layer.mask, !canRender(mask) { return false }
        return layer.sublayers?.allSatisfy { canRender($0) } ?? true
    }

    private static func layoutSubtree(_ view: UIView) {
        view.layoutIfNeeded()
        for child in view.subviews where !child.isHidden {
            layoutSubtree(child)
        }
    }

    private static func invalidateViewSubtree(_ view: UIView) {
        guard !view.isHidden, view.alpha > 0 else { return }
        view.setNeedsDisplay()
        for child in view.subviews {
            invalidateViewSubtree(child)
        }
    }

    private static func displaySubtree(_ layer: CALayer) {
        guard !layer.isHidden, layer.opacity > 0 else { return }
        layer.displayIfNeeded()
        if let mask = layer.mask {
            displaySubtree(mask)
        }
        for child in layer.sublayers ?? [] {
            displaySubtree(child)
        }
    }

    private static func rasterize(
        _ view: UIView,
        bounds: CGRect,
        raster: RasterSize,
        scale: CGFloat,
        fillColor: CGColor,
        colorSpace: CGColorSpace
    ) -> UIImage? {
        autoreleasepool { () -> UIImage? in
            let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            guard
                let context = CGContext(
                    data: nil, width: raster.width, height: raster.height,
                    bitsPerComponent: 8, bytesPerRow: raster.width * 4,
                    space: colorSpace, bitmapInfo: bitmapInfo
                )
            else { return nil }

            // Fill the fractional trailing pixel too; never shrink or crop the page to fit.
            context.setBlendMode(.copy)
            context.setFillColor(fillColor)
            context.fill(CGRect(x: 0, y: 0, width: CGFloat(raster.width), height: CGFloat(raster.height)))
            context.setBlendMode(.normal)
            context.translateBy(x: 0, y: CGFloat(raster.height))
            context.scaleBy(x: scale, y: -scale)
            context.clip(to: CGRect(origin: .zero, size: bounds.size))
            context.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)

            // Layer-local rendering excludes the root view's frame, anchor and transform.
            view.traitCollection.performAsCurrent {
                UIGraphicsPushContext(context)
                defer { UIGraphicsPopContext() }
                view.layer.render(in: context)
            }
            guard let image = context.makeImage(),
                image.width == raster.width, image.height == raster.height
            else { return nil }
            return UIImage(cgImage: image, scale: scale, orientation: .up)
        }
    }
}
