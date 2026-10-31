import AVFoundation
import CoreText
import Kingfisher
import UIKit

final class ReaderPageContentView: UIView {
    var bookURL: String? {
        didSet {
            if oldValue != bookURL {
                loadedImages.removeAll()
                loadingURLs.removeAll()
                imageTasks.values.forEach { $0.cancel() }
                imageTasks.removeAll()
                imageRequestIDs.removeAll()
                updateImageRequests()
                setNeedsDisplay()
            }
        }
    }

    var pageLayout: ReaderPageLayout? {
        didSet {
            updateImageRequests()
            updatePageContentAccessibility()
            setNeedsDisplay()
        }
    }

    override var isHidden: Bool {
        didSet { updatePageContentAccessibility() }
    }

    func updatePageContentAccessibility() {
        let text = pageLayout?.accessibilityText
        let hasContent = pageLayout?.isEmpty == false && text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        isAccessibilityElement = !isHidden && hasContent
        accessibilityElementsHidden = !isAccessibilityElement
        accessibilityTraits = .staticText
        accessibilityIdentifier = UIIdentifiers.Reader.pageContent
        accessibilityLabel = isAccessibilityElement ? text : nil
        accessibilityValue = nil
    }

    var theme: ReaderThemeController = .init() {
        didSet {
            setNeedsDisplay()
        }
    }

    var highlightedBlockIndex: Int? {
        didSet {
            if oldValue != highlightedBlockIndex {
                setNeedsDisplay()
            }
        }
    }

    var selectionRange: NSRange? {
        didSet {
            if oldValue != selectionRange {
                setNeedsDisplay()
            }
        }
    }

    var searchResultRange: NSRange? {
        didSet {
            if oldValue != searchResultRange {
                setNeedsDisplay()
            }
        }
    }

    var selectionColor: UIColor { theme.selectionColor }
    var visibleRect: CGRect = .zero {
        didSet {
            if oldValue != visibleRect {
                setNeedsDisplay()
            }
        }
    }

    private(set) var loadedImages: [URL: UIImage] = [:]
    private var loadingURLs: Set<URL> = []
    private var imageTasks: [URL: Task<Void, Never>] = [:]
    private var imageRequestIDs: [URL: UUID] = [:]

    deinit {
        cancelImageRequests()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            cancelImageRequests()
        } else {
            updateImageRequests()
        }
    }

    func cacheLoadedImage(_ image: UIImage, for url: URL) {
        guard pageLayout?.attachmentFragments.contains(where: {
            if case .remoteImage(let sourceURL, _) = $0.source { return sourceURL == url }
            return false
        }) == true else { return }
        imageTasks.removeValue(forKey: url)?.cancel()
        imageRequestIDs.removeValue(forKey: url)
        loadingURLs.remove(url)
        loadedImages[url] = image
        setNeedsDisplay()
    }

    func removeCachedImage(for url: URL) {
        loadedImages.removeValue(forKey: url)
        loadingURLs.remove(url)
        imageTasks[url]?.cancel()
        imageTasks.removeValue(forKey: url)
        imageRequestIDs.removeValue(forKey: url)
        updateImageRequests()
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        super.draw(rect)
        guard let pageLayout, let context = UIGraphicsGetCurrentContext() else { return }
        let visibleRect = effectiveVisibleRect()
        guard visibleRect.isEmpty == false, visibleRect.intersects(rect) else { return }
        let layoutRect = rect.offsetBy(dx: -visibleRect.minX, dy: -visibleRect.minY)

        context.saveGState()
        UIBezierPath(rect: visibleRect).addClip()
        context.translateBy(x: visibleRect.minX, y: visibleRect.minY)
        defer { context.restoreGState() }

        for fragment in pageLayout.textFragments {
            guard fragment.frame.intersects(layoutRect) else { continue }
            drawText(fragment, in: context)
            // TextColumn.draw / TextLine.drawText cover the painted glyphs with
            // selectedPaint. Keep read-aloud's own background/text styling intact.
            if let selectionRange, selectionRange.length > 0 {
                selectionColor.setFill()
                for rect in ReaderTextSelectionGeometry(fragment: fragment).selectionRects(for: selectionRange) {
                    context.fill(rect)
                }
            }
        }

        for fragment in pageLayout.attachmentFragments where fragment.frame.intersects(layoutRect) {
            switch fragment.source {
            case .spacer:
                continue
            case let .remoteImage(url, altText):
                if let image = loadedImages[url] {
                    let drawRect: CGRect
                    if fragment.contentMode == .scaleAspectFill {
                        drawRect = aspectFillRect(aspectRatio: image.size, in: fragment.frame)
                    } else {
                        drawRect = AVMakeRect(aspectRatio: image.size, insideRect: fragment.frame)
                    }
                    context.saveGState()
                    UIBezierPath(rect: fragment.frame).addClip()
                    image.draw(in: drawRect)
                    context.restoreGState()
                } else {
                    drawPlaceholder(in: fragment.frame, altText: altText, context: context)
                }
            }
        }
    }

    func layoutPoint(at point: CGPoint) -> CGPoint? {
        let visibleRect = effectiveVisibleRect()
        guard visibleRect.contains(point) else { return nil }
        return CGPoint(x: point.x - visibleRect.minX, y: point.y - visibleRect.minY)
    }

    func viewRect(for layoutRect: CGRect) -> CGRect {
        let visibleRect = effectiveVisibleRect()
        return layoutRect.offsetBy(dx: visibleRect.minX, dy: visibleRect.minY)
    }

    private func effectiveVisibleRect() -> CGRect {
        let candidate = visibleRect == .zero ? bounds : visibleRect
        return candidate.intersection(bounds)
    }

    private func updateImageRequests() {
        var imageFragments: [URL: ReaderAttachmentLayoutFragment] = [:]
        for fragment in pageLayout?.attachmentFragments ?? [] {
            if case let .remoteImage(url, _) = fragment.source {
                imageFragments[url] = fragment
            }
        }
        let urls = Set(imageFragments.keys)
        loadedImages = loadedImages.filter { urls.contains($0.key) }
        loadingURLs = loadingURLs.filter { urls.contains($0) }
        imageTasks.keys.filter { urls.contains($0) == false }.forEach { url in
            imageTasks[url]?.cancel()
            imageTasks.removeValue(forKey: url)
            imageRequestIDs.removeValue(forKey: url)
        }

        for (url, fragment) in imageFragments where loadedImages[url] == nil && loadingURLs.contains(url) == false {
            guard window != nil else { continue }
            loadingURLs.insert(url)
            imageTasks[url]?.cancel()
            let requestID = UUID()
            let requestedBookURL = bookURL
            let requestRule = fragment.requestRule
            imageRequestIDs[url] = requestID
            imageTasks[url] = Task { [weak self] in
                let image: UIImage?
                if let requestedBookURL {
                    // A source-aware request must not silently retry without its headers/decoder.
                    image = await BookCoverImageLoader.loadDecodedImage(
                        bookUrl: requestedBookURL, imageUrl: requestRule ?? url.absoluteString, isCover: false)
                } else if requestRule == nil {
                    image = await withCheckedContinuation { continuation in
                        KingfisherManager.shared.retrieveImage(with: url) { result in
                            continuation.resume(returning: try? result.get().image)
                        }
                    }
                } else {
                    // Raw source rules need book context, never a plain-URL network fallback.
                    image = nil
                }
                guard !Task.isCancelled, let self, self.window != nil,
                    self.bookURL == requestedBookURL, self.imageRequestIDs[url] == requestID
                else { return }
                self.loadingURLs.remove(url)
                self.imageTasks.removeValue(forKey: url)
                self.imageRequestIDs.removeValue(forKey: url)
                if let image { self.loadedImages[url] = image }
                self.setNeedsDisplay()
            }
        }
    }

    private func cancelImageRequests() {
        imageTasks.values.forEach { $0.cancel() }
        imageTasks.removeAll()
        imageRequestIDs.removeAll()
        loadingURLs.removeAll()
    }

    private func attributedText(for fragment: ReaderTextLayoutFragment) -> NSAttributedString {
        let isReadAloud = highlightedBlockIndex == fragment.blockIndex
        let searchRange = localSearchResultRange(for: fragment)
        guard isReadAloud || searchRange != nil else {
            return fragment.attributedText
        }
        let highlighted = NSMutableAttributedString(attributedString: fragment.attributedText)
        if isReadAloud {
            let range = NSRange(location: 0, length: highlighted.length)
            highlighted.addAttribute(.backgroundColor, value: theme.textColor.withAlphaComponent(0.18), range: range)
            highlighted.addAttribute(.foregroundColor, value: theme.textColor, range: range)
        }
        if let searchRange {
            highlighted.addAttribute(
                .foregroundColor, value: AndroidReplicaTheme.accent.resolvedColor(with: traitCollection), range: searchRange)
        }
        return highlighted
    }

    private func localSearchResultRange(for fragment: ReaderTextLayoutFragment) -> NSRange? {
        guard let searchResultRange,
            ReaderTextSelectionGeometry.isValidSelectionRange(searchResultRange),
            ReaderTextSelectionGeometry.isValidSelectionRange(fragment.sourceRange)
        else { return nil }
        let intersection = NSIntersectionRange(searchResultRange, fragment.sourceRange)
        guard intersection.length > 0 else { return nil }
        let localRange = NSRange(
            location: intersection.location - fragment.sourceRange.location, length: intersection.length)
        let boundedRange = NSIntersectionRange(localRange, NSRange(location: 0, length: fragment.attributedText.length))
        return boundedRange.length > 0 ? boundedRange : nil
    }

    private func drawText(_ fragment: ReaderTextLayoutFragment, in context: CGContext) {
        if highlightedBlockIndex == fragment.blockIndex {
            theme.textColor.withAlphaComponent(0.18).setFill()
            UIBezierPath(rect: fragment.frame).fill()
        }
        let attributed = attributedText(for: fragment)
        let frame = ReaderTextSelectionGeometry.makeFrame(for: attributed, size: fragment.frame.size)
        context.saveGState()
        context.textMatrix = .identity
        context.setShouldSmoothFonts(true)
        context.setShouldSubpixelPositionFonts(true)
        context.translateBy(x: fragment.frame.minX, y: fragment.frame.minY + fragment.frame.height)
        context.scaleBy(x: 1, y: -1)
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    private func drawPlaceholder(in frame: CGRect, altText: String?, context: CGContext) {
        let roundedPath = UIBezierPath(roundedRect: frame, cornerRadius: 12)
        context.saveGState()
        theme.textColor.withAlphaComponent(0.08).setFill()
        roundedPath.fill()
        theme.textColor.withAlphaComponent(0.18).setStroke()
        roundedPath.lineWidth = 1
        roundedPath.stroke()

        let iconConfig = UIImage.SymbolConfiguration(pointSize: min(frame.height * 0.18, 28), weight: .regular)
        let icon = UIImage(systemName: "photo", withConfiguration: iconConfig)
        let iconSize = icon?.size ?? .zero
        let iconRect = CGRect(
            x: frame.midX - iconSize.width / 2,
            y: frame.midY - iconSize.height / 2 - 10,
            width: iconSize.width,
            height: iconSize.height
        )
        icon?.withTintColor(theme.textColor.withAlphaComponent(0.3), renderingMode: .alwaysOriginal).draw(in: iconRect)

        if let altText, altText.isEmpty == false {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 12, weight: .regular),
                .foregroundColor: theme.textColor.withAlphaComponent(0.55),
                .paragraphStyle: centeredParagraphStyle(),
            ]
            let textRect = CGRect(
                x: frame.minX + 12,
                y: min(iconRect.maxY + 8, frame.maxY - 38),
                width: frame.width - 24,
                height: max(frame.maxY - iconRect.maxY - 16, 18)
            )
            NSString(string: altText).draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes, context: nil)
        }
        context.restoreGState()
    }

    private func aspectFillRect(aspectRatio: CGSize, in rect: CGRect) -> CGRect {
        guard aspectRatio.width > 0, aspectRatio.height > 0, rect.width > 0, rect.height > 0 else {
            return rect
        }
        let scale = max(rect.width / aspectRatio.width, rect.height / aspectRatio.height)
        let width = aspectRatio.width * scale
        let height = aspectRatio.height * scale
        return CGRect(
            x: rect.midX - width / 2,
            y: rect.midY - height / 2,
            width: width,
            height: height
        )
    }

    private func centeredParagraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        return style
    }
}
