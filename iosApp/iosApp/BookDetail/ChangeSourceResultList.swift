import UIKit
import shared

/// Keeps streaming result updates separate from the committed selection and visible scroll anchor.
@MainActor
final class ChangeSourceResultList {
    private struct Identity: Hashable {
        let sourceURL: String
        let bookURL: String

        init(_ candidate: BookSourceChangeCandidate) {
            sourceURL = candidate.sourceUrl
            bookURL = candidate.bookUrl
        }
    }

    private enum Section { case results }
    private enum ScrollRequest { case current, top, bottom }

    private final class CellBinding {
        weak var cell: ChangeSourceCandidateCell?
        let generation: UUID

        init(cell: ChangeSourceCandidateCell, generation: UUID) {
            self.cell = cell
            self.generation = generation
        }
    }

    private struct Update {
        let identities: [Identity]
        let records: [Identity: BookSourceChangeCandidate]
        let generation: UUID
        let resetScroll: Bool
        let presentationRevision: Int
    }

    private struct Anchor {
        let identity: Identity
        let topOffset: CGFloat
        let interactionVersion: Int
    }

    private struct ScrollRestoration {
        let generation: UUID
        let reset: Bool
        let anchor: Anchor?
        let interactionVersion: Int
    }

    private let tableView: UITableView
    private let currentSourceURL: String
    private let currentBookURL: String?
    private let ratings: ChangeSourceRatingStore
    private var presentationRevision = 0
    private var appliedPresentationRevision = 0
    private var dataSource: UITableViewDiffableDataSource<Section, Identity>!
    private var records: [Identity: BookSourceChangeCandidate] = [:]
    private var providerRecords: [Identity: BookSourceChangeCandidate] = [:]
    private var cellBindings: [Identity: CellBinding] = [:]
    private var requestedGeneration = UUID()
    private var appliedGeneration: UUID?
    private var providerGeneration: UUID?
    private var pendingUpdate: Update?
    private var pendingScroll: ScrollRequest?
    private var scrollRestoration: ScrollRestoration?
    private var pendingVisibleCount: Int?
    private var touchObserver: ChangeSourceTouchObserver?
    private var interactionVersion = 0
    private var isApplying = false
    private var isActive = false
    private var isSuspended = false
    private var isFastScrolling = false
    private var isDeliveryScheduled = false

    /// Owner checks (top controller, modal ownership) gate actions, never queued rendering.
    var canInteract: (() -> Bool)?
    var onVisibleCountChange: ((Int) -> Void)?
    var onScore: ((BookSourceChangeCandidate, Int) -> Void)?
    var loadWordCount = false { didSet { if oldValue != loadWordCount { presentationRevision &+= 1 } } }
    var isScoreEnabled = true {
        didSet {
            if oldValue != isScoreEnabled { presentationRevision &+= 1 }
            updateInteractionAvailability()
        }
    }

    init(tableView: UITableView, currentSourceURL: String, currentBookURL: String?, ratings: ChangeSourceRatingStore) {
        self.tableView = tableView
        self.currentSourceURL = currentSourceURL
        self.currentBookURL = currentBookURL
        self.ratings = ratings
        tableView.register(
            ChangeSourceCandidateCell.self, forCellReuseIdentifier: ChangeSourceCandidateCell.reuseIdentifier)
        dataSource = UITableViewDiffableDataSource<Section, Identity>(tableView: tableView) {
            [weak self] tableView, indexPath, identity in
            guard let self, let candidate = self.providerRecords[identity], let generation = self.providerGeneration
            else { return nil }
            let cell =
                tableView.dequeueReusableCell(
                    withIdentifier: ChangeSourceCandidateCell.reuseIdentifier, for: indexPath)
                as! ChangeSourceCandidateCell
            self.configure(cell, candidate: candidate)
            let binding = CellBinding(cell: cell, generation: generation)
            self.cellBindings[identity] = binding
            self.bindScore(cell, identity: identity, binding: binding)
            return cell
        }
        dataSource.defaultRowAnimation = .none
        let observer = ChangeSourceTouchObserver(
            onBegin: { [weak self] in self?.noteUserInteraction() },
            onEnd: { [weak self] in self?.interactionDidEnd() })
        touchObserver = observer
        tableView.addGestureRecognizer(observer)
        updateInteractionAvailability()
    }

    /// Starts paused; queued renders survive temporary disappearance and scene deactivation.
    func setActive(_ active: Bool) {
        guard !isSuspended else { return }
        isActive = active
        updateInteractionAvailability()
        if active { deliverPending() }
    }

    /// A repeated search/filter must not revive bindings from an earlier identical result set.
    func beginNewGeneration() {
        guard !isSuspended else { return }
        requestedGeneration = UUID()
        pendingUpdate = nil
        pendingScroll = nil
        scrollRestoration = nil
        pendingVisibleCount = nil
        updateInteractionAvailability()
    }

    func render(_ candidates: [BookSourceChangeCandidate], resetScroll: Bool = false) {
        guard !isSuspended else { return }
        var identities: [Identity] = []
        var updated: [Identity: BookSourceChangeCandidate] = [:]
        for candidate in candidates {
            let identity = Identity(candidate)
            if updated[identity] == nil { identities.append(identity) }
            updated[identity] = candidate
        }
        pendingUpdate = Update(
            identities: identities, records: updated, generation: requestedGeneration,
            resetScroll: resetScroll || requestedGeneration != appliedGeneration || pendingUpdate?.resetScroll == true,
            presentationRevision: presentationRevision)
        updateInteractionAvailability()
        deliverPending()
    }

    func candidate(at indexPath: IndexPath) -> BookSourceChangeCandidate? {
        guard isContentInteractive, canInteract?() ?? true,
            let identity = dataSource.itemIdentifier(for: indexPath),
            dataSource.indexPath(for: identity) == indexPath,
            let cell = tableView.cellForRow(at: indexPath),
            let binding = cellBindings[identity], binding.cell === cell,
            binding.generation == appliedGeneration, isVisible(cell, at: indexPath)
        else { return nil }
        return records[identity]
    }

    func noteUserInteraction() {
        guard !isSuspended else { return }
        interactionVersion &+= 1
        pendingScroll = nil
    }

    func setFastScrolling(_ scrolling: Bool) {
        guard !isSuspended else { return }
        if scrolling && !isFastScrolling { noteUserInteraction() }
        isFastScrolling = scrolling
        updateInteractionAvailability()
        if !scrolling { interactionDidEnd() }
    }

    func interactionDidEnd() {
        guard !isSuspended, !isDeliveryScheduled else { return }
        isDeliveryScheduled = true
        // UIKit can still report tracking inside its touch/drag-end callback.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isDeliveryScheduled = false
            self.deliverPending()
        }
    }

    func noteScoreChanged() { presentationRevision &+= 1 }

    func refreshPalette() {
        guard !isSuspended else { return }
        presentationRevision &+= 1
        // Keep the newest queued records and defer cell changes through normal touch/scroll delivery.
        let identities = pendingUpdate?.identities ?? dataSource.snapshot().itemIdentifiers
        let latest = pendingUpdate?.records ?? providerRecords
        render(identities.compactMap { latest[$0] })
    }

    func scrollToCurrent() { requestScroll(.current) }
    func scrollToEdge(last: Bool) { requestScroll(last ? .bottom : .top) }

    func suspend() {
        isSuspended = true
        isActive = false
        pendingUpdate = nil
        pendingScroll = nil
        scrollRestoration = nil
        pendingVisibleCount = nil
        updateInteractionAvailability()
        cellBindings.removeAll()
        if let touchObserver { tableView.removeGestureRecognizer(touchObserver) }
        touchObserver = nil
    }

    private var isPresentationActive: Bool {
        !isSuspended && isActive && tableView.window?.windowScene?.activationState == .foregroundActive
    }

    private var isContentInteractive: Bool {
        isPresentationActive && !isApplying && pendingUpdate == nil && !isFastScrolling
            && !tableView.isDragging && !tableView.isDecelerating
            && appliedGeneration != nil && appliedGeneration == requestedGeneration
    }

    private var canDeliver: Bool {
        isPresentationActive && !isApplying && !isFastScrolling
            && !tableView.isDragging && !tableView.isDecelerating && !tableView.isTracking
            && touchObserver?.hasTouches != true
    }

    private func updateInteractionAvailability() {
        tableView.allowsSelection = isContentInteractive
        for indexPath in tableView.indexPathsForVisibleRows ?? [] {
            guard let cell = tableView.cellForRow(at: indexPath) as? ChangeSourceCandidateCell else { continue }
            guard let identity = dataSource.itemIdentifier(for: indexPath),
                let binding = cellBindings[identity], binding.cell === cell
            else {
                cell.onScore = nil
                continue
            }
            bindScore(cell, identity: identity, binding: binding)
        }
    }

    private func configure(_ cell: ChangeSourceCandidateCell, candidate: BookSourceChangeCandidate) {
        cell.configure(
            candidate: candidate, isCurrent: candidate.bookUrl == currentBookURL,
            score: ratings.bookScore(candidate), loadWordCount: loadWordCount, isScoreEnabled: isScoreEnabled)
    }

    private func bindScore(_ cell: ChangeSourceCandidateCell, identity: Identity, binding: CellBinding) {
        guard isContentInteractive, isScoreEnabled, binding.generation == appliedGeneration else {
            cell.onScore = nil
            return
        }
        cell.onScore = { [weak self, weak cell] score in
            guard let self, let cell else { return }
            guard self.isScoreEnabled, self.cellBindings[identity] === binding,
                let indexPath = self.tableView.indexPath(for: cell),
                self.tableView.cellForRow(at: indexPath) === cell,
                self.dataSource.itemIdentifier(for: indexPath) == identity,
                let candidate = self.candidate(at: indexPath)
            else {
                // A rating control updates optimistically; a rejected action must show the stored score.
                if self.cellBindings[identity] === binding, binding.cell === cell,
                    binding.generation == self.providerGeneration,
                    let indexPath = self.tableView.indexPath(for: cell),
                    self.tableView.cellForRow(at: indexPath) === cell,
                    self.dataSource.itemIdentifier(for: indexPath) == identity,
                    let candidate = self.providerRecords[identity]
                {
                    self.configure(cell, candidate: candidate)
                }
                return
            }
            self.onScore?(candidate, score)
        }
    }

    private func isVisible(_ cell: UITableViewCell, at indexPath: IndexPath) -> Bool {
        guard let window = tableView.window, cell.window === window,
            tableView.indexPathsForVisibleRows?.contains(indexPath) == true
        else { return false }
        var ancestor: UIView? = cell
        while let view = ancestor {
            guard !view.isHidden, view.alpha > 0.01, !view.accessibilityElementsHidden, view.isUserInteractionEnabled
            else { return false }
            if view === window { return true }
            ancestor = view.superview
        }
        return false
    }

    private func deliverPending() {
        guard canDeliver else { return }
        if let update = pendingUpdate {
            pendingUpdate = nil
            apply(update)
            return
        }
        restoreScrollPosition()
        performPendingScroll()
        updateInteractionAvailability()
        if let count = pendingVisibleCount {
            pendingVisibleCount = nil
            onVisibleCountChange?(count)
        }
    }

    private func apply(_ update: Update) {
        let previous = dataSource.snapshot().itemIdentifiers
        let prior = scrollRestoration.flatMap {
            $0.generation == update.generation && $0.interactionVersion == interactionVersion ? $0 : nil
        }
        let reset = update.resetScroll || previous.first != update.identities.first || prior?.reset == true
        let restoration = ScrollRestoration(
            generation: update.generation, reset: reset,
            anchor: reset ? nil : (prior?.anchor ?? captureAnchor()), interactionVersion: interactionVersion)
        scrollRestoration = nil
        let generationChanged = appliedGeneration != update.generation
        let oldIdentities = Set(previous)
        var snapshot = NSDiffableDataSourceSnapshot<Section, Identity>()
        snapshot.appendSections([.results])
        snapshot.appendItems(update.identities)
        let changed = update.identities.filter { identity in
            oldIdentities.contains(identity)
                && (generationChanged || appliedPresentationRevision != update.presentationRevision
                    || !Self.sameContent(records[identity], update.records[identity]))
        }
        snapshot.reconfigureItems(changed)
        providerRecords = records.merging(update.records) { _, new in new }
        providerGeneration = update.generation
        isApplying = true
        updateInteractionAvailability()
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            guard let self else { return }
            self.isApplying = false
            guard !self.isSuspended else { return }
            self.records = update.records
            self.providerRecords = update.records
            self.appliedGeneration = update.generation
            self.appliedPresentationRevision = update.presentationRevision
            self.cellBindings = self.cellBindings.filter {
                update.records[$0.key] != nil && $0.value.cell != nil && $0.value.generation == update.generation
            }
            if update.generation == self.requestedGeneration {
                self.scrollRestoration = restoration
                self.pendingVisibleCount = update.identities.count
            }
            self.updateInteractionAvailability()
            self.deliverPending()
        }
    }

    private func captureAnchor() -> Anchor? {
        guard let indexPath = tableView.indexPathsForVisibleRows?.min(),
            let identity = dataSource.itemIdentifier(for: indexPath)
        else { return nil }
        return Anchor(
            identity: identity, topOffset: tableView.rectForRow(at: indexPath).minY - tableView.contentOffset.y,
            interactionVersion: interactionVersion)
    }

    private func restoreScrollPosition() {
        guard canDeliver, let restoration = scrollRestoration else { return }
        scrollRestoration = nil
        guard pendingScroll == nil, restoration.generation == requestedGeneration,
            restoration.interactionVersion == interactionVersion
        else { return }
        tableView.layoutIfNeeded()
        if restoration.reset {
            setClampedOffset(-tableView.adjustedContentInset.top)
        } else if let anchor = restoration.anchor, anchor.interactionVersion == interactionVersion,
            let indexPath = dataSource.indexPath(for: anchor.identity)
        {
            setClampedOffset(tableView.rectForRow(at: indexPath).minY - anchor.topOffset)
        }
    }

    private func setClampedOffset(_ y: CGFloat) {
        guard canDeliver else { return }
        let minY = -tableView.adjustedContentInset.top
        let maxY = max(
            minY, tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom)
        tableView.setContentOffset(CGPoint(x: 0, y: min(maxY, max(minY, y))), animated: false)
    }

    private func requestScroll(_ request: ScrollRequest) {
        guard !isSuspended else { return }
        noteUserInteraction()
        pendingScroll = request
        deliverPending()
    }

    private func performPendingScroll() {
        guard canDeliver, pendingUpdate == nil, appliedGeneration == requestedGeneration,
            let request = pendingScroll
        else { return }
        pendingScroll = nil
        let identities = dataSource.snapshot().itemIdentifiers
        let identity: Identity?
        switch request {
        case .current:
            if let currentBookURL {
                identity = identities.first { $0.bookURL == currentBookURL }
            } else {
                identity = identities.first { $0.sourceURL == currentSourceURL }
            }
        case .top:
            identity = identities.first
        case .bottom:
            identity = identities.last
        }
        guard let identity, let indexPath = dataSource.indexPath(for: identity) else { return }
        if request == .current {
            let interaction = interactionVersion
            let generation = appliedGeneration
            // Materialize estimated-height rows before applying Android's 60dp top offset.
            tableView.scrollToRow(at: indexPath, at: .top, animated: false)
            tableView.layoutIfNeeded()
            guard canDeliver, interaction == interactionVersion, appliedGeneration == generation,
                dataSource.itemIdentifier(for: indexPath) == identity
            else { return }
            setClampedOffset(tableView.rectForRow(at: indexPath).minY - tableView.adjustedContentInset.top - 60)
        } else {
            tableView.scrollToRow(at: indexPath, at: .top, animated: false)
        }
    }

    private static func sameContent(_ lhs: BookSourceChangeCandidate?, _ rhs: BookSourceChangeCandidate?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs.sourceName == rhs.sourceName && lhs.displayName == rhs.displayName && lhs.author == rhs.author
            && lhs.latestChapterTitle == rhs.latestChapterTitle && lhs.chapterWordCountText == rhs.chapterWordCountText
            && lhs.respondTime == rhs.respondTime
            && lhs.chapterWordCount == rhs.chapterWordCount
            && lhs.bookType == rhs.bookType
    }
}

// Observes stationary touches too, without taking ownership from table/controls/long-press gestures.
private final class ChangeSourceTouchObserver: UIGestureRecognizer {
    private let onBegin: () -> Void
    private let onEnd: () -> Void
    private var trackedTouches = Set<UITouch>()
    var hasTouches: Bool { !trackedTouches.isEmpty }

    init(onBegin: @escaping () -> Void, onEnd: @escaping () -> Void) {
        self.onBegin = onBegin
        self.onEnd = onEnd
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func canPrevent(_: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by _: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        let firstTouch = trackedTouches.isEmpty
        trackedTouches.formUnion(touches)
        if firstTouch { onBegin() }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        finish(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        finish(touches)
    }

    private func finish(_ touches: Set<UITouch>) {
        trackedTouches.subtract(touches)
        guard trackedTouches.isEmpty else { return }
        if state == .possible { state = .failed }
        onEnd()
    }
}
