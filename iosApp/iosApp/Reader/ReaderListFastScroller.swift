import UIKit

@MainActor
private final class ReaderFastScrollListAdapter {
    private weak var tableView: UITableView?
    private weak var collectionView: UICollectionView?

    init(tableView: UITableView) {
        self.tableView = tableView
    }

    init(collectionView: UICollectionView) {
        self.collectionView = collectionView
    }

    var scrollView: UIScrollView? {
        if let tableView { return tableView }
        return collectionView
    }

    var itemCount: Int {
        if let tableView {
            guard tableView.dataSource != nil, tableView.numberOfSections == 1 else { return 0 }
            return tableView.numberOfRows(inSection: 0)
        }
        guard let collectionView, collectionView.dataSource != nil,
            collectionView.numberOfSections == 1
        else { return 0 }
        return collectionView.numberOfItems(inSection: 0)
    }

    var visibleIndices: [Int] {
        let paths =
            tableView?.indexPathsForVisibleRows
            ?? collectionView?.indexPathsForVisibleItems ?? []
        let count = itemCount
        return paths.filter { $0.section == 0 && (0..<count).contains($0.item) }
            .map { $0.item }.sorted()
    }

    var hasUncommittedUpdates: Bool {
        if let tableView { return tableView.hasUncommittedUpdates }
        return collectionView?.hasUncommittedUpdates ?? false
    }

    var usesEstimatedRowHeights: Bool { tableView != nil }

    func scrollTo(item: Int, alignToBottom: Bool) {
        if let tableView {
            tableView.scrollToRow(
                at: IndexPath(row: item, section: 0),
                at: alignToBottom ? .bottom : .top, animated: false)
        } else if let collectionView {
            collectionView.scrollToItem(
                at: IndexPath(item: item, section: 0),
                at: alignToBottom ? .bottom : .top, animated: false)
        }
    }
}

enum ReaderListFastScrollerGeometry {
    static let columnWidth: CGFloat = 24
    static let handleWidth: CGFloat = 8
    static let handleHeight: CGFloat = 40
    static let trackWidth: CGFloat = 2
    static let snapRange: CGFloat = 5

    static func handleOrigin(at y: CGFloat, height: CGFloat) -> CGFloat {
        guard y.isFinite, height.isFinite else { return 0 }
        return min(max(0, height - handleHeight), max(0, y - handleHeight / 2))
    }

    static func row(at y: CGFloat, height: CGFloat, rowCount: Int) -> Int? {
        guard rowCount > 0, height.isFinite, height > handleHeight, y.isFinite else { return nil }
        let origin = handleOrigin(at: y, height: height)
        // FastScroller.kt snaps at the clamped top and within 5dp of the bottom.
        if origin == 0 { return 0 }
        if origin + handleHeight >= height - snapRange { return rowCount - 1 }
        let rounded = (min(1, max(0, y / height)) * CGFloat(rowCount)).rounded()
        if rounded >= CGFloat(rowCount - 1) { return rowCount - 1 }
        return max(0, Int(rounded))
    }

    static func proportion(
        offsetY: CGFloat, contentHeight: CGFloat, viewportHeight: CGFloat,
        topInset: CGFloat, bottomInset: CGFloat
    ) -> CGFloat {
        let extent = contentHeight + topInset + bottomInset - viewportHeight
        guard extent.isFinite, extent > 0, offsetY.isFinite, topInset.isFinite else { return 0 }
        return min(1, max(0, (offsetY + topInset) / extent))
    }
}

/// Legado 5f5d314 FastScroller, without SectionIndexer or a bubble.
/// The owner supplies a 24pt sibling column, inset 8pt from the list's top and bottom.
@MainActor
final class ReaderListFastScroller: UIControl {
    private enum Visibility {
        case hidden
        case visible
        case hiding
    }

    private static let hideDelay: TimeInterval = 1
    private static let animationDuration: TimeInterval = 0.3
    private static let slideDistance: CGFloat = 8

    var onScrubbingChanged: ((Bool) -> Void)?
    private(set) var isScrubbing = false

    private let list: ReaderFastScrollListAdapter
    private weak var trackingTouch: UITouch?
    private weak var observedPan: UIPanGestureRecognizer?
    private let scrollbar = UIView()
    private let track = UIView()
    private let handle = UIView()
    private var accent = UIColor.clear
    private var observations: [NSKeyValueObservation] = []
    private var observationGeneration: UInt = 0
    private var interactionGeneration: UInt = 0
    private var animationGeneration: UInt = 0
    private var hideGeneration: UInt = 0
    private var hideWork: DispatchWorkItem?
    private var visibility: Visibility = .hidden
    private var canDisplay = false
    private var isSynchronizing = false
    private var isAccessibilityFocused = false
    private var dragY: CGFloat?
    private var lastContentOffset: CGPoint?

    convenience init(tableView: UITableView) {
        self.init(adapter: ReaderFastScrollListAdapter(tableView: tableView))
    }

    convenience init(collectionView: UICollectionView) {
        self.init(adapter: ReaderFastScrollListAdapter(collectionView: collectionView))
    }

    private init(adapter: ReaderFastScrollListAdapter) {
        list = adapter
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear
        isMultipleTouchEnabled = false
        clipsToBounds = false
        accessibilityLabel = L10n.Bookshelf.displayFastScroller
        accessibilityTraits = .adjustable
        isAccessibilityElement = false
        scrollbar.isUserInteractionEnabled = false
        scrollbar.isAccessibilityElement = false
        scrollbar.isHidden = true
        scrollbar.alpha = 0
        track.backgroundColor = UIColor(white: 0, alpha: 48.0 / 255.0)
        for view in [track, handle] {
            view.isUserInteractionEnabled = false
            view.isAccessibilityElement = false
            view.layer.cornerRadius = 0
            scrollbar.addSubview(view)
        }
        addSubview(scrollbar)
        NotificationCenter.default.addObserver(
            self, selector: #selector(reduceMotionChanged),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationWillResignActive),
            name: UIApplication.willResignActiveNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit {
        hideWork?.cancel()
        for observation in observations { observation.invalidate() }
        NotificationCenter.default.removeObserver(self)
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: ReaderListFastScrollerGeometry.columnWidth, height: UIView.noIntrinsicMetric)
    }

    override var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled { synchronize() } else { suspendInteraction() }
        }
    }

    override var isHidden: Bool {
        didSet {
            guard isHidden != oldValue else { return }
            if isHidden { suspendInteraction() } else { synchronize() }
        }
    }

    override var isUserInteractionEnabled: Bool {
        didSet {
            guard isUserInteractionEnabled != oldValue else { return }
            if isUserInteractionEnabled { synchronize() } else { suspendInteraction() }
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            stopObserving()
            suspendInteraction()
        } else {
            reload()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        synchronize()
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard isEnabled, !isHidden, isUserInteractionEnabled, alpha > 0.01,
            window != nil, let scrollView = list.scrollView, scrollView.window === window,
            !scrollView.isHidden, list.itemCount > 0,
            isScrollable(scrollView), canDisplay, !scrollbar.isHidden
        else { return false }
        let opacity = scrollbar.layer.presentation()?.opacity ?? Float(scrollbar.alpha)
        return opacity > 0.01 && bounds.contains(point)
    }

    func apply(accent: UIColor) {
        self.accent = accent
        updateHandleColor()
    }

    /// Call after reloadData(), including filtered or reordered results.
    func reload() {
        interactionGeneration &+= 1
        stopObserving()
        let generation = observationGeneration
        hideImmediately()
        finishScrubbing()
        // The stop callback can synchronously reload or detach the list.
        guard generation == observationGeneration else { return }
        list.scrollView?.layoutIfNeeded()
        guard generation == observationGeneration else { return }
        lastContentOffset = list.scrollView?.contentOffset
        setNeedsLayout()
        layoutIfNeeded()
        guard generation == observationGeneration else { return }
        synchronize()
        startObserving()
    }

    func cancelScrubbing() {
        interactionGeneration &+= 1
        let generation = interactionGeneration
        finishScrubbing()
        guard generation == interactionGeneration else { return }
        synchronize()
        scheduleHide()
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        synchronize()
        guard point(inside: touch.location(in: self), with: event),
            let scrollView = list.scrollView, !list.hasUncommittedUpdates
        else { return false }
        interactionGeneration &+= 1
        let generation = interactionGeneration
        trackingTouch = touch
        dragY = touch.location(in: self).y - bounds.minY
        isScrubbing = true
        showScrollbar()
        updateHandleColor()
        onScrubbingChanged?(true)
        guard generation == interactionGeneration, isScrubbing else { return false }
        scrollView.setContentOffset(scrollView.contentOffset, animated: false)
        guard generation == interactionGeneration, isScrubbing else { return false }
        scrub(at: touch.location(in: self).y - bounds.minY)
        return isScrubbing
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard isScrubbing else { return false }
        scrub(at: touch.location(in: self).y - bounds.minY)
        return isScrubbing
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        cancelScrubbing()
        super.endTracking(touch, with: event)
    }

    override func cancelTracking(with event: UIEvent?) {
        cancelScrubbing()
        super.cancelTracking(with: event)
    }

    override func accessibilityIncrement() { adjustAccessibility(direction: 1) }

    override func accessibilityDecrement() { adjustAccessibility(direction: -1) }

    override func accessibilityElementDidBecomeFocused() {
        super.accessibilityElementDidBecomeFocused()
        isAccessibilityFocused = true
        synchronize()
        if canDisplay { showScrollbar() }
    }

    override func accessibilityElementDidLoseFocus() {
        super.accessibilityElementDidLoseFocus()
        isAccessibilityFocused = false
        scheduleHide()
    }

    private func isScrollable(_ scrollView: UIScrollView) -> Bool {
        let count = list.itemCount
        let insets = scrollView.adjustedContentInset
        let viewport = scrollView.bounds.height - insets.top - insets.bottom
        guard count > 0, viewport.isFinite, viewport > 0,
            scrollView.contentSize.height.isFinite
        else { return false }
        // Unmeasured self-sizing rows must not make an underestimated table look like it fits.
        if list.usesEstimatedRowHeights {
            let visible = list.visibleIndices
            if !visible.isEmpty, !visible.contains(0) || !visible.contains(count - 1) {
                return true
            }
        }
        return scrollView.contentSize.height - viewport > 0.5
    }

    private func proportion(in scrollView: UIScrollView) -> CGFloat {
        ReaderListFastScrollerGeometry.proportion(
            offsetY: scrollView.contentOffset.y, contentHeight: scrollView.contentSize.height,
            viewportHeight: scrollView.bounds.height, topInset: scrollView.adjustedContentInset.top,
            bottomInset: scrollView.adjustedContentInset.bottom)
    }

    private func synchronize(scrollActivity: Bool = false) {
        guard !isSynchronizing else { return }
        isSynchronizing = true
        defer { isSynchronizing = false }
        let moved = lastContentOffset != list.scrollView?.contentOffset
        if scrollActivity { lastContentOffset = list.scrollView?.contentOffset }
        canDisplay =
            isEnabled && !isHidden && isUserInteractionEnabled && alpha > 0.01
            && window != nil && bounds.width.isFinite && bounds.width > 0
            && bounds.height.isFinite && bounds.height > ReaderListFastScrollerGeometry.handleHeight
        if let scrollView = list.scrollView {
            canDisplay =
                canDisplay && scrollView.window === window && !scrollView.isHidden
                && scrollView.alpha > 0.01 && isScrollable(scrollView)
        } else {
            canDisplay = false
        }

        let height = bounds.height.isFinite ? max(0, bounds.height) : 0
        let width = bounds.width.isFinite ? max(0, bounds.width) : 0
        var y = (list.scrollView.map { proportion(in: $0) } ?? 0) * height
        if isScrubbing {
            let touchY = trackingTouch.map { $0.location(in: self).y - bounds.minY }
            y = min(height, max(0, touchY ?? dragY ?? y))
            dragY = y
        }
        UIView.performWithoutAnimation {
            scrollbar.bounds = CGRect(x: 0, y: 0, width: width, height: height)
            scrollbar.center = CGPoint(x: bounds.midX, y: bounds.midY)
            track.frame = CGRect(
                x: (width - ReaderListFastScrollerGeometry.trackWidth) / 2, y: 0,
                width: ReaderListFastScrollerGeometry.trackWidth, height: height)
            handle.frame = CGRect(
                x: (width - ReaderListFastScrollerGeometry.handleWidth) / 2,
                y: ReaderListFastScrollerGeometry.handleOrigin(at: y, height: height),
                width: ReaderListFastScrollerGeometry.handleWidth,
                height: ReaderListFastScrollerGeometry.handleHeight)
        }

        // Size/estimate KVO never terminates an active touch; reload() owns data invalidation.
        guard canDisplay else {
            hideImmediately()
            return
        }
        if isScrubbing {
            showScrollbar()
        } else if scrollActivity && moved {
            showScrollbar()
            scheduleHide()
        }
        updateAccessibility()
    }

    private func scrub(at y: CGFloat) {
        guard isScrubbing, y.isFinite else { return }
        dragY = min(max(0, bounds.height), max(0, y))
        synchronize()
        guard canDisplay,
            let item = ReaderListFastScrollerGeometry.row(
                at: y, height: bounds.height, rowCount: list.itemCount)
        else { return }
        scroll(to: item, expectedCount: list.itemCount, generation: interactionGeneration)
        synchronize()
    }

    private func scroll(to item: Int, expectedCount: Int, generation: UInt) {
        guard expectedCount > 0, (0..<expectedCount).contains(item) else { return }
        // The first jump can replace estimates. Align the real item again after layout.
        for _ in 0..<2 {
            guard generation == interactionGeneration, canDisplay, isEnabled, !isHidden,
                let scrollView = list.scrollView, scrollView.window === window, window != nil,
                !list.hasUncommittedUpdates, list.itemCount == expectedCount
            else { return }
            list.scrollTo(item: item, alignToBottom: item == expectedCount - 1)
            guard generation == interactionGeneration,
                list.itemCount == expectedCount
            else { return }
            scrollView.layoutIfNeeded()
        }
    }

    private func finishScrubbing() {
        guard isScrubbing else { return }
        isScrubbing = false
        trackingTouch = nil
        dragY = nil
        updateHandleColor()
        onScrubbingChanged?(false)
    }

    private func suspendInteraction() {
        interactionGeneration &+= 1
        canDisplay = false
        hideImmediately()
        finishScrubbing()
    }

    private func updateHandleColor() {
        let resolved = accent.resolvedColor(with: traitCollection)
        handle.backgroundColor =
            isScrubbing
            ? resolved.withAlphaComponent(resolved.cgColor.alpha * 0.8) : accent
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateHandleColor()
    }

    private func startObserving() {
        guard observations.isEmpty, window != nil, let scrollView = list.scrollView else { return }
        observationGeneration &+= 1
        let generation = observationGeneration
        observations = [
            scrollView.observe(\.contentOffset, options: [.old, .new]) { [weak self] _, change in
                guard change.oldValue != change.newValue else { return }
                self?.enqueueListChange(scrollActivity: true, generation: generation)
            },
            scrollView.observe(\.contentSize, options: [.old, .new]) { [weak self] _, change in
                guard change.oldValue != change.newValue else { return }
                self?.enqueueListChange(scrollActivity: false, generation: generation)
            },
            scrollView.observe(\.bounds, options: [.old, .new]) { [weak self] _, change in
                guard change.oldValue?.size != change.newValue?.size else { return }
                self?.enqueueListChange(scrollActivity: false, generation: generation)
            },
        ]
        observedPan = scrollView.panGestureRecognizer
        observedPan?.addTarget(self, action: #selector(nativePanChanged(_:)))
    }

    private func stopObserving() {
        observationGeneration &+= 1
        for observation in observations { observation.invalidate() }
        observations.removeAll()
        observedPan?.removeTarget(self, action: #selector(nativePanChanged(_:)))
        observedPan = nil
    }

    private nonisolated func enqueueListChange(scrollActivity: Bool, generation: UInt) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.observationGeneration == generation else { return }
            self.synchronize(scrollActivity: scrollActivity)
        }
    }

    @objc private func nativePanChanged(_ recognizer: UIPanGestureRecognizer) {
        guard !isScrubbing else { return }
        synchronize()
        guard canDisplay else { return }
        switch recognizer.state {
        case .began, .changed:
            showScrollbar()
        case .ended, .cancelled, .failed:
            scheduleHide()
        default:
            break
        }
    }

    private func cancelHide() {
        hideGeneration &+= 1
        hideWork?.cancel()
        hideWork = nil
    }

    private func scheduleHide() {
        cancelHide()
        guard canDisplay, !isScrubbing, !isAccessibilityFocused, visibility == .visible else { return }
        let generation = hideGeneration
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.hideGeneration == generation else { return }
                self.hideWork = nil
                self.synchronize()
                guard self.canDisplay, !self.isScrubbing, !self.isAccessibilityFocused else { return }
                if let scrollView = self.list.scrollView,
                    scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating
                {
                    self.scheduleHide()
                } else {
                    self.hideScrollbar()
                }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hideDelay, execute: work)
    }

    private func showScrollbar() {
        guard canDisplay else { return }
        cancelHide()
        guard visibility != .visible else { return }
        animationGeneration &+= 1
        let wasHidden = visibility == .hidden
        let opacity = scrollbar.layer.presentation()?.opacity
        let transform = scrollbar.layer.presentation()?.affineTransform()
        scrollbar.layer.removeAllAnimations()
        scrollbar.alpha = wasHidden ? 0 : CGFloat(opacity ?? Float(scrollbar.alpha))
        scrollbar.transform =
            UIAccessibility.isReduceMotionEnabled
            ? .identity
            : (wasHidden
                ? CGAffineTransform(translationX: Self.slideDistance, y: 0)
                : transform ?? scrollbar.transform)
        scrollbar.isHidden = false
        visibility = .visible
        updateAccessibility()
        UIView.animate(
            withDuration: Self.animationDuration, delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut],
            animations: { [weak self] in
                self?.scrollbar.alpha = 1
                self?.scrollbar.transform = .identity
            })
    }

    private func hideScrollbar() {
        guard !isScrubbing, visibility == .visible else { return }
        animationGeneration &+= 1
        let generation = animationGeneration
        visibility = .hiding
        UIView.animate(
            withDuration: Self.animationDuration, delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut],
            animations: { [weak self] in
                self?.scrollbar.alpha = 0
                self?.scrollbar.transform =
                    UIAccessibility.isReduceMotionEnabled
                    ? .identity
                    : CGAffineTransform(translationX: Self.slideDistance, y: 0)
            },
            completion: { [weak self] _ in
                guard let self, self.animationGeneration == generation else { return }
                self.hideImmediately()
            })
    }

    private func hideImmediately() {
        cancelHide()
        animationGeneration &+= 1
        scrollbar.layer.removeAllAnimations()
        scrollbar.isHidden = true
        scrollbar.alpha = 0
        scrollbar.transform = .identity
        visibility = .hidden
        isAccessibilityElement = false
        accessibilityValue = nil
        isAccessibilityFocused = false
    }

    private func updateAccessibility() {
        isAccessibilityElement = canDisplay && visibility != .hidden
        guard isAccessibilityElement, let scrollView = list.scrollView else {
            accessibilityValue = nil
            return
        }
        accessibilityValue = NumberFormatter.localizedString(
            from: NSNumber(value: Double(proportion(in: scrollView))), number: .percent)
    }

    private func adjustAccessibility(direction: Int) {
        synchronize()
        guard canDisplay, visibility != .hidden, !isScrubbing else { return }
        let count = list.itemCount
        let visible = list.visibleIndices
        guard let first = visible.first else { return }
        let step = max(1, visible.count - 1)
        let target = min(count - 1, max(0, first + direction * step))
        showScrollbar()
        scroll(to: target, expectedCount: count, generation: interactionGeneration)
        synchronize()
        scheduleHide()
    }

    @objc private func reduceMotionChanged() {
        if visibility == .hiding {
            hideImmediately()
        } else if visibility == .visible {
            animationGeneration &+= 1
            scrollbar.layer.removeAllAnimations()
            scrollbar.alpha = 1
            scrollbar.transform = .identity
        }
    }

    @objc private func applicationWillResignActive() {
        cancelScrubbing()
        hideImmediately()
    }
}
