import UIKit
import UIKit.UIGestureRecognizerSubclass
import shared

/// Owns the displayed URL snapshot separately from the newest subscription/filter payload.
@MainActor
final class ExploreSourceListCoordinator {
    private enum Section { case sources }

    final class Binding {
        let sourceURL: String
        fileprivate let context: UUID
        fileprivate let revision: UUID
        fileprivate let actionRevision: UUID
        fileprivate let input: UUID
        fileprivate weak var cell: AndroidExploreSourceCell?

        fileprivate init(
            sourceURL: String, context: UUID, revision: UUID, actionRevision: UUID,
            input: UUID, cell: AndroidExploreSourceCell
        ) {
            self.sourceURL = sourceURL
            self.context = context
            self.revision = revision
            self.actionRevision = actionRevision
            self.input = input
            self.cell = cell
        }
    }

    private struct Row {
        let source: BookSourcePart
        let expanded: Bool
        let loading: Bool
        let kinds: [ExploreKind]
        let isLast: Bool
        var revision = UUID()
        var actionRevision = UUID()

        func hasSameContent(as other: Row) -> Bool {
            ExploreSourceListCoordinator.sameSource(source, other.source)
                && expanded == other.expanded && loading == other.loading
                && kinds == other.kinds && isLast == other.isLast
        }
    }

    private struct Update {
        let urls: [String]
        let rows: [String: Row]
        let context: UUID
        let showsEmpty: Bool
    }

    private struct Anchor {
        let sourceURL: String
        let distance: CGFloat
    }

    private struct Restoration {
        let anchors: [Anchor]
        let offset: CGFloat
        let interaction: Int
        let scrollsToTop: Bool
    }

    private struct ExpansionScroll {
        let sourceURL: String
        let context: UUID
        let interaction: Int
    }

    var canUsePage: (() -> Bool)?
    var onDeliver: ((Int, Bool) -> Void)?
    var onToggle: ((Binding) -> Void)?
    var onKindSelected: ((Binding, ExploreKind) -> Void)?
    var onShowMenu: ((Binding, UIView) -> Void)?

    private let table: UITableView
    private let contact = ExploreSourceContactObserver()
    private var dataSource: UITableViewDiffableDataSource<Section, String>!
    private var requested: Update?
    private var presentedRows: [String: Row] = [:]
    private var presentedUpdate: Update?
    private var needsDeliveryNotification = false
    private var providerRows: [String: Row] = [:]
    private var providerContext = UUID()
    private var bindings: [String: Binding] = [:]
    private var query: String?
    private(set) var contextID = UUID()
    private var inputID = UUID()
    private var pending = false
    private var needsRebinding = false
    private var scheduled = false
    private var applying = false
    private var presentationActive = false
    private var menuCovered = false
    private var cancelledContact = false
    private var finishingContact = false
    private var interaction = 0
    private var restoration: Restoration?
    private var expansionScroll: ExpansionScroll?
    private var lastTabReselection: (time: TimeInterval, context: UUID, input: UUID)?
    private var scrollToTopTargetY: CGFloat?

    init(tableView: UITableView, interactionView: UIView) {
        table = tableView
        table.register(AndroidExploreSourceCell.self, forCellReuseIdentifier: AndroidExploreSourceCell.reuseIdentifier)
        dataSource = UITableViewDiffableDataSource<Section, String>(tableView: table) {
            [weak self] table, path, url in
            guard let self, let row = self.providerRows[url] else { return nil }
            let cell =
                table.dequeueReusableCell(
                    withIdentifier: AndroidExploreSourceCell.reuseIdentifier, for: path) as! AndroidExploreSourceCell
            cell.configure(
                source: row.source, isExpanded: row.expanded, isLoading: row.loading,
                kinds: row.kinds, isLast: row.isLast)
            let binding = Binding(
                sourceURL: url, context: self.providerContext, revision: row.revision,
                actionRevision: row.actionRevision, input: self.inputID, cell: cell)
            self.bindings[url] = binding
            cell.onToggle = { [weak self] in
                guard let self, self.source(for: binding) != nil else { return }
                self.onToggle?(binding)
            }
            cell.onKindSelected = { [weak self] kind in
                guard let self, self.source(for: binding) != nil,
                    let current = self.requested?.rows[url], current.expanded, current.kinds.contains(kind)
                else { return }
                self.onKindSelected?(binding, kind)
            }
            cell.onShowMenu = { [weak self, weak cell] anchor in
                guard let self, let cell, self.source(for: binding) != nil, anchor.isDescendant(of: cell) else { return }
                self.onShowMenu?(binding, anchor)
            }
            return cell
        }
        dataSource.defaultRowAnimation = .none
        // Presentation checks can query visible rows before the first source subscription arrives.
        var initial = NSDiffableDataSourceSnapshot<Section, String>()
        initial.appendSections([.sources])
        dataSource.applySnapshotUsingReloadData(initial)
        contact.onBegin = { [weak self] in
            guard let self else { return }
            self.cancelledContact = false
            self.noteUserInteraction()
        }
        contact.onMove = { [weak self] in self?.cancelledContact = true }
        contact.onEnd = { [weak self] cancelled in
            guard let self else { return }
            self.cancelledContact = self.cancelledContact || cancelled
            self.finishingContact = true
            // UIControl must consume touch-up before a deferred snapshot can replace its row.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.finishingContact = false
                self.resumeDelivery()
            }
        }
        interactionView.addGestureRecognizer(contact)
    }

    func render(
        sources: [BookSourcePart], query: String, expandedSourceURL: String?,
        kindsCache: [String: [ExploreKind]], isLoading: Bool
    ) {
        if self.query != query {
            self.query = query
            contextID = UUID()
            expansionScroll = nil
        }
        let filtered = ExploreSourceListPolicy.apply(sources, query: query)
        var urls: [String] = []
        var rows: [String: Row] = [:]
        for source in filtered where rows[source.bookSourceUrl] == nil {
            let url = source.bookSourceUrl
            urls.append(url)
            let expanded = url == expandedSourceURL
            var row = Row(
                source: source, expanded: expanded, loading: expanded && isLoading,
                kinds: expanded ? kindsCache[url] ?? [] : [],
                isLast: url == filtered.last?.bookSourceUrl)
            if let previous = requested?.rows[url], row.hasSameContent(as: previous) {
                row.revision = previous.revision
            }
            // A late kinds payload must not cancel a real header/menu action for an unchanged source.
            if let previous = requested?.rows[url], Self.sameSource(source, previous.source), expanded == previous.expanded {
                row.actionRevision = previous.actionRevision
            }
            rows[url] = row
        }
        // Revisions follow requests, not just applied snapshots: A -> B -> A cannot revive an old row.
        requested = Update(urls: urls, rows: rows, context: contextID, showsEmpty: sources.isEmpty && query.isEmpty)
        pending = true
        if let scroll = expansionScroll, rows[scroll.sourceURL]?.expanded != true { expansionScroll = nil }
        resumeDelivery()
    }

    func source(for binding: Binding, allowingMenu: Bool = false) -> BookSourcePart? {
        guard presentationActive, sceneActive, canUsePage?() == true, !applying,
            allowingMenu || (!menuCovered && !cancelledContact && !table.isDragging && !table.isDecelerating),
            binding.input == inputID, binding.context == contextID, bindings[binding.sourceURL] === binding,
            let row = requested?.rows[binding.sourceURL], row.actionRevision == binding.actionRevision,
            presentedRows[binding.sourceURL]?.revision == binding.revision,
            let cell = binding.cell, let window = table.window, cell.window === window,
            let path = table.indexPath(for: cell), table.cellForRow(at: path) === cell,
            dataSource.itemIdentifier(for: path) == binding.sourceURL,
            dataSource.indexPath(for: binding.sourceURL) == path,
            table.indexPathsForVisibleRows?.contains(path) == true,
            isVisible(cell, in: window, checkingAccessibility: !allowingMenu)
        else { return nil }
        return row.source
    }

    /// Source actions may outlive their cell (e.g. a delete confirmation), but never their source/filter.
    func hasCurrentSource(_ binding: Binding) -> Bool {
        binding.context == contextID && requested?.rows[binding.sourceURL]?.actionRevision == binding.actionRevision
    }

    func setPresentationActive(_ active: Bool) {
        guard active != presentationActive else {
            if active { resumeDelivery() }
            return
        }
        presentationActive = active
        if !active { invalidateInput() } else { cancelledContact = false }
        resumeDelivery()
    }

    func setMenuCovered(_ covered: Bool) {
        menuCovered = covered
        if covered {
            expansionScroll = nil
            lastTabReselection = nil
            cancelScrollToTop()
        }
        resumeDelivery()
    }

    func invalidateInput() {
        inputID = UUID()
        bindings.removeAll()
        needsRebinding = true
        expansionScroll = nil
        lastTabReselection = nil
        cancelScrollToTop()
        contact.cancelContact()
        cancelledContact = true
        resumeDelivery()
    }

    func noteUserInteraction() {
        interaction &+= 1
        expansionScroll = nil
        lastTabReselection = nil
        cancelScrollToTop()
    }

    /// MainActivity requires two reselects within 300ms, owned by the same visible input/filter.
    func consumeTabReselection() -> Bool {
        guard canHandleTabReselection else {
            lastTabReselection = nil
            return false
        }
        let now = ProcessInfo.processInfo.systemUptime
        if let previous = lastTabReselection, now - previous.time <= 0.3,
            previous.context == contextID, previous.input == inputID
        {
            return true
        }
        lastTabReselection = (now, contextID, inputID)
        return false
    }

    func scrollToTop(animated: Bool) {
        guard canHandleTabReselection else { return }
        noteUserInteraction()
        restoration = nil
        table.layoutIfNeeded()
        guard canHandleTabReselection else { return }
        let target = CGPoint(x: table.contentOffset.x, y: -table.adjustedContentInset.top)
        guard table.contentOffset != target else { return }
        let pixel = 1 / max(1, table.traitCollection.displayScale)
        let animates = animated && abs(table.contentOffset.y - target.y) > pixel
        scrollToTopTargetY = animates ? target.y : nil
        table.setContentOffset(target, animated: animates)
    }

    func requestExpansionScroll(sourceURL: String) {
        expansionScroll = ExpansionScroll(sourceURL: sourceURL, context: contextID, interaction: interaction)
    }

    func cancelExpansionScroll() { expansionScroll = nil }

    func didBeginDragging() {
        noteUserInteraction()
        cancelledContact = true
    }

    func finishScrolling() {
        if let target = scrollToTopTargetY {
            let pixel = 1 / max(1, table.traitCollection.displayScale)
            // A cancelled animation's late delegate callback cannot finish a newer scroll.
            guard
                abs(table.contentOffset.y - target) <= pixel
                    || abs(table.contentOffset.y + table.adjustedContentInset.top) <= pixel
            else { return }
            scrollToTopTargetY = nil
        }
        if !contact.hasContact && !table.isDragging && !table.isDecelerating { cancelledContact = false }
        resumeDelivery()
    }

    func resumeDelivery() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.deliver()
        }
    }

    private var sceneActive: Bool { table.window?.windowScene?.activationState == .foregroundActive }

    private var canDeliver: Bool {
        let pan = table.panGestureRecognizer.state
        return presentationActive && sceneActive && canUsePage?() == true && !menuCovered && !applying
            && !contact.hasContact && !finishingContact && !table.isTracking && !table.isDragging
            && !table.isDecelerating && pan != .began && pan != .changed && scrollToTopTargetY == nil
    }

    private var canHandleTabReselection: Bool {
        canDeliver && !pending && !needsRebinding && restoration == nil
            && requested?.context == contextID && presentedUpdate?.context == contextID
    }

    private func cancelScrollToTop() {
        guard scrollToTopTargetY != nil else { return }
        scrollToTopTargetY = nil
        // Stop at the current position; never retain a command to replay after uncovering/resuming.
        table.setContentOffset(table.contentOffset, animated: false)
    }

    private func deliver() {
        guard canDeliver else { return }
        restorePosition()
        guard pending || needsRebinding, let update = requested else {
            fulfillExpansionScroll()
            notifyDelivery()
            return
        }
        let rebind = needsRebinding
        cancelledContact = false
        pending = false
        needsRebinding = false
        let previous = Set(dataSource.snapshot().itemIdentifiers)
        // ExploreFragment's AdapterDataObserver scrolls to zero for an insertion at zero.
        let insertsFirst = update.urls.first.map { !previous.contains($0) } ?? false
        let position = capturePosition(scrollsToTop: insertsFirst)
        var snapshot = NSDiffableDataSourceSnapshot<Section, String>()
        snapshot.appendSections([.sources])
        snapshot.appendItems(update.urls)
        snapshot.reconfigureItems(
            update.urls.filter { url in
                previous.contains(url)
                    && (rebind || providerContext != update.context || presentedRows[url]?.revision != update.rows[url]?.revision)
            })
        providerRows = presentedRows.merging(update.rows) { _, new in new }
        providerContext = update.context
        applying = true
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            guard let self else { return }
            self.presentedRows = update.rows
            self.presentedUpdate = update
            self.needsDeliveryNotification = true
            self.providerRows = update.rows
            self.bindings = self.bindings.filter { url, binding in
                binding.cell != nil && binding.revision == update.rows[url]?.revision
                    && binding.context == update.context && binding.input == self.inputID
            }
            self.applying = false
            self.restoration = position
            if self.canDeliver {
                self.restorePosition()
                self.fulfillExpansionScroll()
                self.notifyDelivery()
            }
            self.resumeDeliveryIfNeeded()
        }
    }

    private func resumeDeliveryIfNeeded() {
        if pending || needsRebinding { resumeDelivery() }
    }

    private func notifyDelivery() {
        guard canDeliver, !pending, !needsRebinding, needsDeliveryNotification,
            let update = presentedUpdate, update.context == contextID
        else { return }
        needsDeliveryNotification = false
        onDeliver?(update.urls.count, update.showsEmpty)
    }

    private func capturePosition(scrollsToTop: Bool) -> Restoration {
        let anchors = (table.indexPathsForVisibleRows ?? []).sorted().compactMap { path -> Anchor? in
            guard let url = dataSource.itemIdentifier(for: path) else { return nil }
            return Anchor(sourceURL: url, distance: table.rectForRow(at: path).minY - table.contentOffset.y)
        }
        return Restoration(
            anchors: anchors, offset: table.contentOffset.y, interaction: interaction, scrollsToTop: scrollsToTop)
    }

    private func restorePosition() {
        guard canDeliver, let position = restoration else { return }
        restoration = nil
        guard position.interaction == interaction else { return }
        table.layoutIfNeeded()
        if position.scrollsToTop {
            setOffset(-table.adjustedContentInset.top)
            return
        }
        let anchor = position.anchors.first { dataSource.indexPath(for: $0.sourceURL) != nil }
        let offset =
            anchor.flatMap { anchor in
                dataSource.indexPath(for: anchor.sourceURL).map { table.rectForRow(at: $0).minY - anchor.distance }
            } ?? position.offset
        setOffset(offset)
    }

    private func fulfillExpansionScroll() {
        guard canDeliver, !pending, !needsRebinding, let scroll = expansionScroll else { return }
        guard scroll.context == contextID, scroll.interaction == interaction,
            let row = requested?.rows[scroll.sourceURL], row.expanded,
            presentedRows[scroll.sourceURL]?.revision == row.revision,
            let path = dataSource.indexPath(for: scroll.sourceURL)
        else {
            expansionScroll = nil
            return
        }
        table.layoutIfNeeded()
        // ExploreAdapter scrolls the row (including its 12dp top padding) to offset zero
        // both before and after kinds load. A later touch still cancels this request above.
        setOffset(table.rectForRow(at: path).minY - table.adjustedContentInset.top)
        if !row.loading { expansionScroll = nil }
    }

    private func setOffset(_ y: CGFloat) {
        let minY = -table.adjustedContentInset.top
        let maxY = max(minY, table.contentSize.height - table.bounds.height + table.adjustedContentInset.bottom)
        let offset = CGPoint(x: table.contentOffset.x, y: min(maxY, max(minY, y)))
        if table.contentOffset != offset { table.setContentOffset(offset, animated: false) }
    }

    private func isVisible(_ cell: UIView, in window: UIWindow, checkingAccessibility: Bool) -> Bool {
        var ancestor: UIView? = cell
        while let view = ancestor {
            guard !view.isHidden, view.alpha > 0.01, view.isUserInteractionEnabled,
                !checkingAccessibility || !view.accessibilityElementsHidden
            else { return false }
            if view === window { return true }
            ancestor = view.superview
        }
        return false
    }

    nonisolated static func sameSource(_ lhs: BookSourcePart, _ rhs: BookSourcePart) -> Bool {
        lhs.bookSourceUrl == rhs.bookSourceUrl && lhs.bookSourceName == rhs.bookSourceName
            && lhs.bookSourceGroup == rhs.bookSourceGroup && lhs.customOrder == rhs.customOrder
            && lhs.enabled == rhs.enabled && lhs.enabledExplore == rhs.enabledExplore
            && lhs.hasLoginUrl == rhs.hasLoginUrl && lhs.lastUpdateTime == rhs.lastUpdateTime
            && lhs.respondTime == rhs.respondTime && lhs.weight == rhs.weight
            && lhs.hasExploreUrl == rhs.hasExploreUrl && lhs.hasBookUrlPattern == rhs.hasBookUrlPattern
    }
}

@MainActor
private final class ExploreSourceContactObserver: UIGestureRecognizer {
    var onBegin: (() -> Void)?
    var onMove: (() -> Void)?
    var onEnd: ((Bool) -> Void)?
    private var touches: Set<UITouch> = []
    private var origin = CGPoint.zero
    var hasContact: Bool { !touches.isEmpty }

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        requiresExclusiveTouchType = false
    }

    override func canPrevent(_: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by _: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        let firstContact = self.touches.isEmpty
        self.touches.formUnion(touches)
        if firstContact, let touch = touches.first {
            origin = touch.location(in: view)
            onBegin?()
        }
        if self.touches.count > 1 { onMove?() }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first {
            let point = touch.location(in: view)
            if hypot(point.x - origin.x, point.y - origin.y) > 8 { onMove?() }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches, cancelled: false) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches, cancelled: true) }

    override func reset() {
        super.reset()
        if hasContact {
            touches.removeAll()
            onEnd?(true)
        }
    }

    func cancelContact() {
        guard hasContact else { return }
        touches.removeAll()
        state = .failed
        onEnd?(true)
    }

    private func finish(_ ended: Set<UITouch>, cancelled: Bool) {
        touches.subtract(ended)
        if cancelled { onMove?() }
        guard touches.isEmpty else { return }
        state = .failed
        onEnd?(cancelled)
    }
}

/// Presented alerts can dismiss without sending the root another viewDidAppear callback.
@MainActor
final class ExploreSourcePresentationObserver: UIView {
    var onRemoval: (() -> Void)?
    private var wasAttached = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            wasAttached = true
        } else if wasAttached {
            wasAttached = false
            let callback = onRemoval
            onRemoval = nil
            DispatchQueue.main.async { callback?() }
            removeFromSuperview()
        }
    }
}
