import UIKit

final class ReaderImageZoomView: UIView, UIScrollViewDelegate {
    private static let maximumRelativeZoomScale: CGFloat = 2.5

    private struct ViewportState {
        let normalizedCenter: CGPoint
        let relativeZoomScale: CGFloat

        static let initial = ViewportState(normalizedCenter: CGPoint(x: 0.5, y: 0.5), relativeZoomScale: 1)
    }

    private let imageSize: CGSize
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private var hasLaidOutImage = false
    private var isUpdatingGeometry = false
    private var isDoubleTapZoomed = false

    init(image: UIImage) {
        imageSize = image.size
        super.init(frame: .zero)
        accessibilityIdentifier = "reader.imagePreview.zoom"
        clipsToBounds = true

        scrollView.delegate = self
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.alwaysBounceVertical = false
        scrollView.bouncesZoom = false
        scrollView.accessibilityIdentifier = "reader.imagePreview.scroll"
        addSubview(scrollView)

        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityTraits = .image
        imageView.accessibilityLabel = L10n.Reader.imagePreview
        imageView.accessibilityIdentifier = "reader.imagePreview.image"
        if hasValidImageSize {
            // Keep source point coordinates fixed; UIScrollView alone applies the zoom transform.
            imageView.bounds = CGRect(origin: .zero, size: imageSize)
            imageView.center = CGPoint(x: imageSize.width / 2, y: imageSize.height / 2)
        }
        scrollView.addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let viewportSize = bounds.size
        guard hasValidImageSize, viewportSize.width.isFinite, viewportSize.height.isFinite,
            viewportSize.width > 0, viewportSize.height > 0,
            !hasLaidOutImage || scrollView.bounds.size != viewportSize
        else { return }

        // Read the old viewport before resizing the scroll view, including during rotation or split view.
        let state = hasLaidOutImage ? viewportState() : .initial
        isUpdatingGeometry = true
        defer { isUpdatingGeometry = false }

        scrollView.frame = CGRect(origin: .zero, size: viewportSize)
        let minimumScale = min(1, min(viewportSize.width / imageSize.width, viewportSize.height / imageSize.height))
        let maximumScale = minimumScale * Self.maximumRelativeZoomScale
        let relativeScale = min(Self.maximumRelativeZoomScale, max(1, state.relativeZoomScale))

        // Widen first so neither limit temporarily clamps the old zoom before restoring the new one.
        scrollView.minimumZoomScale = min(scrollView.minimumZoomScale, minimumScale)
        scrollView.maximumZoomScale = max(scrollView.maximumZoomScale, maximumScale)
        scrollView.setZoomScale(minimumScale * relativeScale, animated: false)
        scrollView.minimumZoomScale = minimumScale
        scrollView.maximumZoomScale = maximumScale
        updateCenteringInsets()

        let scaledSize = scaledImageSize(at: scrollView.zoomScale)
        let offset = CGPoint(
            x: state.normalizedCenter.x * scaledSize.width - viewportSize.width / 2,
            y: state.normalizedCenter.y * scaledSize.height - viewportSize.height / 2
        )
        scrollView.setContentOffset(clampedOffset(offset, scaledSize: scaledSize), animated: false)
        hasLaidOutImage = true
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        setNeedsLayout()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        hasValidImageSize ? imageView : nil
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        guard !isUpdatingGeometry else { return }
        updateCenteringInsets()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        guard !isUpdatingGeometry, hasLaidOutImage else { return }
        isUpdatingGeometry = true
        defer { isUpdatingGeometry = false }
        let clampedScale = min(scrollView.maximumZoomScale, max(scrollView.minimumZoomScale, scrollView.zoomScale))
        scrollView.setZoomScale(clampedScale, animated: false)
        updateCenteringInsets()
        scrollView.setContentOffset(
            clampedOffset(scrollView.contentOffset, scaledSize: scaledImageSize(at: clampedScale)),
            animated: false
        )
    }

    private var hasValidImageSize: Bool {
        imageSize.width.isFinite && imageSize.height.isFinite && imageSize.width > 0 && imageSize.height > 0
    }

    private func viewportState() -> ViewportState {
        let size = scaledImageSize(at: scrollView.zoomScale)
        let center = CGPoint(
            x: (scrollView.contentOffset.x + scrollView.bounds.width / 2) / size.width,
            y: (scrollView.contentOffset.y + scrollView.bounds.height / 2) / size.height
        )
        return ViewportState(
            normalizedCenter: CGPoint(x: min(1, max(0, center.x)), y: min(1, max(0, center.y))),
            relativeZoomScale: scrollView.zoomScale / scrollView.minimumZoomScale
        )
    }

    private func scaledImageSize(at scale: CGFloat) -> CGSize {
        CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    private func centeringInsets(for size: CGSize) -> UIEdgeInsets {
        let horizontal = max(0, (scrollView.bounds.width - size.width) / 2)
        let vertical = max(0, (scrollView.bounds.height - size.height) / 2)
        return UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }

    private func updateCenteringInsets() {
        let size = scaledImageSize(at: scrollView.zoomScale)
        scrollView.contentSize = size
        let insets = centeringInsets(for: size)
        if scrollView.contentInset != insets {
            scrollView.contentInset = insets
        }
    }

    private func clampedOffset(_ offset: CGPoint, scaledSize: CGSize) -> CGPoint {
        let insets = centeringInsets(for: scaledSize)
        let minimumX = -insets.left
        let minimumY = -insets.top
        let maximumX = max(minimumX, scaledSize.width - scrollView.bounds.width + insets.right)
        let maximumY = max(minimumY, scaledSize.height - scrollView.bounds.height + insets.bottom)
        return CGPoint(x: min(maximumX, max(minimumX, offset.x)), y: min(maximumY, max(minimumY, offset.y)))
    }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        layoutIfNeeded()
        guard hasLaidOutImage, gesture.state == .ended else { return }
        isDoubleTapZoomed.toggle()
        let targetScale = isDoubleTapZoomed ? scrollView.maximumZoomScale : scrollView.minimumZoomScale
        let sourcePoint = gesture.location(in: imageView)
        let viewportPoint = gesture.location(in: self)
        let offset = clampedOffset(
            CGPoint(x: sourcePoint.x * targetScale - viewportPoint.x, y: sourcePoint.y * targetScale - viewportPoint.y),
            scaledSize: scaledImageSize(at: targetScale)
        )
        let rect = CGRect(
            x: offset.x / targetScale,
            y: offset.y / targetScale,
            width: scrollView.bounds.width / targetScale,
            height: scrollView.bounds.height / targetScale
        )
        scrollView.zoom(to: rect, animated: !UIAccessibility.isReduceMotionEnabled)
    }
}
