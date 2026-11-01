import UIKit

/// Keeps a cached result visible while UITableView replaces estimated self-sizing heights.
@MainActor
final class ReaderContentSearchFocusRestoration {
    private struct Request {
        let indexPath: IndexPath
        let isCurrent: () -> Bool
    }

    private struct Geometry: Equatable {
        let bounds: CGRect
        let contentSize: CGSize
        let insets: UIEdgeInsets
        let row: CGRect
    }

    private weak var tableView: UITableView?
    private var request: Request?
    private var generation: UInt = 0
    private var scheduledGeneration: UInt?
    private var observations: [NSKeyValueObservation] = []
    private var isRestoring = false

    init(tableView: UITableView) {
        self.tableView = tableView
    }

    func restore(row: Int, isCurrent: @escaping () -> Bool) {
        cancel()
        guard row >= 0, let tableView else { return }
        request = Request(indexPath: IndexPath(row: row, section: 0), isCurrent: isCurrent)
        let generation = self.generation
        observations = [
            tableView.observe(\.contentSize, options: [.old, .new]) { [weak self] _, change in
                guard change.oldValue != change.newValue else { return }
                self?.enqueueGeometryChange(generation: generation)
            },
            tableView.observe(\.contentOffset, options: [.old, .new]) { [weak self] _, change in
                guard change.oldValue != change.newValue else { return }
                self?.enqueueGeometryChange(generation: generation)
            },
            tableView.observe(\.bounds, options: [.old, .new]) { [weak self] _, change in
                guard change.oldValue?.size != change.newValue?.size else { return }
                self?.enqueueGeometryChange(generation: generation)
            },
        ]
        scheduleUpdate(generation: generation)
    }

    func cancel() {
        generation &+= 1
        request = nil
        scheduledGeneration = nil
        for observation in observations { observation.invalidate() }
        observations.removeAll()
    }

    func layoutDidChange() {
        guard !isRestoring else { return }
        scheduleUpdate(generation: generation)
    }

    private nonisolated func enqueueGeometryChange(generation: UInt) {
        // Like ReaderListFastScroller, never scroll reentrantly from a KVO/layout callback.
        DispatchQueue.main.async { [weak self] in
            self?.scheduleUpdate(generation: generation)
        }
    }

    private func scheduleUpdate(generation: UInt) {
        guard request != nil, self.generation == generation, scheduledGeneration != generation else { return }
        scheduledGeneration = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == generation, self.scheduledGeneration == generation else { return }
            self.scheduledGeneration = nil
            self.restoreIfNeeded(generation: generation)
        }
    }

    private func restoreIfNeeded(generation: UInt) {
        guard !isRestoring, self.generation == generation, let request else { return }
        guard request.isCurrent(), let tableView,
            tableView.window != nil, !tableView.isHidden, tableView.alpha > 0.01,
            !tableView.isTracking, !tableView.isDragging, !tableView.isDecelerating,
            request.indexPath.section < tableView.numberOfSections,
            request.indexPath.row < tableView.numberOfRows(inSection: request.indexPath.section)
        else {
            cancel()
            return
        }
        guard !tableView.hasUncommittedUpdates, tableView.bounds.width > 0, tableView.bounds.height > 0 else { return }
        isRestoring = true
        defer { isRestoring = false }
        tableView.layoutIfNeeded()
        guard self.generation == generation else { return }
        guard request.isCurrent() else {
            cancel()
            return
        }
        let viewport = tableView.bounds.inset(by: tableView.adjustedContentInset)
        guard viewport.width > 0, viewport.height > 0 else { return }
        guard !isVisible(request.indexPath, in: tableView) else { return }

        let previous = geometry(request.indexPath, in: tableView)
        UIView.performWithoutAnimation {
            tableView.scrollToRow(at: request.indexPath, at: .top, animated: false)
            tableView.layoutIfNeeded()
        }
        guard self.generation == generation else { return }
        if !isVisible(request.indexPath, in: tableView), geometry(request.indexPath, in: tableView) != previous {
            enqueueGeometryChange(generation: generation)
        }
        // Do not consume the anchor on first visibility: unresolved earlier estimates can still
        // move this row later. Geometry changes recheck it until user intent or ownership cancels.
    }

    private func isVisible(_ indexPath: IndexPath, in tableView: UITableView) -> Bool {
        guard tableView.indexPathsForVisibleRows?.contains(indexPath) == true,
            let cell = tableView.cellForRow(at: indexPath), cell.window === tableView.window,
            tableView.indexPath(for: cell) == indexPath, !cell.isHidden, cell.alpha > 0.01,
            cell.bounds.height > 0
        else { return false }
        let viewport = tableView.bounds.inset(by: tableView.adjustedContentInset)
        let row = tableView.convert(cell.bounds, from: cell)
        let tolerance = 1 / max(tableView.traitCollection.displayScale, 1)
        if row.height > viewport.height {
            return abs(row.minY - viewport.minY) <= tolerance
        }
        return row.minY >= viewport.minY - tolerance && row.maxY <= viewport.maxY + tolerance
    }

    private func geometry(_ indexPath: IndexPath, in tableView: UITableView) -> Geometry {
        Geometry(
            bounds: tableView.bounds, contentSize: tableView.contentSize,
            insets: tableView.adjustedContentInset, row: tableView.rectForRow(at: indexPath))
    }
}
