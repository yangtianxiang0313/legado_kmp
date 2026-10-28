import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Coalesces bookshelf payloads without replacing the row underneath a held touch.
@MainActor
final class BookshelfBookPagePresentationCoordinator {
    var canDeliver: (() -> Bool)?
    var canAwaitPresentation: (() -> Bool)?
    var onDeliver: (() -> Void)?
    var onCancelSelection: (() -> Void)?

    private weak var collectionView: UICollectionView?
    private let contact = BookshelfBookPageContactObserver()
    private var pending = false
    private var scheduled: DispatchWorkItem?
    private(set) var suppressesSelection = false

    init(collectionView: UICollectionView) {
        self.collectionView = collectionView
        contact.onBegin = { [weak self] in self?.suppressesSelection = false }
        contact.onMove = { [weak self] in self?.cancelSelection() }
        contact.onEnd = { [weak self] in
            self?.resumeDelivery()
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.contact.hasContact else { return }
                self.suppressesSelection = false
            }
        }
        collectionView.addGestureRecognizer(contact)
    }

    deinit { scheduled?.cancel() }

    var isBusy: Bool {
        guard let collectionView else { return true }
        let pan = collectionView.panGestureRecognizer.state
        return contact.hasContact || collectionView.isTracking || collectionView.isDragging
            || collectionView.isDecelerating || pan == .began || pan == .changed
            || collectionView.visibleCells.contains(where: { $0.isHighlighted })
    }

    func requestDelivery() {
        pending = true
        resumeDelivery()
    }

    func resumeDelivery() { schedule(after: 0) }

    func cancelSelection() {
        suppressesSelection = contact.hasContact || collectionView?.isDragging == true || collectionView?.isDecelerating == true
        onCancelSelection?()
    }

    func suspend() {
        scheduled?.cancel()
        scheduled = nil
        cancelSelection()
        contact.cancelContact()
        for cell in collectionView?.visibleCells ?? [] { cell.isHighlighted = false }
    }

    private func schedule(after delay: TimeInterval) {
        guard pending, scheduled == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.scheduled = nil
            guard !self.isBusy else { return }
            guard self.canDeliver?() == true else {
                // Over-full-screen dialogs do not reliably resend the presenter's appearance callbacks.
                // Only await a visible active page with pending data; hidden/background pages never poll.
                if self.canAwaitPresentation?() == true { self.schedule(after: 0.25) }
                return
            }
            self.pending = false
            self.onDeliver?()
        }
        scheduled = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
}

/// A passive recognizer observes contact even when UIScrollView delays delivery to a cell.
@MainActor
private final class BookshelfBookPageContactObserver: UIGestureRecognizer {
    var onBegin: (() -> Void)?
    var onMove: (() -> Void)?
    var onEnd: (() -> Void)?
    private(set) var hasContact = false
    private var touch: UITouch?
    private var origin = CGPoint.zero

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        requiresExclusiveTouchType = false
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touch == nil, touches.count == 1, let first = touches.first else {
            onMove?()
            return
        }
        touch = first
        origin = first.location(in: view)
        hasContact = true
        onBegin?()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch, touches.contains(touch) else { return }
        let point = touch.location(in: view)
        if hypot(point.x - origin.x, point.y - origin.y) > 8 { onMove?() }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch, touches.contains(touch) else { return }
        finish()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        onMove?()
        finish()
    }

    override func reset() {
        super.reset()
        touch = nil
        hasContact = false
    }

    func cancelContact() {
        guard hasContact else { return }
        onMove?()
        finish()
    }

    private func finish() {
        touch = nil
        hasContact = false
        state = .failed
        onEnd?()
    }
}
