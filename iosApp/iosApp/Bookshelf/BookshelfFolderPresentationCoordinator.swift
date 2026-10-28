import UIKit
import shared

/// Coalesces folder snapshots and owns input lifetimes, independently of layout and scroll anchors.
@MainActor
final class BookshelfFolderPresentationCoordinator: NSObject {
    enum Identity: Equatable {
        case group(Int64)
        case book(String)
    }

    enum Item {
        case group(BookGroup)
        case book(Book)

        var identity: Identity {
            switch self {
            case .group(let group): return .group(group.groupId)
            case .book(let book): return .book(book.bookUrl)
            }
        }

        var origin: String? {
            if case .book(let book) = self { return book.origin }
            return nil
        }
    }

    enum Status: Equatable {
        case idle, loading, loaded
        case failure(String)
    }

    struct Context: Equatable {
        var groupID: Int64?
        var generation = UUID()
    }

    struct Snapshot {
        var context = Context()
        var items: [Item] = []
        var status: Status = .idle
        var layoutMode: BookshelfLayoutMode = .grid3
        var preferences: AppUiPreferences?
        var canRefresh = true
        var isRefreshing = false
        var refreshingBookURLs: Set<String> = []
    }

    struct Binding: Equatable {
        let context: Context
        let path: IndexPath
        let identity: Identity
        let origin: String?
        let cell: ObjectIdentifier
        let token = UUID()
    }

    var currentGroupID: (() -> Int64?)?
    var isCovered: (() -> Bool)?
    var onGroupChange: (() -> Void)?
    var onDeliver: ((Snapshot, Bool, Bool) -> Void)?
    var onLongPress: ((Item) -> Void)?

    private(set) var presented = Snapshot()
    private var requested = Snapshot()
    private weak var owner: UIViewController?
    private weak var collectionView: UICollectionView?
    private var observer: BookshelfFolderTouchObserver?
    private var longPress: UILongPressGestureRecognizer?
    private var timer: Timer?
    private var isVisible = false
    private var isTransitioning = false
    private var applicationSuspended = false
    private var sceneSuspended = false
    private var environmentAvailable = false
    private var needsEnvironmentRecovery = false
    private var needsDelivery = false
    private var needsLayout = false
    private var needsScrollToTop = false
    private var isDelivering = false
    private var isCancellingInput = false
    private var scheduled = false
    private var bindings: [ObjectIdentifier: Binding] = [:]
    private var intent: Binding?
    private var selection: Binding?
    private var hasTouches = false
    private var isFinishingTouch = false
    private var cancelledIntent = false
    private var consumedIntent = false
    private var touchGeneration = UUID()

    init(owner: UIViewController, collectionView: UICollectionView) {
        self.owner = owner
        self.collectionView = collectionView
        super.init()
        let observer = BookshelfFolderTouchObserver()
        observer.onBegin = { [weak self] point in self?.beginTouch(at: point) }
        observer.onMove = { [weak self] in self?.cancelledIntent = true }
        observer.onEnd = { [weak self] cancelled in self?.endTouch(cancelled: cancelled) }
        collectionView.addGestureRecognizer(observer)
        self.observer = observer
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
        collectionView.addGestureRecognizer(longPress)
        self.longPress = longPress
        collectionView.panGestureRecognizer.addTarget(self, action: #selector(panChanged(_:)))
        for name in [
            UIApplication.willResignActiveNotification, UIApplication.didBecomeActiveNotification,
            UIScene.willDeactivateNotification, UIScene.didActivateNotification,
            UIWindow.didResignKeyNotification, UIWindow.didBecomeKeyNotification,
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(activationChanged(_:)), name: name, object: nil)
        }
    }

    deinit {
        timer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    var requestedGroupID: Int64? { requested.context.groupID }

    func configure(layoutMode: BookshelfLayoutMode, preferences: AppUiPreferences?, canRefresh: Bool) {
        needsLayout = needsLayout || requested.layoutMode != layoutMode
        requested.layoutMode = layoutMode
        requested.preferences = preferences
        requested.canRefresh = canRefresh
        stageDelivery()
    }

    func stage(items: [Item], groupID: Int64, status: Status) {
        // Model ownership is independent of visibility, a menu, or navigation availability.
        let modelGroupID = currentGroupID?()
        guard modelGroupID == nil || modelGroupID == groupID else { return }
        // Without an attached owner, prepare/selectGroup still establishes the target for late renders.
        if status == .loaded, let requestedGroupID, requestedGroupID != groupID, modelGroupID == nil { return }
        changeGroup(groupID)
        requested.items = items
        requested.status = status
        stageDelivery()
    }

    func selectGroup(_ groupID: Int64) {
        changeGroup(groupID)
        requested.items = []
        requested.status = .loading
        stageDelivery()
    }

    func setStatus(_ status: Status) {
        guard currentRequestBelongsToModel else { return }
        requested.status = status
        stageDelivery()
    }

    func setRefreshing(bookURLs: Set<String>, isRefreshing: Bool) {
        requested.refreshingBookURLs = bookURLs
        requested.isRefreshing = isRefreshing
        stageDelivery()
    }

    func invalidateLayout() {
        needsLayout = true
        stageDelivery()
    }

    func scrollToTop() {
        needsScrollToTop = true
        stageDelivery()
    }

    func setVisible(_ visible: Bool) {
        isVisible = visible
        timer?.invalidate()
        timer = nil
        if visible {
            applicationSuspended = UIApplication.shared.applicationState != .active
            sceneSuspended = collectionView?.window?.windowScene?.activationState != .foregroundActive
        }
        resumeDelivery()
    }

    func setTransitioning(_ transitioning: Bool) {
        isTransitioning = transitioning
        if !transitioning {
            needsLayout = true
            needsDelivery = true
        }
        resumeDelivery()
    }

    func resumeDelivery() {
        updateEnvironment()
        guard !isDelivering else { return }
        guard needsDelivery, currentRequestBelongsToModel, environmentAvailable, !isBusy else {
            waitForPresentation()
            return
        }
        stopWaiting()
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.deliver()
        }
    }

    private func stopWaiting() {
        timer?.invalidate()
        timer = nil
    }

    private func waitForPresentation() {
        guard (needsDelivery && currentRequestBelongsToModel) || needsEnvironmentRecovery,
            canWaitForPresentation, !isBusy
        else {
            stopWaiting()
            return
        }
        guard timer == nil else { return }
        let timer = Timer(
            timeInterval: 0.25, target: InteractionTarget(owner: self),
            selector: #selector(InteractionTarget.tick(_:)), userInfo: nil, repeats: false)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func retryPresentation(_ timer: Timer) {
        guard self.timer === timer else { return }
        self.timer = nil
        resumeDelivery()
    }

    private func stageDelivery() {
        needsDelivery = true
        resumeDelivery()
    }

    private func changeGroup(_ groupID: Int64) {
        guard requested.context.groupID != groupID else { return }
        onGroupChange?()
        requested.context = Context(groupID: groupID)
        requested.isRefreshing = false
        needsScrollToTop = false
        cancelInput()
    }

    private var currentRequestBelongsToModel: Bool {
        guard let modelGroupID = currentGroupID?(), let requestedGroupID else { return true }
        return requestedGroupID == modelGroupID
    }

    private var isBusy: Bool {
        guard let collectionView else { return true }
        let pan = collectionView.panGestureRecognizer.state
        let press = longPress?.state
        return hasTouches || isFinishingTouch || selection != nil
            || collectionView.isTracking || collectionView.isDragging || collectionView.isDecelerating
            || pan == .began || pan == .changed || press == .began || press == .changed
            || collectionView.visibleCells.contains(where: { $0.isHighlighted })
    }

    private func deliver() {
        updateEnvironment()
        guard environmentAvailable, currentRequestBelongsToModel, needsDelivery, !isDelivering, !isBusy else {
            waitForPresentation()
            return
        }
        let snapshot = requested
        let layout = needsLayout
        let scrollToTop = needsScrollToTop
        needsDelivery = false
        needsLayout = false
        needsScrollToTop = false
        isDelivering = true
        presented = snapshot
        onDeliver?(snapshot, layout, scrollToTop)
        isDelivering = false
        resumeDelivery()
    }

    private var canWaitForPresentation: Bool {
        guard isVisible, !isTransitioning, !applicationSuspended, !sceneSuspended,
            UIApplication.shared.applicationState == .active, let owner, let collectionView,
            let window = collectionView.window, window.isKeyWindow, !window.isHidden, window.alpha > 0,
            window.windowScene?.activationState == .foregroundActive
        else { return false }
        if owner.navigationController != nil, !owner.isVisibleInNavigationStack { return false }
        var ancestor: UIView? = owner.viewIfLoaded
        while let view = ancestor {
            guard !view.isHidden, view.alpha > 0.01, !view.accessibilityElementsHidden,
                view.isUserInteractionEnabled
            else { return false }
            if view === window { return true }
            ancestor = view.superview
        }
        return false
    }

    private var canUseEnvironment: Bool {
        guard canWaitForPresentation, let owner, owner.navigationController?.transitionCoordinator == nil,
            isCovered?() != true
        else { return false }
        var controller: UIViewController? = owner
        while let candidate = controller {
            guard !candidate.isBeingPresented, !candidate.isBeingDismissed,
                !candidate.isMovingFromParent, !candidate.isMovingToParent,
                candidate.presentedViewController == nil
            else { return false }
            controller = candidate.parent
        }
        return true
    }

    private func updateEnvironment() {
        let available = canUseEnvironment
        let shouldCancel = environmentAvailable && !available
        environmentAvailable = available
        needsEnvironmentRecovery = isVisible && !available
        if shouldCancel { cancelInput() }
        collectionView?.isUserInteractionEnabled =
            available && !isDelivering
            && requested.context == presented.context && currentRequestBelongsToModel
    }

    private func cancelInput() {
        guard !isCancellingInput else { return }
        isCancellingInput = true
        defer { isCancellingInput = false }
        touchGeneration = UUID()
        intent = nil
        selection = nil
        hasTouches = false
        isFinishingTouch = false
        cancelledIntent = true
        consumedIntent = true
        guard let collectionView else { return }
        collectionView.isUserInteractionEnabled = false
        observer?.isEnabled = false
        observer?.isEnabled = true
        longPress?.isEnabled = false
        longPress?.isEnabled = true
        collectionView.panGestureRecognizer.isEnabled = false
        collectionView.panGestureRecognizer.isEnabled = true
        collectionView.setContentOffset(collectionView.contentOffset, animated: false)
        for cell in collectionView.visibleCells { cell.isHighlighted = false }
        for path in collectionView.indexPathsForSelectedItems ?? [] {
            collectionView.deselectItem(at: path, animated: false)
        }
    }

    @objc private func activationChanged(_ notification: Notification) {
        if let scene = notification.object as? UIScene, scene !== collectionView?.window?.windowScene { return }
        if let window = notification.object as? UIWindow, window !== collectionView?.window { return }
        switch notification.name {
        case UIApplication.willResignActiveNotification: applicationSuspended = true
        case UIApplication.didBecomeActiveNotification: applicationSuspended = false
        case UIScene.willDeactivateNotification: sceneSuspended = true
        case UIScene.didActivateNotification: sceneSuspended = false
        default: break
        }
        resumeDelivery()
    }

    func bind(_ cell: UICollectionViewCell, item: Item, at path: IndexPath) -> Binding {
        let binding = Binding(
            context: presented.context, path: path, identity: item.identity, origin: item.origin,
            cell: ObjectIdentifier(cell))
        bindings[binding.cell] = binding
        return binding
    }

    func isBound(_ cell: UICollectionViewCell, at path: IndexPath) -> Bool {
        guard let binding = bindings[ObjectIdentifier(cell)], binding.context == presented.context,
            binding.path == path, presented.items.indices.contains(path.item)
        else { return false }
        let item = presented.items[path.item]
        return item.identity == binding.identity && item.origin == binding.origin
    }

    private func currentItem(_ binding: Binding, cell: UICollectionViewCell) -> Item? {
        guard canUseEnvironment, !isDelivering, currentRequestBelongsToModel,
            requested.context == presented.context, binding.context == requested.context,
            binding.cell == ObjectIdentifier(cell), bindings[binding.cell] == binding,
            let collectionView, cell.window === collectionView.window,
            collectionView.indexPathsForVisibleItems.contains(binding.path),
            collectionView.indexPath(for: cell) == binding.path,
            collectionView.cellForItem(at: binding.path) === cell,
            !cell.isHidden, cell.alpha > 0.01, presented.items.indices.contains(binding.path.item),
            presented.items[binding.path.item].identity == binding.identity,
            presented.items[binding.path.item].origin == binding.origin,
            let item = requested.items.first(where: { $0.identity == binding.identity }), item.origin == binding.origin
        else { return nil }
        return item
    }

    private func binding(at path: IndexPath) -> Binding? {
        guard let cell = collectionView?.cellForItem(at: path),
            let binding = bindings[ObjectIdentifier(cell)], currentItem(binding, cell: cell) != nil
        else { return nil }
        return binding
    }

    private var canActWithoutScrolling: Bool {
        guard canUseEnvironment, let collectionView else { return false }
        let pan = collectionView.panGestureRecognizer.state
        return !collectionView.isDragging && !collectionView.isDecelerating && pan != .began && pan != .changed
    }

    private func beginTouch(at point: CGPoint) {
        guard !isCancellingInput else { return }
        touchGeneration = UUID()
        hasTouches = true
        isFinishingTouch = false
        consumedIntent = false
        cancelledIntent = !canActWithoutScrolling
        selection = nil
        intent = collectionView?.indexPathForItem(at: point).flatMap { binding(at: $0) }
    }

    private func endTouch(cancelled: Bool) {
        guard !isCancellingInput else { return }
        hasTouches = false
        isFinishingTouch = true
        cancelledIntent = cancelledIntent || cancelled
        let generation = touchGeneration
        // UIKit may deliver selection after the recognizer's end callback in this event.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.touchGeneration == generation else { return }
            self.isFinishingTouch = false
            self.intent = nil
            self.selection = nil
            self.resumeDelivery()
        }
    }

    func shouldHighlight(at path: IndexPath) -> Bool {
        canActWithoutScrolling && binding(at: path) != nil && !cancelledIntentWhileTouching
    }

    private var cancelledIntentWhileTouching: Bool {
        (hasTouches || isFinishingTouch) && (cancelledIntent || consumedIntent)
    }

    func shouldSelect(at path: IndexPath) -> Bool {
        selection = nil
        guard canActWithoutScrolling, !cancelledIntentWhileTouching, let binding = binding(at: path) else { return false }
        if hasTouches || isFinishingTouch {
            guard intent == binding else { return false }
        }
        selection = binding
        DispatchQueue.main.async { [weak self] in
            guard let self, self.selection == binding else { return }
            self.selection = nil
            self.resumeDelivery()
        }
        return true
    }

    func consumeSelection(at path: IndexPath) -> Item? {
        let selected = selection
        selection = nil
        defer { resumeDelivery() }
        guard let selected, selected.path == path, canActWithoutScrolling,
            !cancelledIntentWhileTouching, let cell = collectionView?.cellForItem(at: path),
            let item = currentItem(selected, cell: cell)
        else { return nil }
        consumedIntent = true
        return item
    }

    func consumeDetails(from cell: UICollectionViewCell, binding: Binding) -> Item? {
        guard canActWithoutScrolling, !cancelledIntentWhileTouching,
            let item = currentItem(binding, cell: cell)
        else { return nil }
        if hasTouches || isFinishingTouch {
            guard intent == binding else { return nil }
        }
        consumedIntent = true
        selection = nil
        return item
    }

    func canRetry(from footer: UICollectionReusableView, context: Context, status: Status) -> Bool {
        guard canActWithoutScrolling, !cancelledIntentWhileTouching, !isDelivering,
            currentRequestBelongsToModel, context == requested.context, context == presented.context,
            status == requested.status, case .failure = status, let collectionView,
            footer.window === collectionView.window,
            collectionView.visibleSupplementaryViews(ofKind: UICollectionView.elementKindSectionFooter)
                .contains(where: { $0 === footer })
        else { return false }
        consumedIntent = true
        selection = nil
        return true
    }

    var canRefresh: Bool {
        canUseEnvironment && currentRequestBelongsToModel && requested.context == presented.context
            && requested.canRefresh && !requested.items.isEmpty && !requested.isRefreshing
    }

    func beganDragging() {
        cancelledIntent = true
        selection = nil
    }

    @objc private func panChanged(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began, .changed: beganDragging()
        case .ended, .cancelled, .failed: resumeDelivery()
        default: break
        }
    }

    @objc private func pressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, hasTouches || isFinishingTouch,
            let collectionView, let path = collectionView.indexPathForItem(at: gesture.location(in: collectionView)),
            let intent, intent.path == path, let cell = collectionView.cellForItem(at: path),
            let item = consumeDetails(from: cell, binding: intent)
        else {
            if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed { resumeDelivery() }
            return
        }
        cell.isHighlighted = false
        collectionView.deselectItem(at: path, animated: false)
        onLongPress?(item)
    }

    @MainActor
    private final class InteractionTarget: NSObject {
        weak var owner: BookshelfFolderPresentationCoordinator?
        init(owner: BookshelfFolderPresentationCoordinator) { self.owner = owner }
        @objc func tick(_ timer: Timer) {
            guard let owner else {
                timer.invalidate()
                return
            }
            owner.retryPresentation(timer)
        }
    }
}

/// Folder mode is toggled by hiding its child view, without forwarding appearance transitions.
final class BookshelfFolderPresentationView: UIView {
    var onVisibilityChange: (() -> Void)?

    override var isHidden: Bool {
        didSet { if oldValue != isHidden { onVisibilityChange?() } }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onVisibilityChange?()
    }
}

/// A passive recognizer also observes stationary cell/footer touches, including scroll cancellation.
private final class BookshelfFolderTouchObserver: UIGestureRecognizer {
    var onBegin: ((CGPoint) -> Void)?
    var onMove: (() -> Void)?
    var onEnd: ((Bool) -> Void)?
    private var touches = Set<UITouch>()
    private var start: CGPoint?

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func canPrevent(_: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by _: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        let wasEmpty = self.touches.isEmpty
        self.touches.formUnion(touches)
        if wasEmpty, let touch = touches.first {
            start = touch.location(in: view)
            if let start { onBegin?(start) }
        }
        if self.touches.count > 1 { onMove?() }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let start else { return }
        if touches.contains(where: { hypot($0.location(in: view).x - start.x, $0.location(in: view).y - start.y) > 10 }) {
            onMove?()
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        finish(touches, cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        finish(touches, cancelled: true)
    }

    private func finish(_ touches: Set<UITouch>, cancelled: Bool) {
        self.touches.subtract(touches)
        if cancelled { onMove?() }
        guard self.touches.isEmpty else { return }
        onEnd?(cancelled)
        if state == .possible { state = .failed }
    }

    override func reset() {
        if !touches.isEmpty { onEnd?(true) }
        touches.removeAll()
        start = nil
        super.reset()
    }
}
