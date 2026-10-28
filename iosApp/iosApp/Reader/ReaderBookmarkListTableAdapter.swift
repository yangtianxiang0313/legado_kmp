import UIKit
import UIKit.UIGestureRecognizerSubclass
import shared

@MainActor
enum ReaderBookmarkListLayout {
    static func install(
        in view: UIView, tableView: UITableView, emptyView: UIView,
        header: (bar: UIView, search: UIView, summary: UIView)?
    ) {
        let visibleItems: [UIView] =
            header.map { [$0.bar, $0.search, $0.summary, tableView, emptyView] } ?? [tableView, emptyView]
        for item in visibleItems {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        var constraints: [NSLayoutConstraint] = [
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyView.centerXAnchor.constraint(equalTo: tableView.centerXAnchor),
            emptyView.centerYAnchor.constraint(equalTo: tableView.centerYAnchor, constant: -24),
            emptyView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 28),
            emptyView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -28),
        ]
        if let header {
            constraints.append(contentsOf: [
                header.bar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                header.bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                header.bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                header.search.topAnchor.constraint(equalTo: header.bar.bottomAnchor, constant: 10),
                header.search.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
                header.search.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
                header.search.heightAnchor.constraint(equalToConstant: 36),
                header.summary.topAnchor.constraint(equalTo: header.search.bottomAnchor, constant: 8),
                header.summary.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
                header.summary.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
                tableView.topAnchor.constraint(equalTo: header.summary.bottomAnchor, constant: 8),
                tableView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            ])
        } else {
            constraints.append(contentsOf: [
                tableView.topAnchor.constraint(equalTo: view.topAnchor),
                tableView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            ])
        }
        NSLayoutConstraint.activate(constraints)
    }
}

@MainActor
final class ReaderBookmarkListTableAdapter: NSObject, UITableViewDataSource, UITableViewDelegate {
    enum LegacyAction {
        case more, delete, edit, detail
    }

    private weak var tableView: UITableView?
    private let bookmarkCount: () -> Int
    private let bookmarkAtRow: (Int) -> Bookmark?
    private let isEmbedded: () -> Bool
    private let canPerformEmbeddedActions: () -> Bool
    private let palette: () -> ReaderTocPalette
    private let onSelect: (Bookmark) -> Void
    private let onLegacyAction: (LegacyAction, Bookmark) -> Void
    private let onStaleBookmark: () -> Void
    private let onScrollInteractionChanged: (Bool) -> Void
    private var snapshotGeneration = UUID()

    init(
        bookmarkCount: @escaping () -> Int,
        bookmarkAtRow: @escaping (Int) -> Bookmark?,
        isEmbedded: @escaping () -> Bool,
        canPerformEmbeddedActions: @escaping () -> Bool,
        palette: @escaping () -> ReaderTocPalette,
        onSelect: @escaping (Bookmark) -> Void,
        onLegacyAction: @escaping (LegacyAction, Bookmark) -> Void,
        onStaleBookmark: @escaping () -> Void,
        onScrollInteractionChanged: @escaping (Bool) -> Void
    ) {
        self.bookmarkCount = bookmarkCount
        self.bookmarkAtRow = bookmarkAtRow
        self.isEmbedded = isEmbedded
        self.canPerformEmbeddedActions = canPerformEmbeddedActions
        self.palette = palette
        self.onSelect = onSelect
        self.onLegacyAction = onLegacyAction
        self.onStaleBookmark = onStaleBookmark
        self.onScrollInteractionChanged = onScrollInteractionChanged
        super.init()
    }

    func install(on tableView: UITableView) {
        self.tableView = tableView
        tableView.dataSource = self
        tableView.delegate = self
        // Both Android bookmark adapters inflate the same item_bookmark.xml.
        tableView.register(
            ReaderTocBookmarkCell.self, forCellReuseIdentifier: ReaderTocBookmarkCell.reuseIdentifier)
        tableView.addGestureRecognizer(
            UILongPressGestureRecognizer(target: self, action: #selector(handleBookmarkLongPress(_:))))
        tableView.addGestureRecognizer(
            ReaderBookmarkTouchEndObserver { [weak self] in self?.onScrollInteractionChanged(false) })
    }

    func reloadData() {
        snapshotGeneration = UUID()
        tableView?.reloadData()
    }

    func refreshPalette() {
        guard let tableView else { return }
        let colors = palette()
        for case let cell as ReaderTocBookmarkCell in tableView.visibleCells {
            guard let indexPath = tableView.indexPath(for: cell), let bookmark = bookmarkAtRow(indexPath.row) else {
                continue
            }
            cell.configure(with: bookmark, palette: colors)
        }
    }

    func preservingScrollAnchor(_ updates: () -> Void) {
        guard isEmbedded(), let tableView else {
            updates()
            return
        }
        let previousOffset = tableView.contentOffset
        let anchor = tableView.indexPathsForVisibleRows?.min()
        let bookmarkTime = anchor.flatMap { bookmarkAtRow($0.row)?.time }
        let topOffset = anchor.map { tableView.rectForRow(at: $0).minY - previousOffset.y } ?? 0
        updates()
        tableView.layoutIfNeeded()
        var offset = previousOffset
        if let anchor, bookmarkCount() > 0 {
            let row =
                (0..<bookmarkCount()).first { bookmarkAtRow($0)?.time == bookmarkTime }
                ?? min(anchor.row, bookmarkCount() - 1)
            offset.y = tableView.rectForRow(at: IndexPath(row: row, section: 0)).minY - topOffset
        }
        let minimumY = -tableView.adjustedContentInset.top
        let maximumY = max(
            minimumY, tableView.contentSize.height + tableView.adjustedContentInset.bottom - tableView.bounds.height)
        offset.y = min(maximumY, max(minimumY, offset.y))
        tableView.setContentOffset(offset, animated: false)
    }

    func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
        bookmarkCount()
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let bookmark = bookmarkAtRow(indexPath.row) else {
            onStaleBookmark()
            return UITableViewCell()
        }
        let cell =
            tableView.dequeueReusableCell(withIdentifier: ReaderTocBookmarkCell.reuseIdentifier, for: indexPath)
            as! ReaderTocBookmarkCell
        cell.configure(with: bookmark, palette: palette())
        cell.accessibilityIdentifier = UIIdentifiers.ReaderBookmarkList.cell
        let generation = snapshotGeneration
        cell.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: L10n.Common.edit) { [weak self, weak cell] action in
                guard let self, let cell, let tableView = self.tableView,
                    self.snapshotGeneration == generation,
                    !self.isEmbedded() || self.canPerformEmbeddedActions(),
                    cell.accessibilityCustomActions?.contains(where: { $0 === action }) == true,
                    cell.window != nil, cell.window === tableView.window,
                    cell.window?.windowScene?.activationState == .foregroundActive,
                    tableView.visibleCells.contains(where: { $0 === cell }),
                    let currentPath = tableView.indexPath(for: cell),
                    let current = self.bookmarkAtRow(currentPath.row), current.time == bookmark.time
                else { return false }
                self.onLegacyAction(.more, current)
                return true
            }
        ]
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let bookmark = bookmarkAtRow(indexPath.row) else {
            onStaleBookmark()
            return
        }
        onSelect(bookmark)
    }

    func tableView(_: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
        -> UISwipeActionsConfiguration?
    {
        guard !isEmbedded(), let bookmark = bookmarkAtRow(indexPath.row) else { return nil }
        let jump = UIContextualAction(style: .normal, title: L10n.Reader.chapterJumpAction) {
            [weak self] _, _, completion in
            self?.onSelect(bookmark)
            completion(true)
        }
        jump.backgroundColor = AndroidReplicaTheme.accent
        jump.image = UIImage(systemName: "arrow.right.circle")
        return UISwipeActionsConfiguration(actions: [jump])
    }

    func tableView(_: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
        -> UISwipeActionsConfiguration?
    {
        guard !isEmbedded(), let bookmark = bookmarkAtRow(indexPath.row) else { return nil }
        let delete = UIContextualAction(style: .destructive, title: L10n.Common.delete) {
            [weak self] _, _, completion in
            self?.onLegacyAction(.delete, bookmark)
            completion(true)
        }
        delete.image = UIImage(systemName: "trash")
        let edit = UIContextualAction(style: .normal, title: L10n.Common.edit) { [weak self] _, _, completion in
            self?.onLegacyAction(.edit, bookmark)
            completion(true)
        }
        edit.backgroundColor = AndroidReplicaTheme.secondaryText
        edit.image = UIImage(systemName: "square.and.pencil")
        let detail = UIContextualAction(style: .normal, title: L10n.Reader.bookmarkViewDetail) {
            [weak self] _, _, completion in
            self?.onLegacyAction(.detail, bookmark)
            completion(true)
        }
        detail.backgroundColor = .systemBlue
        detail.image = UIImage(systemName: "eye")
        return UISwipeActionsConfiguration(actions: [delete, edit, detail])
    }

    @objc private func handleBookmarkLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let tableView, tableView.allowsSelection else { return }
        guard !isEmbedded() || canPerformEmbeddedActions() else { return }
        let location = gesture.location(in: tableView)
        guard let indexPath = tableView.indexPathForRow(at: location), let bookmark = bookmarkAtRow(indexPath.row)
        else {
            if !isEmbedded() { onStaleBookmark() }
            return
        }
        tableView.selectRow(at: indexPath, animated: true, scrollPosition: .none)
        if isEmbedded() { tableView.deselectRow(at: indexPath, animated: false) }
        onLegacyAction(.more, bookmark)
    }

    func scrollViewWillBeginDragging(_: UIScrollView) {
        onScrollInteractionChanged(true)
    }

    func scrollViewDidEndDragging(_: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { onScrollInteractionChanged(false) }
    }

    func scrollViewDidEndDecelerating(_: UIScrollView) {
        onScrollInteractionChanged(false)
    }

    func scrollViewDidEndScrollingAnimation(_: UIScrollView) {
        onScrollInteractionChanged(false)
    }
}

// A touch can end without ever dragging; UIScrollView then sends no drag-end callback.
@MainActor
private final class ReaderBookmarkTouchEndObserver: UIGestureRecognizer {
    private let onEnd: () -> Void

    init(onEnd: @escaping () -> Void) {
        self.onEnd = onEnd
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func canPrevent(_: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by _: UIGestureRecognizer) -> Bool { false }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        finish()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        finish()
    }

    private func finish() {
        if state == .possible { state = .failed }
        DispatchQueue.main.async { [weak self] in self?.onEnd() }
    }
}
