import UIKit
import shared

@MainActor
final class MangaReaderStripController: NSObject, UICollectionViewDataSource, UICollectionViewDelegate {
    private struct Anchor {
        let key: MangaWindowPageKey
        var verticalFraction: CGFloat = 0
        var horizontalFraction: CGFloat = 0
        var chapterEdge: MangaChapterTitle.Edge?

        func layoutAnchor(at row: Int) -> MangaReaderLayoutAnchor {
            MangaReaderLayoutAnchor(
                position: row, verticalFraction: verticalFraction, horizontalFraction: horizontalFraction,
                chapterEdge: chapterEdge)
        }
    }

    private struct CellBinding {
        weak var cell: MangaPageCell?
        let token: UUID
    }

    let collection: UICollectionView
    let layout: MangaReaderLayout
    let prefetcher = MangaReaderLayoutPrefetcher()
    private(set) var pages: [MangaWindowPage] = []
    var canInteract: () -> Bool = { true }
    var onPageChanged: ((MangaWindowPage) -> Void)?
    var onDragBegan: (() -> Void)?
    var onScrollSettled: (() -> Void)?
    var hasPendingPages: Bool { pendingPages != nil }

    private let pipeline: MangaImagePipeline
    private var options = MangaReadingOptions()
    private var imagePages: [MangaPage] = []
    private var rowsByKey: [MangaWindowPageKey: Int] = [:]
    private var chapterTitles: [MangaChapterTitle.ID: MangaChapterTitle] = [:]
    private var pendingPages: [MangaWindowPage]?
    private var deferredAnchor: Anchor?
    private var lastReportedKey: MangaWindowPageKey?
    private var snapshotRevision = UUID()
    private var cellBindings: [ObjectIdentifier: CellBinding] = [:]
    private var isApplyingPosition = false
    private var isSettlingScroll = false
    private var isCancelled = false
    private var prefetchEnabled = false

    init(pipeline: MangaImagePipeline) {
        self.pipeline = pipeline
        let layout = MangaReaderLayout()
        self.layout = layout
        collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init()
        collection.backgroundColor = .black
        collection.dataSource = self
        collection.delegate = self
        collection.isPrefetchingEnabled = false
        collection.contentInsetAdjustmentBehavior = .never
        collection.register(MangaPageCell.self, forCellWithReuseIdentifier: MangaPageCell.reuseIdentifier)
        for edge in [MangaChapterTitle.Edge.leading, .trailing] {
            collection.register(
                MangaChapterTitleView.self, forSupplementaryViewOfKind: edge.rawValue,
                withReuseIdentifier: MangaChapterTitleView.reuseIdentifier)
        }
        layout.configure(options)
    }

    func setPages(_ pages: [MangaWindowPage], restoring key: MangaWindowPageKey? = nil) {
        if key == nil, !isSettlingScroll, collection.isDragging || collection.isDecelerating {
            // Keep the active datasource and geometry unchanged until UIKit finishes the gesture.
            pendingPages = pages
            return
        }
        pendingPages = nil
        applyPages(pages, restoring: key)
    }

    func seek(to key: MangaWindowPageKey) {
        if let pendingPages, pendingPages.contains(where: { $0.key == key }) {
            self.pendingPages = nil
            applyPages(pendingPages, restoring: key)
            return
        }
        guard rowsByKey[key] != nil else { return }
        pendingPages = nil
        let anchor = Anchor(key: key)
        withPositionUpdate {
            collection.setContentOffset(collection.contentOffset, animated: false)
            applyLayout(anchor: anchor)
        }
        reportCurrentPage()
        refreshPrefetch()
    }

    func currentPage() -> MangaWindowPage? {
        guard let anchor = currentAnchor(), let row = rowsByKey[anchor.key], pages.indices.contains(row) else {
            return nil
        }
        return pages[row]
    }

    func updateViewport() {
        guard hasViewport, layout.needsViewportUpdate || deferredAnchor != nil else { return }
        applyLayout(anchor: currentAnchor())
        refreshPrefetch()
    }

    func applyOptions(_ options: MangaReadingOptions) {
        let previous = self.options
        let anchor = currentAnchor()
        self.options = options
        let layoutChanged =
            previous.horizontalScroll != options.horizontalScroll || previous.pageSnap != options.pageSnap
            || previous.animatesPages != options.animatesPages
        let displayChanged =
            previous.displayStyle != options.displayStyle
            || previous.colorFilter.pixelVariant != options.colorFilter.pixelVariant
        let titlesChanged = previous.hideChapterTitle != options.hideChapterTitle
        if displayChanged { prefetcher.reset() }
        if layoutChanged || displayChanged || titlesChanged {
            withPositionUpdate {
                collection.setContentOffset(collection.contentOffset, animated: false)
                if layoutChanged { layout.configure(options) }
                if titlesChanged {
                    rebuildChapterTitles()
                    layout.setChapterTitles(Array(chapterTitles.values))
                }
                if displayChanged { invalidateCellBindings() }
                applyLayout(anchor: anchor, reloadImages: displayChanged, preservingFraction: !layoutChanged)
            }
        }
        refreshPrefetch()
    }

    func updatePrefetch(enabled: Bool) {
        prefetchEnabled = enabled
        if enabled, isCancelled {
            isCancelled = false
            for path in collection.indexPathsForVisibleItems {
                guard let cell = collection.cellForItem(at: path) as? MangaPageCell else { continue }
                configure(cell, at: path)
            }
        }
        refreshPrefetch()
    }

    func didMoveAutomatically() {
        deferredAnchor = nil
        layout.releaseRestoredAnchor()
        scrollViewDidScroll(collection)
    }

    func cancel() {
        isCancelled = true
        pendingPages = nil
        prefetcher.cancel()
        invalidateCellBindings()
    }

    private var hasViewport: Bool { collection.bounds.width > 0 && collection.bounds.height > 0 }

    private func currentAnchor() -> Anchor? {
        if let deferredAnchor { return deferredAnchor }
        guard let anchor = layout.anchor(pendingPosition: nil), pages.indices.contains(anchor.position) else { return nil }
        return Anchor(
            key: pages[anchor.position].key,
            verticalFraction: anchor.verticalFraction, horizontalFraction: anchor.horizontalFraction,
            chapterEdge: anchor.chapterEdge)
    }

    private func applyPages(_ pages: [MangaWindowPage], restoring key: MangaWindowPageKey?) {
        let previousAnchor = currentAnchor()
        var nextRows: [MangaWindowPageKey: Int] = [:]
        for (row, page) in pages.enumerated() where nextRows[page.key] == nil { nextRows[page.key] = row }
        let anchor: Anchor?
        if let key, nextRows[key] != nil {
            anchor = Anchor(key: key)
        } else if let previousAnchor, nextRows[previousAnchor.key] != nil {
            anchor = previousAnchor
        } else if let previousAnchor, let previousRow = rowsByKey[previousAnchor.key] {
            // If the visible page itself was removed, prefer the next surviving old page, then the previous one.
            let next = self.pages.dropFirst(previousRow).first { nextRows[$0.key] != nil }
            let previous = self.pages.prefix(previousRow).reversed().first { nextRows[$0.key] != nil }
            anchor = (next ?? previous ?? pages.first).map { Anchor(key: $0.key) }
        } else {
            anchor = pages.first.map { Anchor(key: $0.key) }
        }
        let hasRetainedPages = nextRows.keys.contains { rowsByKey[$0] != nil }
        withPositionUpdate {
            if key != nil { collection.setContentOffset(collection.contentOffset, animated: false) }
            invalidateCellBindings()
            if !hasRetainedPages { prefetcher.reset() }
            self.pages = pages
            imagePages = pages.map(\.page)
            rowsByKey = nextRows
            rebuildChapterTitles()
            isCancelled = false
            layout.setPages(imagePages.map(\.mImageUrl), chapterTitles: Array(chapterTitles.values))
            applyLayout(anchor: anchor, reloadImages: true)
        }
        if pages.isEmpty { lastReportedKey = nil }
        reportCurrentPage()
        refreshPrefetch()
    }

    private func rebuildChapterTitles() {
        chapterTitles.removeAll(keepingCapacity: true)
        guard !options.hideChapterTitle else { return }
        for (row, item) in pages.enumerated() where rowsByKey[item.key] == row {
            // ReadManga / MangaChapterParser use full-height volume markers only for image-less chapters.
            // The window contains images only, including any image-bearing volume chapter.
            let name = item.page.mChapterName
            if item.position == 0 {
                let title = MangaChapterTitle(position: row, edge: .leading, message: "阅读 \(name)")
                chapterTitles[title.id] = title
            }
            if item.position == item.chapter.pages.count - 1 {
                let title = MangaChapterTitle(position: row, edge: .trailing, message: "已读完 \(name)")
                chapterTitles[title.id] = title
            }
        }
    }

    private func withPositionUpdate(_ update: () -> Void) {
        let wasApplyingPosition = isApplyingPosition
        isApplyingPosition = true
        defer { isApplyingPosition = wasApplyingPosition }
        update()
    }

    private func applyLayout(anchor: Anchor?, reloadImages: Bool = false, preservingFraction: Bool = true) {
        withPositionUpdate {
            deferredAnchor = anchor
            layout.updateViewport()
            if reloadImages { collection.reloadData() }
            guard hasViewport else { return }
            collection.layoutIfNeeded()
            if let anchor, let row = rowsByKey[anchor.key] {
                layout.restore(anchor.layoutAnchor(at: row), preservingFraction: preservingFraction)
                collection.layoutIfNeeded()
            }
            deferredAnchor = nil
        }
        refreshVisibleTiles()
    }

    private func refreshVisibleTiles() {
        for case let cell as MangaPageCell in collection.visibleCells { cell.refreshVisibleTiles() }
    }

    private func invalidateCellBindings() {
        snapshotRevision = UUID()
        for binding in cellBindings.values { binding.cell?.cancelLoad() }
        cellBindings.removeAll()
    }

    private func configure(_ cell: MangaPageCell, at indexPath: IndexPath) {
        guard !isCancelled, indexPath.section == 0, pages.indices.contains(indexPath.item) else { return }
        let windowPage = pages[indexPath.item]
        let key = windowPage.key
        let page = windowPage.page
        let revision = snapshotRevision
        let style = options.displayStyle
        let filter = options.colorFilter.pixelVariant
        let token = UUID()
        let identifier = ObjectIdentifier(cell)
        cellBindings[identifier] = CellBinding(cell: cell, token: token)
        cell.configure(page: page, pipeline: pipeline, pixelWidth: layout.pixelWidth, displayStyle: style, colorFilter: filter) {
            [weak self, weak cell] ratio in
            guard let self, let cell, !self.isCancelled, self.snapshotRevision == revision,
                self.options.displayStyle == style, self.options.colorFilter.pixelVariant == filter,
                self.cellBindings[identifier]?.token == token,
                let path = self.collection.indexPath(for: cell), path.section == 0,
                self.pages.indices.contains(path.item), self.pages[path.item].key == key,
                self.pages[path.item].page.mImageUrl == page.mImageUrl
            else { return }
            let anchor = self.currentAnchor()
            if self.layout.setAspectRatio(ratio, for: page.mImageUrl) { self.applyLayout(anchor: anchor) }
        }
    }

    private func reportCurrentPage() {
        guard !isApplyingPosition, !isCancelled, canInteract(), let page = currentPage(), page.key != lastReportedKey else {
            return
        }
        lastReportedKey = page.key
        onPageChanged?(page)
    }

    private func refreshPrefetch() {
        guard !isApplyingPosition else { return }
        guard prefetchEnabled, !isCancelled, canInteract(), hasViewport, !layout.needsViewportUpdate, !pages.isEmpty else {
            prefetcher.cancel()
            return
        }
        let position = currentAnchor().flatMap { rowsByKey[$0.key] } ?? 0
        prefetcher.update(
            pages: imagePages, visible: collection.indexPathsForVisibleItems.map(\.item),
            position: position, direction: layout.scrollDirection, count: options.prefetchCount,
            pixelWidth: layout.pixelWidth, displayStyle: options.displayStyle, colorFilter: options.colorFilter,
            pipeline: pipeline)
    }

    private func scrollSettled() {
        guard !isApplyingPosition, !isSettlingScroll else { return }
        isSettlingScroll = true
        defer { isSettlingScroll = false }
        if let pendingPages {
            self.pendingPages = nil
            applyPages(pendingPages, restoring: nil)
        }
        guard !isCancelled else { return }
        reportCurrentPage()
        refreshPrefetch()
        refreshVisibleTiles()
        if canInteract() { onScrollSettled?() }
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        pages.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: MangaPageCell.reuseIdentifier, for: indexPath)
        if let cell = cell as? MangaPageCell { configure(cell, at: indexPath) }
        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath
    ) -> UICollectionReusableView {
        let view = collectionView.dequeueReusableSupplementaryView(
            ofKind: kind, withReuseIdentifier: MangaChapterTitleView.reuseIdentifier, for: indexPath)
        if let view = view as? MangaChapterTitleView, let edge = MangaChapterTitle.Edge(rawValue: kind),
            let title = chapterTitles[MangaChapterTitle.ID(position: indexPath.item, edge: edge)]
        {
            view.configure(title)
        }
        return view
    }

    func collectionView(
        _ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath
    ) {
        cellBindings.removeValue(forKey: ObjectIdentifier(cell))
        (cell as? MangaPageCell)?.cancelLoad()
    }

    func collectionView(
        _ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath
    ) {
        guard !isCancelled, let cell = cell as? MangaPageCell else { return }
        if cellBindings[ObjectIdentifier(cell)] == nil {
            configure(cell, at: indexPath)
        } else {
            cell.resumeLoad()
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard !isApplyingPosition else { return }
        deferredAnchor = nil
        _ = currentAnchor()
        layout.beginDragging()
        if !isCancelled, canInteract() { onDragBegan?() }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isApplyingPosition, !layout.needsViewportUpdate, deferredAnchor == nil else { return }
        layout.userDidScroll()
        reportCurrentPage()
        refreshPrefetch()
        refreshVisibleTiles()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { scrollSettled() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { scrollSettled() }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { scrollSettled() }
}
