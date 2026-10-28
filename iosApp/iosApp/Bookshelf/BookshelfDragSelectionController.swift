import UIKit

struct BookshelfSelectionDragSession {
    let orderedURLs: [String]
    let initialSelection: Set<String>
    let start: Int
    private var visited: Set<String> = []

    init(orderedURLs: [String], initialSelection: Set<String>, start: Int) {
        self.orderedURLs = orderedURLs
        self.initialSelection = initialSelection
        self.start = start
    }

    mutating func selection(through end: Int) -> Set<String> {
        guard orderedURLs.indices.contains(start), orderedURLs.indices.contains(end) else { return initialSelection }
        // Android ToggleAndReverse uses the first row's state for both entering and leaving rows.
        let range = Set(orderedURLs[min(start, end)...max(start, end)])
        visited.formUnion(range)
        var result = initialSelection
        if initialSelection.contains(orderedURLs[start]) {
            result.formUnion(visited)
            result.subtract(range)
        } else {
            result.subtract(visited)
            result.formUnion(range)
        }
        return result
    }
}

@MainActor
final class BookshelfDragSelectionController: NSObject, UIGestureRecognizerDelegate {
    var canBegin: (() -> Bool)?
    var orderedURLs: (() -> [String])?
    var initialSelection: (() -> Set<String>)?
    var onSelection: ((Set<String>) -> Void)?
    var onActiveChanged: ((Bool) -> Void)?
    private weak var table: UITableView?
    private var session: BookshelfSelectionDragSession?
    private var displayLink: CADisplayLink?
    private var proxy: DisplayProxy?
    private var lastTimestamp: CFTimeInterval?
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(changed(_:)))
    private(set) var isSelecting = false

    init(table: UITableView) {
        self.table = table
        super.init()
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        table.addGestureRecognizer(pan)
        table.panGestureRecognizer.require(toFail: pan)
    }

    deinit { displayLink?.invalidate() }

    func cancel() {
        let wasSelecting = isSelecting
        isSelecting = false
        session = nil
        displayLink?.invalidate()
        displayLink = nil
        proxy = nil
        lastTimestamp = nil
        if wasSelecting { onActiveChanged?(false) }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pan, canBegin?() == true, let table else { return false }
        let point = pan.location(in: table)
        let translation = pan.translation(in: table)
        let origin = CGPoint(x: point.x - translation.x, y: point.y - translation.y)
        guard let path = table.indexPathForRow(at: origin), let cell = table.cellForRow(at: path) as? BookshelfManageCell else { return false }
        let checkbox = cell.checkButton.convert(cell.checkButton.bounds, to: table).insetBy(dx: -10, dy: 0)
        return origin.x >= checkbox.minX && origin.x <= checkbox.maxX
    }

    @objc private func changed(_ recognizer: UIPanGestureRecognizer) {
        guard let table else {
            cancel()
            return
        }
        switch recognizer.state {
        case .began:
            let point = recognizer.location(in: table)
            let translation = recognizer.translation(in: table)
            let origin = CGPoint(x: point.x - translation.x, y: point.y - translation.y)
            guard let path = table.indexPathForRow(at: origin), let urls = orderedURLs?(), urls.indices.contains(path.row) else {
                cancel()
                return
            }
            session = .init(orderedURLs: urls, initialSelection: initialSelection?() ?? [], start: path.row)
            isSelecting = true
            onActiveChanged?(true)
            updateSelection()
            let proxy = DisplayProxy(owner: self)
            self.proxy = proxy
            displayLink = CADisplayLink(target: proxy, selector: #selector(DisplayProxy.tick(_:)))
            displayLink?.add(to: .main, forMode: .common)
        case .changed: updateSelection()
        case .ended:
            updateSelection()
            cancel()
        case .cancelled, .failed: cancel()
        default: break
        }
    }

    private func updateSelection() {
        guard let table, var session, !session.orderedURLs.isEmpty else { return }
        let point = pan.location(in: table)
        let index =
            table.indexPathForRow(at: point)?.row
            ?? (point.y < (table.rectForRow(at: IndexPath(row: 0, section: 0)).minY) ? 0 : session.orderedURLs.count - 1)
        let selection = session.selection(through: min(max(0, index), session.orderedURLs.count - 1))
        self.session = session
        onSelection?(selection)
    }

    private func tick(_ link: CADisplayLink) {
        guard isSelecting, let table, table.window != nil else {
            cancel()
            return
        }
        let dt = min(0.05, max(0, link.timestamp - (lastTimestamp ?? link.timestamp)))
        lastTimestamp = link.timestamp
        let point = pan.location(in: table)
        let top = table.bounds.minY + table.adjustedContentInset.top
        let bottom = table.bounds.maxY - table.adjustedContentInset.bottom
        let zone: CGFloat = min(50, max(1, (bottom - top) / 2))
        let speed: CGFloat
        if point.y < top + zone {
            speed = -min(1, max(0, (top + zone - point.y) / zone))
        } else if point.y > bottom - zone {
            speed = min(1, max(0, (point.y - bottom + zone) / zone))
        } else {
            speed = 0
        }
        guard speed != 0 else { return }
        let minimum = -table.adjustedContentInset.top
        let maximum = max(minimum, table.contentSize.height - table.bounds.height + table.adjustedContentInset.bottom)
        let y = min(maximum, max(minimum, table.contentOffset.y + speed * 600 * dt))
        if y != table.contentOffset.y {
            table.setContentOffset(CGPoint(x: table.contentOffset.x, y: y), animated: false)
            updateSelection()
        }
    }

    @MainActor private final class DisplayProxy: NSObject {
        weak var owner: BookshelfDragSelectionController?
        init(owner: BookshelfDragSelectionController) { self.owner = owner }
        @objc func tick(_ link: CADisplayLink) { owner?.tick(link) }
    }
}
