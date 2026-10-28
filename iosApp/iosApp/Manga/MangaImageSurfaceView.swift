import UIKit

@MainActor
final class MangaImageSurfaceView: UIView {
    var hasPresentation: Bool { presentation != nil }
    var onRetry: (() -> Void)?

    override var accessibilityLabel: String? {
        get { super.accessibilityLabel }
        set {
            super.accessibilityLabel = newValue
            preview.accessibilityLabel = newValue
        }
    }

    private struct DecodeJob {
        let revision: UUID
        let index: Int
        let task: Task<Void, Never>
    }

    private let preview = UIImageView()
    private let retry = UIButton(type: .system)
    private let maximumVisibleTiles = 8
    private let maximumRetainedTiles = 10
    private let maximumDecoders = 2
    private var presentation: MangaImagePresentation?
    private var revision = UUID()
    private var isSuspended = false
    private var desiredTiles: [MangaImageTile] = []
    private var visibleIndices: Set<Int> = []
    private var failedIndices: Set<Int> = []
    private var tileViews: [Int: UIImageView] = [:]
    // Cancelled synchronous decodes still occupy a slot until they actually finish.
    private var jobs: [UUID: DecodeJob] = [:]
    private var pendingMemoryPurges: Set<UUID> = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        preview.contentMode = .scaleAspectFit
        preview.isAccessibilityElement = true
        preview.accessibilityTraits = .image
        preview.isUserInteractionEnabled = false
        addSubview(preview)
        var configuration = UIButton.Configuration.filled()
        configuration.title = "图片加载失败，重试"
        configuration.image = UIImage(systemName: "arrow.clockwise")
        configuration.imagePadding = 6
        configuration.baseBackgroundColor = UIColor.black.withAlphaComponent(0.8)
        configuration.baseForegroundColor = .white
        configuration.cornerStyle = .small
        configuration.titleLineBreakMode = .byWordWrapping
        retry.configuration = configuration
        retry.titleLabel?.numberOfLines = 2
        retry.isHidden = true
        retry.addTarget(self, action: #selector(retryVisibleTiles), for: .touchUpInside)
        addSubview(retry)
        NotificationCenter.default.addObserver(
            self, selector: #selector(releaseTileMemory), name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit {
        jobs.values.forEach { $0.task.cancel() }
        NotificationCenter.default.removeObserver(self)
    }

    func setPresentation(_ presentation: MangaImagePresentation?) {
        invalidateVisibleWork()
        self.presentation = presentation
        if let tiled = presentation?.tiled {
            preview.image = tiled.preview
            preview.contentMode = .scaleToFill
        } else {
            preview.image = presentation?.bitmap
            preview.contentMode = .scaleAspectFit
        }
        setNeedsLayout()
        refreshVisibleTiles()
    }

    func suspend() {
        isSuspended = true
        invalidateVisibleWork()
    }

    func resume() {
        isSuspended = false
        refreshVisibleTiles()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            invalidateVisibleWork()
        } else {
            refreshVisibleTiles()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        refreshVisibleTiles()
    }

    func refreshVisibleTiles() {
        guard let presentation, let imageRect = fittedImageRect(pixelSize: presentation.pixelSize) else {
            preview.frame = bounds
            discardTiles()
            return
        }
        preview.frame = presentation.tiled == nil ? bounds : imageRect
        guard !isSuspended, let tiled = presentation.tiled, let viewport = visibleViewport() else {
            discardTiles()
            return
        }
        let visibleImage = viewport.intersection(imageRect)
        guard isUsable(visibleImage) else {
            discardTiles()
            return
        }
        let scale = imageRect.width / presentation.pixelSize.width
        let pixelViewport = CGRect(
            x: (visibleImage.minX - imageRect.minX) / scale,
            y: (visibleImage.minY - imageRect.minY) / scale,
            width: visibleImage.width / scale,
            height: visibleImage.height / scale)
        var visibleOffsets: [Int] = []
        for (offset, tile) in tiled.tiles.enumerated() where tile.frame.intersects(pixelViewport) {
            visibleOffsets.append(offset)
            if visibleOffsets.count > maximumVisibleTiles {
                // A zoomed-out overview must never decode the entire strip.
                discardTiles()
                return
            }
        }
        guard !visibleOffsets.isEmpty else {
            discardTiles()
            return
        }
        var retainedOffsets = Set(visibleOffsets)
        if let first = visibleOffsets.first, first > 0 { retainedOffsets.insert(first - 1) }
        if let last = visibleOffsets.last, last + 1 < tiled.tiles.count { retainedOffsets.insert(last + 1) }
        guard retainedOffsets.count <= maximumRetainedTiles else {
            discardTiles()
            return
        }
        visibleIndices = Set(visibleOffsets.map { tiled.tiles[$0].index })
        // Decode visible tiles before their immediate neighbours.
        desiredTiles = visibleOffsets.map { tiled.tiles[$0] }
        desiredTiles.append(contentsOf: retainedOffsets.subtracting(visibleOffsets).sorted().map { tiled.tiles[$0] })
        let desiredIndices = Set(desiredTiles.map(\.index))
        failedIndices.formIntersection(desiredIndices)
        for job in jobs.values where job.revision != revision || !desiredIndices.contains(job.index) {
            job.task.cancel()
        }
        for index in Array(tileViews.keys) where !desiredIndices.contains(index) {
            tileViews.removeValue(forKey: index)?.removeFromSuperview()
        }
        for tile in desiredTiles {
            tileViews[tile.index]?.frame = displayFrame(tile.frame, in: imageRect, scale: scale)
        }
        updateRetry(in: viewport)
        scheduleDecodes()
    }

    private func fittedImageRect(pixelSize: CGSize) -> CGRect? {
        guard pixelSize.width.isFinite, pixelSize.height.isFinite, pixelSize.width > 0, pixelSize.height > 0,
            isUsable(bounds)
        else { return nil }
        let scale = min(bounds.width / pixelSize.width, bounds.height / pixelSize.height)
        let size = CGSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    private func visibleViewport() -> CGRect? {
        guard let window else { return nil }
        var viewport = convert(window.bounds, from: window).intersection(bounds)
        var ancestor: UIView? = self
        while let view = ancestor {
            guard !view.isHidden, view.alpha > 0.01 else { return nil }
            if view.clipsToBounds || view is UIScrollView {
                viewport = viewport.intersection(convert(view.bounds, from: view))
            }
            ancestor = view.superview
        }
        return isUsable(viewport) ? viewport : nil
    }

    private func isUsable(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.width.isFinite && rect.height.isFinite && rect.width > 0 && rect.height > 0
    }

    private func displayFrame(_ frame: CGRect, in imageRect: CGRect, scale: CGFloat) -> CGRect {
        CGRect(
            x: imageRect.minX + frame.minX * scale, y: imageRect.minY + frame.minY * scale,
            width: frame.width * scale, height: frame.height * scale)
    }

    private func scheduleDecodes() {
        guard !isSuspended, window != nil, let tiled = presentation?.tiled else { return }
        for tile in desiredTiles {
            guard jobs.count < maximumDecoders else { break }
            guard tileViews[tile.index] == nil, !failedIndices.contains(tile.index),
                !jobs.values.contains(where: { $0.revision == revision && $0.index == tile.index && !$0.task.isCancelled })
            else { continue }
            let id = UUID()
            let token = revision
            let index = tile.index
            let task = Task { [weak self, tiled] in
                guard !Task.isCancelled else {
                    self?.finishDecode(
                        id: id, token: token, index: index, tiled: tiled,
                        result: .failure(CancellationError()), cancelled: true)
                    return
                }
                let decoding = Task.detached(priority: .userInitiated) {
                    try autoreleasepool {
                        try Task.checkCancellation()
                        let image = try tiled.image(at: index)
                        try Task.checkCancellation()
                        return image
                    }
                }
                let result: Result<UIImage, Error>
                do {
                    let image = try await withTaskCancellationHandler {
                        try await decoding.value
                    } onCancel: {
                        decoding.cancel()
                    }
                    try Task.checkCancellation()
                    result = .success(image)
                } catch {
                    result = .failure(error)
                }
                self?.finishDecode(
                    id: id, token: token, index: index, tiled: tiled, result: result, cancelled: Task.isCancelled)
            }
            jobs[id] = DecodeJob(revision: token, index: index, task: task)
        }
    }

    private func finishDecode(
        id: UUID, token: UUID, index: Int, tiled: MangaTiledImage, result: Result<UIImage, Error>, cancelled: Bool
    ) {
        if pendingMemoryPurges.remove(id) != nil { tiled.clearMemory() }
        guard jobs.removeValue(forKey: id) != nil else { return }
        defer { scheduleDecodes() }
        guard token == revision, !isSuspended, !cancelled, window != nil,
            let tile = desiredTiles.first(where: { $0.index == index }), let presentation,
            let imageRect = fittedImageRect(pixelSize: presentation.pixelSize)
        else { return }
        switch result {
        case .success(let image):
            let imageView = UIImageView(image: image)
            imageView.contentMode = .scaleToFill
            imageView.isAccessibilityElement = false
            imageView.isUserInteractionEnabled = false
            imageView.clipsToBounds = true
            imageView.frame = displayFrame(tile.frame, in: imageRect, scale: imageRect.width / presentation.pixelSize.width)
            tileViews.removeValue(forKey: index)?.removeFromSuperview()
            tileViews[index] = imageView
            insertSubview(imageView, belowSubview: retry)
        case .failure:
            failedIndices.insert(index)
        }
        if let viewport = visibleViewport() { updateRetry(in: viewport) }
    }

    private func updateRetry(in viewport: CGRect) {
        retry.isHidden = failedIndices.isDisjoint(with: visibleIndices)
        guard !retry.isHidden, let window else { return }
        // This button lives inside the zoom view but keeps a screen-sized hit target.
        let origin = convert(CGPoint.zero, to: window)
        let xUnit = convert(CGPoint(x: 1, y: 0), to: window)
        let yUnit = convert(CGPoint(x: 0, y: 1), to: window)
        let xScale = hypot(xUnit.x - origin.x, xUnit.y - origin.y)
        let yScale = hypot(yUnit.x - origin.x, yUnit.y - origin.y)
        guard xScale.isFinite, yScale.isFinite, xScale > 0, yScale > 0 else {
            retry.isHidden = true
            return
        }
        let width = min(240, max(44, viewport.width * xScale - 24))
        retry.transform = CGAffineTransform(scaleX: 1 / xScale, y: 1 / yScale)
        retry.bounds = CGRect(x: 0, y: 0, width: width, height: 52)
        retry.center = CGPoint(x: viewport.midX, y: viewport.midY)
        bringSubviewToFront(retry)
    }

    private func discardTiles() {
        desiredTiles.removeAll()
        visibleIndices.removeAll()
        failedIndices.removeAll()
        jobs.values.forEach { $0.task.cancel() }
        tileViews.values.forEach { $0.removeFromSuperview() }
        tileViews.removeAll()
        retry.isHidden = true
    }

    private func invalidateVisibleWork() {
        revision = UUID()
        discardTiles()
    }

    @objc private func releaseTileMemory() {
        pendingMemoryPurges.formUnion(jobs.keys)
        invalidateVisibleWork()
        presentation?.tiled?.clearMemory()
    }

    @objc private func retryVisibleTiles() {
        failedIndices.removeAll()
        onRetry?()
        refreshVisibleTiles()
    }
}
