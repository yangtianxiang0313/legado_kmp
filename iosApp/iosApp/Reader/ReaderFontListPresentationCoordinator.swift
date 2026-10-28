import UIKit

/// Owns font-list snapshots and deferred preview delivery, not directory or selection operations.
@MainActor
final class ReaderFontListPresentationCoordinator: NSObject, UITableViewDataSource, UITableViewDelegate {
    var canDeliver: (() -> Bool)?
    var canSelect: (() -> Bool)?
    var textColor: (() -> UIColor)?
    var isSelected: ((ReaderFontEntry) -> Bool)?
    var onSelect: ((ReaderFontEntry) -> Void)?

    private(set) var entries: [ReaderFontEntry] = []
    private struct Catalog {
        let entries: [ReaderFontEntry]
        let onApply: () -> Void
    }
    private struct RowSnapshot {
        let generation: UUID
        let row: Int
        let entry: ReaderFontEntry
        let cell: ObjectIdentifier
    }
    private struct Preview {
        let entry: ReaderFontEntry
        let font: UIFont
    }

    private weak var tableView: UITableView?
    private let previewCache = NSCache<NSString, UIFont>()
    private var pendingPreviews = Set<String>()
    private var resolvedPreviews: [String: Preview] = [:]
    private var generation = UUID()
    private var presentedGeneration: UUID?
    private var requestedSize: CGFloat = 14
    private var presentedSize: CGFloat = 14
    private var pendingCatalog: Catalog?
    private var isLoadingCatalog = false
    private var needsReload = true
    private var isClosed = false
    private var isDelivering = false
    private var scheduledGeneration: UUID?
    private var cellSnapshots: [ObjectIdentifier: RowSnapshot] = [:]
    private var highlightedSnapshot: RowSnapshot?
    private var selectionSnapshot: RowSnapshot?

    init(tableView: UITableView) {
        self.tableView = tableView
        super.init()
        previewCache.countLimit = 256
        tableView.dataSource = self
        tableView.delegate = self
        tableView.panGestureRecognizer.addTarget(self, action: #selector(panChanged(_:)))
    }

    func resetPreviews(traits: UITraitCollection, discardCatalog: Bool = false) {
        guard !isClosed else { return }
        generation = UUID()
        requestedSize = UIFontMetrics(forTextStyle: .body).scaledValue(for: 14, compatibleWith: traits)
        pendingPreviews.removeAll()
        resolvedPreviews.removeAll()
        scheduledGeneration = nil
        selectionSnapshot = nil
        if discardCatalog { pendingCatalog = nil }
        // Keep already presented fonts until the replacement can safely reach the table.
        needsReload = true
        resumeDelivery()
    }

    func beginCatalogChange(traits: UITraitCollection) {
        isLoadingCatalog = true
        resetPreviews(traits: traits, discardCatalog: true)
    }

    func stageEntries(_ entries: [ReaderFontEntry], onApply: @escaping () -> Void) {
        guard !isClosed else { return }
        pendingCatalog = Catalog(entries: entries, onApply: onApply)
        needsReload = true
        resumeDelivery()
    }

    func finishCatalogChange() {
        isLoadingCatalog = false
        resumeDelivery()
    }

    func close() {
        isClosed = true
        generation = UUID()
        scheduledGeneration = nil
        pendingCatalog = nil
        pendingPreviews.removeAll()
        resolvedPreviews.removeAll()
        cellSnapshots.removeAll()
        highlightedSnapshot = nil
        selectionSnapshot = nil
        previewCache.removeAllObjects()
    }

    func resumeDelivery() {
        requestVisiblePreviews()
        guard !isClosed, !isDelivering, !isLoadingCatalog,
            needsReload || !resolvedPreviews.isEmpty, scheduledGeneration != generation
        else { return }
        let generation = generation
        scheduledGeneration = generation
        // A bounded window batches independently resolved fonts without starving a long catalog.
        let deadline = DispatchTime.now() + (needsReload ? 0 : 0.05)
        DispatchQueue.main.asyncAfter(deadline: deadline) { [weak self] in
            guard let self, self.generation == generation, self.scheduledGeneration == generation else { return }
            self.scheduledGeneration = nil
            self.deliver()
        }
    }

    private func requestVisiblePreviews() {
        guard !isClosed, !needsReload, !isLoadingCatalog, presentedGeneration == generation,
            canDeliver?() == true, let tableView
        else { return }
        for path in tableView.indexPathsForVisibleRows ?? [] {
            guard entries.indices.contains(path.row) else { continue }
            let entry = entries[path.row]
            if previewCache.object(forKey: entry.identifier as NSString) == nil { requestPreview(for: entry) }
        }
    }

    private var isListBusy: Bool {
        guard let tableView else { return true }
        let state = tableView.panGestureRecognizer.state
        return tableView.isTracking || tableView.isDragging || tableView.isDecelerating
            || state == .began || state == .changed || selectionSnapshot != nil
            || tableView.visibleCells.contains(where: { $0.isHighlighted })
    }

    private func deliver() {
        guard !isClosed, !isDelivering, !isLoadingCatalog, canDeliver?() == true,
            !isListBusy, let tableView, needsReload || !resolvedPreviews.isEmpty
        else { return }
        isDelivering = true
        defer { isDelivering = false }
        tableView.layoutIfNeeded()
        let anchor = tableView.indexPathsForVisibleRows?.min()
        let anchorEntry = anchor.flatMap { entries.indices.contains($0.row) ? entries[$0.row] : nil }
        let anchorOffset = anchor.map { tableView.rectForRow(at: $0).minY - tableView.contentOffset.y }
        let catalog = pendingCatalog
        pendingCatalog = nil
        if let catalog {
            entries = catalog.entries
            catalog.onApply()
        }
        let reloading = needsReload
        if reloading {
            presentedGeneration = generation
            presentedSize = requestedSize
            previewCache.removeAllObjects()
            cellSnapshots.removeAll(keepingCapacity: true)
            highlightedSnapshot = nil
            selectionSnapshot = nil
            needsReload = false
        }
        let previews = resolvedPreviews
        resolvedPreviews.removeAll(keepingCapacity: true)
        for (key, preview) in previews { previewCache.setObject(preview.font, forKey: key as NSString) }
        UIView.performWithoutAnimation {
            if reloading {
                tableView.reloadData()
            } else {
                var changed = false
                for path in tableView.indexPathsForVisibleRows ?? [] {
                    guard entries.indices.contains(path.row), let preview = previews[entries[path.row].identifier],
                        preview.entry == entries[path.row],
                        let cell = tableView.cellForRow(at: path) as? ReaderFontListCell,
                        let snapshot = cellSnapshots[ObjectIdentifier(cell)], snapshot.generation == generation,
                        snapshot.row == path.row, snapshot.entry == preview.entry, cell.representedEntry == preview.entry
                    else { continue }
                    configure(cell, entry: preview.entry, font: preview.font, at: path)
                    changed = true
                }
                if changed {
                    tableView.beginUpdates()
                    tableView.endUpdates()
                }
            }
            tableView.layoutIfNeeded()
            let minimum = -tableView.adjustedContentInset.top
            let maximum = max(
                minimum,
                tableView.contentSize.height - tableView.bounds.height
                    + tableView.adjustedContentInset.bottom)
            if let anchorEntry, let anchorOffset, let row = entries.firstIndex(of: anchorEntry) {
                let y = tableView.rectForRow(at: IndexPath(row: row, section: 0)).minY - anchorOffset
                tableView.setContentOffset(CGPoint(x: tableView.contentOffset.x, y: min(maximum, max(minimum, y))), animated: false)
            } else if catalog != nil {
                tableView.setContentOffset(CGPoint(x: 0, y: minimum), animated: false)
            }
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { entries.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard entries.indices.contains(indexPath.row),
            let cell = tableView.dequeueReusableCell(
                withIdentifier: ReaderFontListCell.reuseIdentifier, for: indexPath) as? ReaderFontListCell
        else { return UITableViewCell() }
        let entry = entries[indexPath.row]
        let font = previewCache.object(forKey: entry.identifier as NSString)
        configure(cell, entry: entry, font: font ?? defaultPreviewFont(size: presentedSize), at: indexPath)
        if font == nil { requestPreview(for: entry) }
        return cell
    }

    private func configure(_ cell: ReaderFontListCell, entry: ReaderFontEntry, font: UIFont, at path: IndexPath) {
        cell.configure(
            entry: entry, font: font, textColor: textColor?() ?? .label,
            selected: isSelected?(entry) == true, enabled: canSelect?() == true && !needsReload && !isLoadingCatalog)
        if let presentedGeneration {
            cellSnapshots[ObjectIdentifier(cell)] = RowSnapshot(
                generation: presentedGeneration, row: path.row, entry: entry, cell: ObjectIdentifier(cell))
        }
    }

    private func requestPreview(for entry: ReaderFontEntry) {
        guard !isClosed, !needsReload, !isLoadingCatalog, presentedGeneration == generation,
            resolvedPreviews[entry.identifier] == nil, canDeliver?() == true,
            pendingPreviews.insert(entry.identifier).inserted
        else { return }
        let generation = generation
        let size = presentedSize
        Task { [weak self] in
            let resolved = await ReaderFontLibraryWork.previewFont(entry: entry, size: size)
            guard let self, !self.isClosed, self.generation == generation else { return }
            self.pendingPreviews.remove(entry.identifier)
            self.resolvedPreviews[entry.identifier] = Preview(
                entry: entry, font: resolved ?? self.defaultPreviewFont(size: size))
            self.resumeDelivery()
        }
    }

    private func defaultPreviewFont(size: CGFloat) -> UIFont {
        ReaderAndroidDefaultFont.font(size: size) ?? .systemFont(ofSize: size)
    }

    private func selectableSnapshot(at path: IndexPath) -> RowSnapshot? {
        guard !isClosed, !needsReload, !isLoadingCatalog, pendingCatalog == nil,
            presentedGeneration == generation, canSelect?() == true, let tableView,
            !tableView.isDragging, !tableView.isDecelerating, entries.indices.contains(path.row),
            tableView.indexPathsForVisibleRows?.contains(path) == true,
            let cell = tableView.cellForRow(at: path) as? ReaderFontListCell,
            let snapshot = cellSnapshots[ObjectIdentifier(cell)], snapshot.generation == generation,
            snapshot.row == path.row, snapshot.entry == entries[path.row], cell.representedEntry == snapshot.entry
        else { return nil }
        return snapshot
    }

    func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        selectableSnapshot(at: indexPath) != nil
    }

    func tableView(_ tableView: UITableView, didHighlightRowAt indexPath: IndexPath) {
        highlightedSnapshot = selectableSnapshot(at: indexPath)
    }

    func tableView(_ tableView: UITableView, didUnhighlightRowAt indexPath: IndexPath) {
        if highlightedSnapshot?.row == indexPath.row { highlightedSnapshot = nil }
        resumeDelivery()
    }

    func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        selectionSnapshot = nil
        if let highlightedSnapshot, highlightedSnapshot.generation != generation { return nil }
        guard let snapshot = selectableSnapshot(at: indexPath) else { return nil }
        selectionSnapshot = snapshot
        return indexPath
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let selected = selectionSnapshot
        selectionSnapshot = nil
        tableView.deselectRow(at: indexPath, animated: false)
        guard let selected, let current = selectableSnapshot(at: indexPath),
            selected.generation == current.generation, selected.row == current.row,
            selected.cell == current.cell, selected.entry == current.entry
        else { return }
        onSelect?(selected.entry)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        highlightedSnapshot = nil
        selectionSnapshot = nil
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { resumeDelivery() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { resumeDelivery() }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { resumeDelivery() }
    func scrollViewDidScrollToTop(_ scrollView: UIScrollView) { resumeDelivery() }

    @objc private func panChanged(_ recognizer: UIPanGestureRecognizer) {
        if recognizer.state == .ended || recognizer.state == .cancelled || recognizer.state == .failed {
            resumeDelivery()
        }
    }
}
