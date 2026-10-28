import UIKit
import shared

/// ExploreShowAdapter uses source URLs, not SearchAdapter's name/author aggregation.
@MainActor
final class ExploreResultsListCoordinator {
    private enum Section { case books }
    private enum Item: Hashable {
        case book(origin: String, url: String)
        case footer

        init(_ book: SearchBook) { self = .book(origin: book.origin, url: book.bookUrl) }
    }

    private final class Binding {
        weak var cell: UITableViewCell?
        let generation: UUID

        init(_ cell: UITableViewCell, generation: UUID) {
            self.cell = cell
            self.generation = generation
        }
    }

    private struct Update {
        let items: [Item]
        let books: [Item: SearchBook]
        let footer: ExploreResultsFooterCell.State
        let generation: UUID
    }

    private struct Anchor {
        let item: Item
        let distance: CGFloat
        let interaction: Int
    }

    private let table: UITableView
    private var dataSource: UITableViewDiffableDataSource<Section, Item>!
    private var records: [Item: SearchBook] = [:]
    private var providerRecords: [Item: SearchBook] = [:]
    private var bindings: [Item: Binding] = [:]
    private var bookshelfKeys: Set<String> = []
    private var generation: UUID?
    private var requestedGeneration: UUID?
    private var providerGeneration: UUID?
    private var footer: ExploreResultsFooterCell.State = .loading
    private var pending: Update?
    private var restoration: Anchor?
    private var resetsScrollOnRestore = false
    private var isApplying = false
    private var isPresentationActive = false
    private var isSuspended = false
    private var interaction = 0
    private var touchObserver: ExploreResultsTouchObserver?
    var canActivate: (() -> Bool)?
    var onBookSelected: ((SearchBook) -> Void)?
    var onFooterActivated: ((ExploreResultsFooterCell.State) -> Void)?
    var onContentSettled: (() -> Void)?

    var isContentSettled: Bool {
        isInteractive && !isInteracting && restoration == nil && !resetsScrollOnRestore
    }

    init(tableView: UITableView) {
        table = tableView
        table.register(ExploreResultsBookCell.self, forCellReuseIdentifier: ExploreResultsBookCell.reuseIdentifier)
        table.register(ExploreResultsFooterCell.self, forCellReuseIdentifier: ExploreResultsFooterCell.reuseIdentifier)
        dataSource = UITableViewDiffableDataSource<Section, Item>(tableView: table) { [weak self] table, path, item in
            guard let self, let generation = self.providerGeneration else { return nil }
            let cell: UITableViewCell
            if item == .footer {
                let footer =
                    table.dequeueReusableCell(
                        withIdentifier: ExploreResultsFooterCell.reuseIdentifier, for: path) as! ExploreResultsFooterCell
                footer.configure(self.footer)
                footer.setPresentationActive(self.isPresentationActive && !self.isSuspended && self.isSceneActive)
                cell = footer
            } else {
                guard let book = self.providerRecords[item] else { return nil }
                let result =
                    table.dequeueReusableCell(
                        withIdentifier: ExploreResultsBookCell.reuseIdentifier, for: path) as! ExploreResultsBookCell
                result.accessibilityIdentifier = UIIdentifiers.Discovery.resultCell
                result.setPresentationActive(self.isPresentationActive && !self.isSuspended && self.isSceneActive)
                result.configure(book: book, isInBookshelf: self.isInBookshelf(book))
                cell = result
            }
            let binding = Binding(cell, generation: generation)
            self.bindings[item] = binding
            let activate: () -> Void = { [weak self, weak cell] in
                guard let self, let cell, self.bindings[item] === binding,
                    let path = self.table.indexPath(for: cell), self.table.cellForRow(at: path) === cell,
                    self.dataSource.itemIdentifier(for: path) == item
                else { return }
                self.select(at: path)
            }
            (cell as? ExploreResultsBookCell)?.onActivate = activate
            (cell as? ExploreResultsFooterCell)?.onActivate = activate
            return cell
        }
        dataSource.defaultRowAnimation = .none
        let observer = ExploreResultsTouchObserver(
            onBegin: { [weak self] in self?.noteUserInteraction() },
            onEnd: { [weak self] in self?.finishScrolling() })
        touchObserver = observer
        table.addGestureRecognizer(observer)
        updateAvailability()
    }

    func render(books: [SearchBook], footer: ExploreResultsFooterCell.State, generation: UUID) {
        guard !isSuspended else { return }
        var items: [Item] = []
        var mapped: [Item: SearchBook] = [:]
        for book in books {
            let item = Item(book)
            if mapped[item] == nil { items.append(item) }
            mapped[item] = book
        }
        items.append(.footer)
        requestedGeneration = generation
        pending = Update(items: items, books: mapped, footer: footer, generation: generation)
        updateAvailability()
        applyPending()
    }

    func setBookshelfKeys(_ keys: Set<String>) {
        bookshelfKeys = keys
        for path in table.indexPathsForVisibleRows ?? [] {
            guard let item = dataSource.itemIdentifier(for: path), let book = records[item],
                let cell = table.cellForRow(at: path) as? ExploreResultsBookCell
            else { continue }
            cell.setInBookshelf(isInBookshelf(book))
        }
    }

    func setPresentationActive(_ active: Bool) {
        guard !isSuspended else { return }
        isPresentationActive = active
        setBoundCellsPresentationActive(active && isSceneActive)
        updateAvailability()
        if active {
            restoreAnchor()
            applyPending()
            notifyContentSettled()
        }
    }

    func noteUserInteraction() {
        interaction &+= 1
        restoration = nil
        resetsScrollOnRestore = false
    }

    func finishScrolling() {
        restoreAnchor()
        applyPending()
        notifyContentSettled()
    }

    func select(at path: IndexPath) {
        guard isInteractive, canActivate?() ?? true,
            let item = dataSource.itemIdentifier(for: path), let binding = bindings[item],
            binding.generation == generation, let cell = binding.cell,
            table.cellForRow(at: path) === cell, table.indexPathsForVisibleRows?.contains(path) == true,
            cell.window === table.window, cell.isUserInteractionEnabled, !cell.isHidden,
            !cell.accessibilityElementsHidden, cell.alpha > 0.01,
            ExploreAndroidGraphics.isAvailableForInteraction(cell)
        else { return }
        if item == .footer {
            onFooterActivated?(footer)
        } else if let book = records[item] {
            onBookSelected?(book)
        }
    }

    func suspend() {
        isSuspended = true
        setBoundCellsPresentationActive(false)
        pending = nil
        restoration = nil
        resetsScrollOnRestore = false
        bindings.removeAll()
        if let touchObserver { table.removeGestureRecognizer(touchObserver) }
        touchObserver = nil
        updateAvailability()
    }

    private var isInteracting: Bool {
        table.isDragging || table.isDecelerating || table.isTracking || touchObserver?.isPressing == true
    }

    private var isSceneActive: Bool { table.window?.windowScene?.activationState == .foregroundActive }

    private var isInteractive: Bool {
        !isSuspended && isPresentationActive && isSceneActive && !isApplying && pending == nil
            && generation != nil && generation == requestedGeneration
    }

    private func updateAvailability() { table.allowsSelection = isInteractive }

    private func notifyContentSettled() {
        guard isContentSettled else { return }
        onContentSettled?()
    }

    private func setBoundCellsPresentationActive(_ active: Bool) {
        let cells = Set(table.visibleCells + bindings.values.compactMap { $0.cell })
        for cell in cells {
            (cell as? ExploreResultsFooterCell)?.setPresentationActive(active)
            (cell as? ExploreResultsBookCell)?.setPresentationActive(active)
        }
    }

    private func isInBookshelf(_ book: SearchBook) -> Bool {
        BookshelfFacade.companion.isInBookshelf(
            keys: bookshelfKeys, name: book.name, author: book.author, bookUrl: book.bookUrl)
    }

    private func applyPending() {
        guard !isSuspended, isPresentationActive, isSceneActive, !isApplying, !isInteracting,
            let update = pending
        else { return }
        restoreAnchor()
        pending = nil
        let previous = dataSource.snapshot().itemIdentifiers
        let sameGeneration = generation == update.generation
        // A loading-only footer is not a reading anchor for the first page of books.
        let resetsScroll = !sameGeneration || (previous == [.footer] && !update.books.isEmpty)
        let anchor = resetsScroll ? nil : captureAnchor()
        let requestedInteraction = interaction
        let old = Set(previous)
        let retriesFailedCovers: Bool
        switch update.footer {
        // ExploreShowActivity calls setItems only when the delivered book count changes.
        case .ready, .empty, .end: retriesFailedCovers = previous.count != update.items.count
        case .loading, .error: retriesFailedCovers = false
        }
        let failedCoverItems: Set<Item> =
            retriesFailedCovers
            ? Set(
                (table.indexPathsForVisibleRows ?? []).compactMap { path -> Item? in
                    guard let cell = table.cellForRow(at: path) as? ExploreResultsBookCell, cell.needsCoverRetry else {
                        return nil
                    }
                    return dataSource.itemIdentifier(for: path)
                }) : []
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.books])
        snapshot.appendItems(update.items)
        snapshot.reconfigureItems(
            update.items.filter { item in
                old.contains(item)
                    && (!sameGeneration
                        || (item == .footer
                            ? self.footer != update.footer
                            : !Self.sameContent(self.records[item], update.books[item])
                                || failedCoverItems.contains(item)))
            })
        providerRecords = records.merging(update.books) { _, new in new }
        providerGeneration = update.generation
        footer = update.footer
        isApplying = true
        updateAvailability()
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            guard let self else { return }
            self.records = update.books
            self.providerRecords = update.books
            self.generation = update.generation
            let retainedItems = Set(update.items)
            self.bindings = self.bindings.filter {
                retainedItems.contains($0.key) && $0.value.cell != nil && $0.value.generation == update.generation
            }
            self.isApplying = false
            guard !self.isSuspended else { return }
            self.restoration = anchor
            if resetsScroll, self.interaction == requestedInteraction { self.resetsScrollOnRestore = true }
            self.restoreAnchor()
            self.updateAvailability()
            self.applyPending()
            self.notifyContentSettled()
        }
    }

    private func captureAnchor() -> Anchor? {
        guard let path = table.indexPathsForVisibleRows?.min(), let item = dataSource.itemIdentifier(for: path) else { return nil }
        return Anchor(item: item, distance: table.rectForRow(at: path).minY - table.contentOffset.y, interaction: interaction)
    }

    private func restoreAnchor() {
        guard !isSuspended, isPresentationActive, isSceneActive, !isApplying, !isInteracting else { return }
        if resetsScrollOnRestore {
            resetsScrollOnRestore = false
            restoration = nil
            table.layoutIfNeeded()
            table.setContentOffset(CGPoint(x: 0, y: -table.adjustedContentInset.top), animated: false)
            return
        }
        guard let anchor = restoration else { return }
        restoration = nil
        guard anchor.interaction == interaction, let path = dataSource.indexPath(for: anchor.item) else { return }
        table.layoutIfNeeded()
        let top = -table.adjustedContentInset.top
        let bottom = max(top, table.contentSize.height + table.adjustedContentInset.bottom - table.bounds.height)
        table.setContentOffset(CGPoint(x: 0, y: min(bottom, max(top, table.rectForRow(at: path).minY - anchor.distance))), animated: false)
    }

    private static func sameContent(_ lhs: SearchBook?, _ rhs: SearchBook?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs.bookUrl == rhs.bookUrl && lhs.origin == rhs.origin && lhs.name == rhs.name
            && lhs.author == rhs.author && lhs.originName == rhs.originName && lhs.coverUrl == rhs.coverUrl
            && lhs.kind == rhs.kind && lhs.tocUrl == rhs.tocUrl && lhs.variable == rhs.variable
            && lhs.wordCount == rhs.wordCount && lhs.latestChapterTitle == rhs.latestChapterTitle
            && lhs.intro == rhs.intro && lhs.origins == rhs.origins
    }
}

private final class ExploreResultsTouchObserver: UIGestureRecognizer {
    private var contacts: Set<UITouch> = []
    var isPressing: Bool { !contacts.isEmpty }
    private let onBegin: () -> Void
    private let onEnd: () -> Void

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
        if contacts.isEmpty { onBegin() }
        contacts.formUnion(touches)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        contacts.subtract(touches)
        if contacts.isEmpty { finish() }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        contacts.subtract(touches)
        if contacts.isEmpty { finish() }
    }

    override func reset() {
        super.reset()
        guard !contacts.isEmpty else { return }
        contacts.removeAll()
        DispatchQueue.main.async { [weak self] in self?.onEnd() }
    }

    private func finish() {
        if state == .possible { state = .failed }
        DispatchQueue.main.async { [weak self] in self?.onEnd() }
    }
}
