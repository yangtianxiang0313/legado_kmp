import UIKit

struct MangaReaderLayoutAnchor {
    let position: Int
    var verticalFraction: CGFloat = 0
    var horizontalFraction: CGFloat = 0
    var chapterEdge: MangaChapterTitle.Edge?
}

@MainActor
final class MangaReaderLayout: UICollectionViewLayout {
    enum TapAction {
        case controls, page(Int), none
    }

    private var imageURLs: [String] = []
    private var aspectRatios: [String: CGFloat] = [:]
    private var attributes: [UICollectionViewLayoutAttributes] = []
    private var chapterTitles: [MangaChapterTitle.ID: MangaChapterTitle] = [:]
    private var titleAttributes: [MangaChapterTitle.ID: UICollectionViewLayoutAttributes] = [:]
    private var flowAttributes: [UICollectionViewLayoutAttributes] = []
    private var size = CGSize.zero
    private var viewport = CGSize.zero
    private var insets = UIEdgeInsets.zero
    private var horizontal = false
    private var configuredPageSnap = false
    private var automaticScrolling = false
    private var snapsPages: Bool { configuredPageSnap && !automaticScrolling }
    private var dragStart: Int?
    private var lastCoordinate: CGFloat?
    private var restoredAnchor: MangaReaderLayoutAnchor?
    private(set) var savedAnchor: MangaReaderLayoutAnchor?
    private(set) var scrollDirection = 1

    override var collectionViewContentSize: CGSize { size }

    var needsViewportUpdate: Bool {
        guard let collectionView else { return false }
        return viewport != collectionView.bounds.size || insets != collectionView.adjustedContentInset
    }

    var pixelWidth: Int {
        let scale = collectionView?.window?.screen.scale ?? UIScreen.main.scale
        return min(4096, max(320, Int(max(1, viewport.width - insets.left - insets.right) * scale)))
    }

    // Title-only viewports have no image cell; the automatic-reading driver may advance through them.
    var hasVisibleChapterTitle: Bool {
        guard let collectionView, !needsViewportUpdate else { return false }
        let rect = collectionView.bounds.inset(by: insets)
        return titleAttributes.values.contains { $0.frame.intersects(rect) }
    }

    func updateViewport() {
        guard let collectionView else { return }
        viewport = collectionView.bounds.size
        insets = collectionView.adjustedContentInset
        invalidateLayout()
    }

    func configure(_ options: MangaReadingOptions) {
        horizontal = options.horizontalScroll
        // Android detaches PagerSnapHelper when page animation is disabled.
        configuredPageSnap = horizontal && options.pageSnap && options.animatesPages
        collectionView?.decelerationRate = snapsPages ? .fast : .normal
        collectionView?.alwaysBounceHorizontal = horizontal
        collectionView?.alwaysBounceVertical = !horizontal
        dragStart = nil
        invalidateLayout()
    }

    func setAutomaticScrolling(_ enabled: Bool) {
        guard automaticScrolling != enabled else { return }
        automaticScrolling = enabled
        collectionView?.decelerationRate = snapsPages ? .fast : .normal
        dragStart = nil
    }

    func setPages(_ urls: [String], chapterTitles: [MangaChapterTitle] = []) {
        let retainedURLs = Set(urls)
        let hasRetainedPages = imageURLs.contains { retainedURLs.contains($0) }
        imageURLs = urls
        aspectRatios = aspectRatios.filter { retainedURLs.contains($0.key) }
        savedAnchor = nil
        restoredAnchor = nil
        lastCoordinate = nil
        dragStart = nil
        if !hasRetainedPages { scrollDirection = 1 }
        setChapterTitles(chapterTitles)
    }

    func setChapterTitles(_ titles: [MangaChapterTitle]) {
        chapterTitles.removeAll(keepingCapacity: true)
        for title in titles where imageURLs.indices.contains(title.position) {
            chapterTitles[title.id] = title
        }
        invalidateLayout()
    }

    @discardableResult
    func setAspectRatio(_ ratio: CGFloat, for imageURL: String) -> Bool {
        guard ratio.isFinite, ratio > 0, abs((aspectRatios[imageURL] ?? 0) - ratio) > 0.001 else { return false }
        aspectRatios[imageURL] = ratio
        if !horizontal { invalidateLayout() }
        return !horizontal
    }

    override func prepare() {
        super.prepare()
        let width = max(1, viewport.width - insets.left - insets.right)
        let height = max(1, viewport.height - insets.top - insets.bottom)
        var origin: CGFloat = 0
        attributes.removeAll(keepingCapacity: true)
        titleAttributes.removeAll(keepingCapacity: true)
        flowAttributes.removeAll(keepingCapacity: true)
        for (index, url) in imageURLs.enumerated() {
            origin = appendTitle(at: index, edge: .leading, origin: origin, width: width, height: height)
            let itemHeight =
                horizontal ? height : max(1, aspectRatios[url].map { width * $0 } ?? max(width, height * 0.75))
            let attribute = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
            attribute.frame = CGRect(
                x: horizontal ? origin : 0, y: horizontal ? 0 : origin, width: width, height: itemHeight)
            origin += horizontal ? width : itemHeight
            attributes.append(attribute)
            flowAttributes.append(attribute)
            origin = appendTitle(at: index, edge: .trailing, origin: origin, width: width, height: height)
        }
        // Android gives the final strip a viewport minimum height; keep the bitmap itself top-aligned.
        let stripHeight = attributes.last.map { max(origin, $0.frame.minY + height) } ?? 0
        size = horizontal ? CGSize(width: origin, height: height) : CGSize(width: width, height: stripHeight)
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard !flowAttributes.isEmpty else { return [] }
        let start = index(at: horizontal ? rect.minX : rect.minY)
        var visible: [UICollectionViewLayoutAttributes] = []
        for index in start..<flowAttributes.count {
            let attribute = flowAttributes[index]
            if (horizontal ? attribute.frame.minX > rect.maxX : attribute.frame.minY > rect.maxY) { break }
            if attribute.frame.intersects(rect) { visible.append(attribute) }
        }
        return visible
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard indexPath.section == 0, attributes.indices.contains(indexPath.item) else { return nil }
        return attributes[indexPath.item]
    }

    override func layoutAttributesForSupplementaryView(
        ofKind elementKind: String, at indexPath: IndexPath
    ) -> UICollectionViewLayoutAttributes? {
        guard indexPath.section == 0, let edge = MangaChapterTitle.Edge(rawValue: elementKind) else { return nil }
        return titleAttributes[MangaChapterTitle.ID(position: indexPath.item, edge: edge)]
    }

    // The controller captures the old geometry's anchor before explicitly updating both viewport axes.
    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool { false }

    func anchor(pendingPosition: Int?) -> MangaReaderLayoutAnchor? {
        guard !imageURLs.isEmpty, let collectionView else { return nil }
        if let pendingPosition {
            return savedAnchor?.position == pendingPosition
                ? savedAnchor : MangaReaderLayoutAnchor(position: pendingPosition)
        }
        if let restoredAnchor { return restoredAnchor }
        if needsViewportUpdate, let savedAnchor { return savedAnchor }
        guard !flowAttributes.isEmpty else { return savedAnchor }
        let coordinate =
            horizontal ? collectionView.contentOffset.x + insets.left : collectionView.contentOffset.y + insets.top
        // UIKit rounds offsets to physical pixels, which can leave a short final page just below its boundary.
        let pixel = 1 / max(1, collectionView.window?.screen.scale ?? UIScreen.main.scale)
        let attribute = flowAttributes[index(at: max(0, coordinate) + pixel)]
        let position = attribute.indexPath.item
        let frame = attribute.frame
        let edge = attribute.representedElementKind.flatMap { MangaChapterTitle.Edge(rawValue: $0) }
        var anchor = MangaReaderLayoutAnchor(position: position, chapterEdge: edge)
        if let savedAnchor, savedAnchor.position == position, savedAnchor.chapterEdge == edge { anchor = savedAnchor }
        anchor.chapterEdge = edge
        let fraction = max(
            0, min(1, (coordinate - (horizontal ? frame.minX : frame.minY)) / max(1, horizontal ? frame.width : frame.height)))
        if horizontal { anchor.horizontalFraction = fraction } else { anchor.verticalFraction = fraction }
        if let lastCoordinate, abs(coordinate - lastCoordinate) > 0.5 {
            scrollDirection = coordinate > lastCoordinate ? 1 : -1
        }
        lastCoordinate = coordinate
        savedAnchor = anchor
        return anchor
    }

    func restore(_ anchor: MangaReaderLayoutAnchor, preservingFraction: Bool = false) {
        guard let collectionView, attributes.indices.contains(anchor.position) else { return }
        var anchor = anchor
        var frame = attributes[anchor.position].frame
        if let edge = anchor.chapterEdge {
            if let title = titleAttributes[MangaChapterTitle.ID(position: anchor.position, edge: edge)] {
                frame = title.frame
            } else {
                // Hiding an edge returns to its image, never to the neighboring chapter's image.
                anchor.chapterEdge = nil
                anchor.horizontalFraction = 0
                let height = max(1, viewport.height - insets.top - insets.bottom)
                anchor.verticalFraction = edge == .trailing ? max(0, 1 - height / frame.height) : 0
            }
        }
        if horizontal, snapsPages, !preservingFraction { anchor.horizontalFraction = 0 }
        let coordinate =
            horizontal
            ? frame.minX + frame.width * anchor.horizontalFraction
            : frame.minY + frame.height * anchor.verticalFraction
        let offset = boundedOffset(coordinate - (horizontal ? insets.left : insets.top))
        savedAnchor = anchor
        // Offset clamping must not turn an explicitly selected final image into the preceding image in progress storage.
        restoredAnchor = anchor
        lastCoordinate = offset + (horizontal ? insets.left : insets.top)
        collectionView.setContentOffset(point(at: offset), animated: false)
    }

    func beginDragging() {
        guard let collectionView else { return }
        releaseRestoredAnchor()
        dragStart = nearestPage(to: collectionView.contentOffset.x)
    }

    func releaseRestoredAnchor() { restoredAnchor = nil }

    func userDidScroll() {
        guard let collectionView, collectionView.isDragging || collectionView.isDecelerating else { return }
        releaseRestoredAnchor()
    }

    override func targetContentOffset(
        forProposedContentOffset proposedContentOffset: CGPoint, withScrollingVelocity velocity: CGPoint
    ) -> CGPoint {
        guard snapsPages, !flowAttributes.isEmpty else { return proposedContentOffset }
        var target = nearestPage(to: proposedContentOffset.x)
        if abs(velocity.x) > 0.05, let collectionView {
            let width = max(1, viewport.width - insets.left - insets.right)
            let page = (collectionView.contentOffset.x + insets.left) / width
            target = Int(velocity.x > 0 ? ceil(page) : floor(page))
            if target == dragStart { target += velocity.x > 0 ? 1 : -1 }
        }
        target = max(0, min(flowAttributes.count - 1, target))
        return point(at: boundedOffset(flowAttributes[target].frame.minX - insets.left))
    }

    func pageOffset(by direction: Int) -> CGPoint? {
        guard let collectionView, !attributes.isEmpty else { return nil }
        let current = horizontal ? collectionView.contentOffset.x : collectionView.contentOffset.y
        let extent =
            horizontal ? viewport.width - insets.left - insets.right : viewport.height - insets.top - insets.bottom
        let target = boundedOffset(current + CGFloat(direction) * max(1, extent))
        guard abs(target - current) > 0.5 else { return nil }
        return point(at: target)
    }

    func autoOffset(distance: CGFloat) -> CGPoint? {
        guard distance.isFinite, distance > 0, let collectionView, !attributes.isEmpty else { return nil }
        var offset = collectionView.contentOffset
        let current = horizontal ? offset.x : offset.y
        let target = boundedOffset(current + distance)
        guard target > current else { return nil }
        if horizontal { offset.x = target } else { offset.y = target }
        return offset
    }

    func isPastEnd(threshold: CGFloat) -> Bool {
        guard let collectionView, !attributes.isEmpty, !needsViewportUpdate else { return false }
        let current = horizontal ? collectionView.contentOffset.x : collectionView.contentOffset.y
        return current > maximumOffset + threshold
    }

    func tapAction(at point: CGPoint, clickScroll: Bool) -> TapAction {
        guard let collectionView else { return .none }
        let rect = collectionView.bounds.inset(by: insets)
        guard rect.width > 0, rect.height > 0, rect.contains(point) else { return .none }
        let x = (point.x - rect.minX) / rect.width
        let y = (point.y - rect.minY) / rect.height
        if (0.33...0.66).contains(x), (0.33...0.66).contains(y) { return .controls }
        guard clickScroll, y >= 0.66 else { return .none }
        if x <= 0.33 { return .page(-1) }
        if x >= 0.66 { return .page(1) }
        return .none
    }

    private var minimumOffset: CGFloat { horizontal ? -insets.left : -insets.top }
    private var maximumOffset: CGFloat {
        max(
            minimumOffset,
            horizontal ? size.width - viewport.width + insets.right : size.height - viewport.height + insets.bottom)
    }

    private func boundedOffset(_ value: CGFloat) -> CGFloat { min(maximumOffset, max(minimumOffset, value)) }
    private func point(at coordinate: CGFloat) -> CGPoint {
        horizontal ? CGPoint(x: coordinate, y: -insets.top) : CGPoint(x: -insets.left, y: coordinate)
    }

    private func nearestPage(to offset: CGFloat) -> Int {
        let width = max(1, viewport.width - insets.left - insets.right)
        return max(0, min(flowAttributes.count - 1, Int(((offset + insets.left) / width).rounded())))
    }

    private func appendTitle(
        at position: Int, edge: MangaChapterTitle.Edge, origin: CGFloat, width: CGFloat, height: CGFloat
    ) -> CGFloat {
        let id = MangaChapterTitle.ID(position: position, edge: edge)
        guard let title = chapterTitles[id] else { return origin }
        let titleHeight = horizontal || title.isVolume ? height : MangaChapterTitleView.normalHeight
        let attribute = UICollectionViewLayoutAttributes(
            forSupplementaryViewOfKind: edge.rawValue, with: IndexPath(item: position, section: 0))
        attribute.frame = CGRect(
            x: horizontal ? origin : 0, y: horizontal ? 0 : origin, width: width, height: titleHeight)
        titleAttributes[id] = attribute
        flowAttributes.append(attribute)
        return origin + (horizontal ? width : titleHeight)
    }

    private func index(at coordinate: CGFloat) -> Int {
        var lower = 0
        var upper = flowAttributes.count
        while lower < upper {
            let middle = (lower + upper) / 2
            let frame = flowAttributes[middle].frame
            if (horizontal ? frame.maxX : frame.maxY) <= coordinate { lower = middle + 1 } else { upper = middle }
        }
        return min(max(0, flowAttributes.count - 1), lower)
    }
}
