import UIKit
import shared

/// SearchAdapter identifies aggregate results by name and author, not their current primary source URL.
final class AndroidSearchResultList {
    private enum Section { case results }
    private enum Item: Hashable {
        case book(name: String, author: String)

        init(_ book: SearchBook) { self = .book(name: book.name, author: book.author) }
    }
    private struct RenderGeneration: Equatable {
        let value: String
        let token = UUID()
    }
    private final class CellBinding {
        weak var cell: AndroidSearchResultCell?
        let generation: RenderGeneration

        init(cell: AndroidSearchResultCell, generation: RenderGeneration) {
            self.cell = cell
            self.generation = generation
        }
    }
    private struct Update {
        let items: [Item]
        let books: [Item: SearchBook]
        let generation: RenderGeneration
        let resetScroll: Bool
    }
    private struct Anchor {
        let item: Item
        let offset: CGFloat
        let interaction: Int
    }
    private struct ScrollRestoration {
        let reset: Bool
        let anchors: [Anchor]
        let interaction: Int
    }

    private let table: UITableView
    private var dataSource: UITableViewDiffableDataSource<Section, Item>!
    private var records: [Item: SearchBook] = [:]
    private var providerRecords: [Item: SearchBook] = [:]
    private var cellBindings: [Item: CellBinding] = [:]
    private var bookshelfKeys: Set<String> = []
    private var generation: RenderGeneration?
    private var requestedGeneration: RenderGeneration?
    private var providerGeneration: RenderGeneration?
    private var pending: Update?
    private var scrollRestoration: ScrollRestoration?
    private var isApplying = false
    private var isActive = true
    private var isPresentationActive = false
    private var isContentVisible = true
    private var interaction = 0
    private var touchEndObserver: AndroidSearchTouchEndObserver?
    var canActivate: (() -> Bool)?
    var onBookSelected: ((SearchBook) -> Void)?
    var onContentSettled: (() -> Void)?

    var isContentSettled: Bool {
        isContentInteractive && scrollRestoration == nil
            && !table.isDragging && !table.isDecelerating && !table.isTracking
    }

    init(tableView: UITableView) {
        table = tableView
        table.register(AndroidSearchResultCell.self, forCellReuseIdentifier: AndroidSearchResultCell.reuseIdentifier)
        dataSource = UITableViewDiffableDataSource<Section, Item>(tableView: table) {
            [weak self] table, indexPath, item in
            guard let self else { return nil }
            guard let book = self.providerRecords[item], let generation = self.providerGeneration else { return nil }
            let cell =
                table.dequeueReusableCell(
                    withIdentifier: AndroidSearchResultCell.reuseIdentifier, for: indexPath) as! AndroidSearchResultCell
            cell.setPresentationActive(self.coversAreActive)
            cell.configure(book: book, isInBookshelf: self.isInBookshelf(book))
            let binding = CellBinding(cell: cell, generation: generation)
            self.cellBindings[item] = binding
            cell.onActivate = { [weak self, weak cell] in
                guard let self, let cell,
                    self.cellBindings[item] === binding, binding.generation == self.generation,
                    let indexPath = self.table.indexPath(for: cell),
                    self.table.cellForRow(at: indexPath) === cell,
                    self.dataSource.itemIdentifier(for: indexPath) == item
                else { return }
                self.activate(at: indexPath)
            }
            return cell
        }
        dataSource.defaultRowAnimation = .none
        let observer = AndroidSearchTouchEndObserver { [weak self] in self?.finishScrolling() }
        touchEndObserver = observer
        table.addGestureRecognizer(observer)
        updateSelectionAvailability()
    }

    func render(books: [SearchBook], generation: String) {
        guard isActive else { return }
        // A -> B -> A must not revive bindings from the first A while B was pending.
        let renderGeneration =
            requestedGeneration.flatMap { $0.value == generation ? $0 : nil }
            ?? RenderGeneration(value: generation)
        requestedGeneration = renderGeneration
        var items: [Item] = []
        var mapped: [Item: SearchBook] = [:]
        for book in books {
            let identity = Item(book)
            if mapped[identity] == nil { items.append(identity) }
            mapped[identity] = book
        }
        let resetScroll = books.isEmpty || renderGeneration != self.generation || pending?.resetScroll == true
        pending = Update(
            items: items, books: mapped, generation: renderGeneration, resetScroll: resetScroll)
        updateSelectionAvailability()
        applyPending()
    }

    func setBookshelfKeys(_ keys: Set<String>) {
        bookshelfKeys = keys
        for indexPath in table.indexPathsForVisibleRows ?? [] {
            guard let item = dataSource.itemIdentifier(for: indexPath),
                let book = providerRecords[item], let cell = table.cellForRow(at: indexPath) as? AndroidSearchResultCell
            else { continue }
            cell.setInBookshelf(isInBookshelf(book))
        }
    }

    func setContentVisible(_ visible: Bool) {
        isContentVisible = visible
        updateCoverPresentation()
        updateSelectionAvailability()
    }

    /// Starts paused; the owner resumes on appearance/scene activation without discarding queued renders.
    func setPresentationActive(_ active: Bool) {
        guard isActive else { return }
        isPresentationActive = active
        updateCoverPresentation()
        updateSelectionAvailability()
        if active {
            restoreScrollPosition()
            applyPending()
            notifyContentSettled()
        }
    }

    func select(at indexPath: IndexPath) {
        activate(at: indexPath)
    }

    func book(at indexPath: IndexPath) -> SearchBook? {
        guard let item = currentItem(at: indexPath) else { return nil }
        return records[item]
    }

    func noteUserInteraction() { interaction &+= 1 }
    func finishScrolling() {
        restoreScrollPosition()
        applyPending()
        notifyContentSettled()
    }

    func suspend() {
        isActive = false
        updateCoverPresentation()
        pending = nil
        scrollRestoration = nil
        cellBindings.removeAll()
        if let touchEndObserver { table.removeGestureRecognizer(touchEndObserver) }
        touchEndObserver = nil
        table.allowsSelection = false
    }

    private var isSceneActive: Bool {
        table.window?.windowScene?.activationState == .foregroundActive
    }

    private var coversAreActive: Bool {
        isActive && isPresentationActive && isContentVisible && isSceneActive
    }

    private func updateCoverPresentation() {
        let cells = Set(table.visibleCells + cellBindings.values.compactMap { $0.cell })
        for cell in cells.compactMap({ $0 as? AndroidSearchResultCell }) {
            cell.setPresentationActive(coversAreActive)
        }
    }

    private var isContentInteractive: Bool {
        isActive && isPresentationActive && isContentVisible && isSceneActive
            && !isApplying && pending == nil && generation != nil && generation == requestedGeneration
    }

    private func updateSelectionAvailability() {
        table.allowsSelection = isContentInteractive
    }

    private func notifyContentSettled() {
        if isContentSettled { onContentSettled?() }
    }

    private func currentItem(at indexPath: IndexPath) -> Item? {
        guard isContentInteractive, canActivate?() ?? true,
            let item = dataSource.itemIdentifier(for: indexPath),
            dataSource.indexPath(for: item) == indexPath,
            let cell = table.cellForRow(at: indexPath), isVisible(cell, at: indexPath)
        else { return nil }
        guard let binding = cellBindings[item], binding.cell === cell, binding.generation == generation
        else { return nil }
        return item
    }

    private func isVisible(_ cell: UITableViewCell, at indexPath: IndexPath) -> Bool {
        guard let window = table.window, cell.window === window,
            table.indexPathsForVisibleRows?.contains(indexPath) == true
        else { return false }
        var ancestor: UIView? = cell
        while let view = ancestor {
            guard !view.isHidden, view.alpha > 0.01, !view.accessibilityElementsHidden,
                view.isUserInteractionEnabled
            else { return false }
            if view === window { return true }
            ancestor = view.superview
        }
        return false
    }

    private func activate(at indexPath: IndexPath) {
        guard let item = currentItem(at: indexPath) else { return }
        if let book = records[item] {
            onBookSelected?(book)
        }
    }

    private func isInBookshelf(_ book: SearchBook) -> Bool {
        BookshelfFacade.companion.isInBookshelf(
            keys: bookshelfKeys, name: book.name, author: book.author, bookUrl: book.bookUrl)
    }

    private func applyPending() {
        guard isActive, isPresentationActive, isSceneActive, !isApplying,
            !table.isDragging, !table.isDecelerating, !table.isTracking,
            let update = pending
        else { return }
        restoreScrollPosition()
        pending = nil
        let previousItems = dataSource.snapshot().itemIdentifiers
        // SearchActivity only scrolls to zero for an insertion at zero or a move
        // to zero. Removing a leading result should preserve the visible book.
        let reset = update.resetScroll || requiresScrollReset(from: previousItems, to: update.items)
        let anchors = reset ? [] : captureAnchors()
        let restoration = ScrollRestoration(reset: reset, anchors: anchors, interaction: interaction)
        let generationChanged = generation != update.generation
        let old = Set(previousItems)
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.results])
        snapshot.appendItems(update.items)
        // SearchBook.equals only compares URL; compare the actual rendered fields instead.
        let changed = update.items.filter { item in
            old.contains(item)
                && (generationChanged || !Self.sameContent(records[item], update.books[item]))
        }
        snapshot.reconfigureItems(changed)
        providerRecords = records.merging(update.books) { _, new in new }
        providerGeneration = update.generation
        isApplying = true
        table.allowsSelection = false
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            guard let self else { return }
            self.records = update.books
            self.providerRecords = update.books
            self.generation = update.generation
            self.cellBindings = self.cellBindings.filter {
                update.books[$0.key] != nil && $0.value.cell != nil && $0.value.generation == update.generation
            }
            self.isApplying = false
            guard self.isActive else { return }
            self.scrollRestoration = restoration
            self.restoreScrollPosition()
            self.updateSelectionAvailability()
            self.applyPending()
            self.notifyContentSettled()
        }
    }

    private func restoreScrollPosition() {
        guard isActive, isPresentationActive, isSceneActive, !isApplying,
            !table.isDragging, !table.isDecelerating, !table.isTracking,
            let restoration = scrollRestoration
        else { return }
        scrollRestoration = nil
        guard interaction == restoration.interaction else { return }
        table.layoutIfNeeded()
        if restoration.reset {
            table.setContentOffset(CGPoint(x: 0, y: -table.adjustedContentInset.top), animated: false)
        } else if let anchor = restoration.anchors.first(where: {
            $0.interaction == interaction && dataSource.indexPath(for: $0.item) != nil
        }),
            let indexPath = dataSource.indexPath(for: anchor.item)
        {
            let minY = -table.adjustedContentInset.top
            let maxY = max(minY, table.contentSize.height - table.bounds.height + table.adjustedContentInset.bottom)
            let y = table.rectForRow(at: indexPath).minY - anchor.offset
            table.setContentOffset(CGPoint(x: 0, y: min(maxY, max(minY, y))), animated: false)
        }
    }

    private func captureAnchors() -> [Anchor] {
        (table.indexPathsForVisibleRows ?? []).sorted().compactMap { indexPath in
            guard let item = dataSource.itemIdentifier(for: indexPath) else { return nil }
            return Anchor(
                item: item, offset: table.rectForRow(at: indexPath).minY - table.contentOffset.y,
                interaction: interaction)
        }
    }

    private func requiresScrollReset(from previous: [Item], to updated: [Item]) -> Bool {
        guard let first = updated.first, first != previous.first else { return false }
        guard let previousIndex = previous.firstIndex(of: first) else { return true }
        let remaining = Set(updated)
        // If every preceding item disappeared, this is a removal, not a move.
        return previous[..<previousIndex].contains { remaining.contains($0) }
    }

    private static func sameContent(_ lhs: SearchBook?, _ rhs: SearchBook?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs.bookUrl == rhs.bookUrl && lhs.origin == rhs.origin && lhs.name == rhs.name
            && lhs.author == rhs.author
            && lhs.originName == rhs.originName && lhs.coverUrl == rhs.coverUrl && lhs.kind == rhs.kind
            && lhs.tocUrl == rhs.tocUrl && lhs.variable == rhs.variable
            && lhs.wordCount == rhs.wordCount && lhs.latestChapterTitle == rhs.latestChapterTitle
            && lhs.intro == rhs.intro
            && lhs.origins == rhs.origins
    }
}

// A stationary touch also defers snapshots, but sends no scroll-view drag-end callback.
private final class AndroidSearchTouchEndObserver: UIGestureRecognizer {
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
