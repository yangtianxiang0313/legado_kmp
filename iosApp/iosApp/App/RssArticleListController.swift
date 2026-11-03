import shared
import UIKit

@MainActor
final class RssArticleListController: NSObject, UITableViewDataSource, UITableViewDelegate,
    UICollectionViewDataSource, UICollectionViewDelegateFlowLayout
{
    struct Pagination: Equatable {
        let title: String
        let isLoading: Bool
    }

    var isPresentationActive: () -> Bool = { false }
    var isArticleRead: (RssArticle) -> Bool = { $0.read }
    var onSelectArticle: ((RssArticle) -> Void)?
    var onLoadMore: (() -> Void)?
    let view = UIView()
    let tableView = UITableView(frame: .zero, style: .plain)
    private let flowLayout = RssArticleGridLayout()
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: flowLayout)
    private var articles: [RssArticle] = []
    private var style = RssArticlePresentationStyle.compact
    private var pagination: Pagination?
    private var bindings: [ObjectIdentifier: (article: RssArticle, id: UUID)] = [:]
    private var generation = UUID()
    private var pendingSizes: [ObjectIdentifier: () -> Bool] = [:]
    private var sizeWork: DispatchWorkItem?
    private var needsLayoutOnResume = false
    private var lastWidth: CGFloat = 0
    private var lastCategory: UIContentSizeCategory?
    private var lastDirection: UITraitEnvironmentLayoutDirection?
    private(set) var isRendering = false

    private var scrollView: UIScrollView { style == .grid ? collectionView : tableView }
    private var active: Bool { isPresentationActive() && view.window != nil && !view.isHidden }

    override init() {
        super.init()
        configureViews()
    }

    deinit { sizeWork?.cancel() }

    func display(
        articles: [RssArticle], style: RssArticlePresentationStyle, pagination: Pagination?,
        resetOffset: Bool = false, appendFrom: Int? = nil
    ) {
        let oldStyle = self.style
        let oldCount = self.articles.count
        let hadFooter = self.pagination != nil
        let anchor = captureAnchor()
        self.articles = articles
        self.pagination = pagination
        if oldStyle == style, appendFrom == oldCount, articles.count >= oldCount, active {
            appendRows(from: oldCount, hadFooter: hadFooter)
            return
        }
        suspend()
        bindings.removeAll()
        self.style = style
        isRendering = true
        tableView.isHidden = style == .grid
        collectionView.isHidden = style != .grid
        tableView.accessibilityValue = String(articles.count)
        collectionView.accessibilityValue = String(articles.count)
        if style == .grid {
            collectionView.reloadData()
            flowLayout.invalidateLayout()
        } else {
            tableView.reloadData()
        }
        view.layoutIfNeeded()
        if resetOffset {
            scrollView.setContentOffset(CGPoint(x: 0, y: -scrollView.adjustedContentInset.top), animated: false)
        } else {
            restoreAnchor(anchor)
        }
        isRendering = false
        resume()
    }

    func updatePagination(_ pagination: Pagination?) {
        guard self.pagination != pagination else { return }
        let wasVisible = self.pagination != nil
        self.pagination = pagination
        guard wasVisible == (pagination != nil) else {
            display(articles: articles, style: style, pagination: pagination)
            return
        }
        if let cell = tableView.cellForRow(at: IndexPath(row: articles.count, section: 0))
            as? AndroidReplicaLoadMoreCell
        {
            configureFooter(cell)
        }
        for case let footer as RssArticleGridFooter in collectionView.visibleSupplementaryViews(
            ofKind: UICollectionView.elementKindSectionFooter)
        { configureFooter(footer) }
    }

    func suspend() {
        generation = UUID()
        sizeWork?.cancel()
        sizeWork = nil
        needsLayoutOnResume = needsLayoutOnResume || !pendingSizes.isEmpty
        pendingSizes.removeAll()
        for cell in tableView.visibleCells { cancel(cell) }
        for cell in collectionView.visibleCells { cancel(cell) }
    }

    func resume() {
        guard active else { return }
        for cell in visibleCells() { resume(cell) }
        if needsLayoutOnResume { scheduleLayout() }
        scheduleSizeUpdate()
    }

    func layoutDidChange() {
        let traits = view.traitCollection
        if lastWidth != view.bounds.width || lastCategory != traits.preferredContentSizeCategory
            || lastDirection != traits.layoutDirection
        {
            lastWidth = view.bounds.width
            lastCategory = traits.preferredContentSizeCategory
            lastDirection = traits.layoutDirection
            scheduleLayout()
        }
        if active { resume() } else { suspend() }
    }

    func markRead(_ article: RssArticle) {
        for cell in visibleCells() where bindings[ObjectIdentifier(cell)]?.article === article {
            if let compact = cell as? AndroidReplicaRssArticleCell { compact.updateReadState(true) }
            mediaView(cell)?.updateReadState(true)
        }
    }

    private func configureViews() {
        view.backgroundColor = AndroidReplicaTheme.background
        tableView.backgroundColor = AndroidReplicaTheme.background
        tableView.accessibilityIdentifier = UIIdentifiers.RSS.table
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 100
        tableView.separatorStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(
            AndroidReplicaRssArticleCell.self, forCellReuseIdentifier: AndroidReplicaRssArticleCell.reuseIdentifier)
        tableView.register(RssArticleWideCell.self, forCellReuseIdentifier: RssArticleWideCell.reuseIdentifier)
        tableView.register(
            AndroidReplicaLoadMoreCell.self, forCellReuseIdentifier: AndroidReplicaLoadMoreCell.reuseIdentifier)
        flowLayout.minimumInteritemSpacing = 0
        flowLayout.minimumLineSpacing = 0
        flowLayout.sectionInset = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        collectionView.backgroundColor = AndroidReplicaTheme.background
        collectionView.accessibilityIdentifier = "rss.grid"
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.alwaysBounceVertical = true
        collectionView.isHidden = true
        collectionView.register(RssArticleGridCell.self, forCellWithReuseIdentifier: RssArticleGridCell.reuseIdentifier)
        collectionView.register(
            RssArticleGridFooter.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionFooter,
            withReuseIdentifier: RssArticleGridFooter.reuseIdentifier)
        for child in [tableView, collectionView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
            NSLayoutConstraint.activate([
                child.topAnchor.constraint(equalTo: view.topAnchor),
                child.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                child.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }
    }

    private struct Anchor {
        let identity: RssArticleListIdentity?
        let offset: CGFloat
        let fallbackY: CGFloat
    }

    private func captureAnchor() -> Anchor {
        let path: IndexPath?
        if style == .grid {
            path = collectionView.indexPathsForVisibleItems.sorted().first
        } else {
            path = tableView.indexPathsForVisibleRows?.sorted().first
        }
        guard let path, articles.indices.contains(path.item), let frame = frame(at: path) else {
            return Anchor(identity: nil, offset: 0, fallbackY: scrollView.contentOffset.y)
        }
        return Anchor(
            identity: RssArticleListIdentity(articles[path.item]),
            offset: frame.minY - scrollView.contentOffset.y, fallbackY: scrollView.contentOffset.y)
    }

    private func restoreAnchor(_ anchor: Anchor) {
        let offset: CGFloat
        if let identity = anchor.identity,
            let index = articles.firstIndex(where: { RssArticleListIdentity($0) == identity })
        {
            let path = IndexPath(item: index, section: 0)
            if style == .grid {
                collectionView.scrollToItem(at: path, at: .top, animated: false)
            } else {
                tableView.scrollToRow(at: path, at: .top, animated: false)
            }
            scrollView.layoutIfNeeded()
            offset = (frame(at: path)?.minY ?? 0) - anchor.offset
        } else {
            offset = anchor.fallbackY
        }
        let top = -scrollView.adjustedContentInset.top
        let bottom = max(
            top, scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
        scrollView.setContentOffset(CGPoint(x: 0, y: min(max(offset, top), bottom)), animated: false)
    }

    private func frame(at path: IndexPath) -> CGRect? {
        style == .grid ? collectionView.layoutAttributesForItem(at: path)?.frame : tableView.rectForRow(at: path)
    }

    private func appendRows(from oldCount: Int, hadFooter: Bool) {
        isRendering = true
        tableView.accessibilityValue = String(articles.count)
        collectionView.accessibilityValue = String(articles.count)
        UIView.performWithoutAnimation {
            if style == .grid {
                collectionView.performBatchUpdates {
                    let added = (oldCount..<articles.count).map { IndexPath(item: $0, section: 0) }
                    if !added.isEmpty { collectionView.insertItems(at: added) }
                    flowLayout.invalidateLayout()
                }
            } else {
                tableView.performBatchUpdates {
                    if hadFooter { tableView.deleteRows(at: [IndexPath(row: oldCount, section: 0)], with: .none) }
                    var added = (oldCount..<articles.count).map { IndexPath(row: $0, section: 0) }
                    if pagination != nil { added.append(IndexPath(row: articles.count, section: 0)) }
                    if !added.isEmpty { tableView.insertRows(at: added, with: .none) }
                }
            }
        }
        isRendering = false
        resume()
    }

    private func visibleCells() -> [UIView] {
        style == .grid ? collectionView.visibleCells.map { $0 as UIView } : tableView.visibleCells.map { $0 as UIView }
    }

    private func mediaView(_ cell: UIView) -> RssArticleMediaView? {
        if let cell = cell as? RssArticleWideCell { return cell.articleView }
        return (cell as? RssArticleGridCell)?.articleView
    }

    private func cancel(_ cell: UIView) {
        if let cell = cell as? AndroidReplicaRssArticleCell { cell.onSizeChange = nil; cell.cancelThumbnailLoading() }
        if let media = mediaView(cell) { media.onSizeChange = nil; media.cancelThumbnailLoading() }
    }

    private func configure(_ cell: UIView, article: RssArticle) {
        cancel(cell)
        bindings[ObjectIdentifier(cell)] = (article, UUID())
        cell.accessibilityIdentifier = UIIdentifiers.RSS.articleCell
        cell.isAccessibilityElement = true
        cell.accessibilityLabel = article.title
        cell.accessibilityValue = article.pubDate?.isEmpty == false ? article.pubDate : nil
        cell.accessibilityTraits = [.button]
        if let compact = cell as? AndroidReplicaRssArticleCell {
            compact.configure(article: article, isRead: isArticleRead(article))
        }
        mediaView(cell)?.configure(article: article, style: style, isRead: isArticleRead(article))
    }

    private func isCurrent(_ cell: UIView, article: RssArticle, configuration: UUID) -> Bool {
        guard active, let binding = bindings[ObjectIdentifier(cell)], binding.article === article,
            binding.id == configuration, cell.window === view.window, !cell.isHidden, cell.alpha > 0.01
        else { return false }
        if style == .grid {
            guard let gridCell = cell as? UICollectionViewCell, let path = collectionView.indexPath(for: gridCell),
                articles.indices.contains(path.item), articles[path.item] === article
            else { return false }
            return collectionView.cellForItem(at: path) === cell
                && collectionView.indexPathsForVisibleItems.contains(path)
                && collectionView.bounds.intersects(collectionView.layoutAttributesForItem(at: path)?.frame ?? .null)
        }
        guard let tableCell = cell as? UITableViewCell, let path = tableView.indexPath(for: tableCell),
            articles.indices.contains(path.row), articles[path.row] === article
        else { return false }
        return tableView.cellForRow(at: path) === cell && tableView.indexPathsForVisibleRows?.contains(path) == true
            && tableView.bounds.intersects(tableView.rectForRow(at: path))
    }

    private func resume(_ cell: UIView) {
        guard let binding = bindings[ObjectIdentifier(cell)],
            isCurrent(cell, article: binding.article, configuration: binding.id),
            let window = view.window, let scene = window.windowScene, let root = window.rootViewController
        else { cancel(cell); return }
        let epoch = generation
        let sizeChanged: () -> Void = { [weak self, weak cell, weak window, weak scene, weak root] in
            guard let self, let cell, let window, let scene, let root,
                self.generation == epoch, self.view.window === window,
                window.windowScene === scene, window.rootViewController === root,
                self.isCurrent(cell, article: binding.article, configuration: binding.id)
            else { return }
            self.pendingSizes[ObjectIdentifier(cell)] = { [weak self, weak cell, weak window, weak scene, weak root] in
                guard let self, let cell, let window, let scene, let root,
                    self.generation == epoch, self.view.window === window,
                    window.windowScene === scene, window.rootViewController === root
                else { return false }
                return self.isCurrent(cell, article: binding.article, configuration: binding.id)
            }
            self.scheduleSizeUpdate()
        }
        if let compact = cell as? AndroidReplicaRssArticleCell {
            compact.onSizeChange = { _ in sizeChanged() }
            compact.resumeThumbnailLoading()
        }
        if let media = mediaView(cell) { media.onSizeChange = sizeChanged; media.resumeThumbnailLoading() }
    }

    private var canUpdateSizes: Bool {
        active && !isRendering && !scrollView.isTracking && !scrollView.isDragging && !scrollView.isDecelerating
            && (style == .grid ? !collectionView.hasUncommittedUpdates : !tableView.hasUncommittedUpdates)
    }

    private func scheduleLayout() { needsLayoutOnResume = true; scheduleSizeUpdate() }

    private func scheduleSizeUpdate() {
        guard sizeWork == nil, needsLayoutOnResume || !pendingSizes.isEmpty, canUpdateSizes else { return }
        let epoch = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == epoch else { return }
            self.sizeWork = nil
            guard self.canUpdateSizes else { return }
            let requestedLayout = self.needsLayoutOnResume
            self.needsLayoutOnResume = false
            let pending = Array(self.pendingSizes.values)
            self.pendingSizes.removeAll()
            guard requestedLayout || pending.contains(where: { $0() }) else { return }
            let anchor = self.captureAnchor()
            self.isRendering = true
            UIView.performWithoutAnimation {
                if self.style == .grid {
                    self.flowLayout.invalidateLayout(); self.collectionView.layoutIfNeeded()
                } else {
                    self.tableView.performBatchUpdates(nil); self.tableView.layoutIfNeeded()
                }
            }
            self.restoreAnchor(anchor)
            self.isRendering = false
            self.scheduleSizeUpdate()
        }
        sizeWork = work
        DispatchQueue.main.async(execute: work)
    }

    private func configureFooter(_ cell: AndroidReplicaLoadMoreCell) {
        guard let pagination else { return }
        cell.configure(title: pagination.title)
        cell.accessibilityIdentifier = UIIdentifiers.RSS.loadMoreCell
        cell.isAccessibilityElement = true
        cell.accessibilityLabel = pagination.title
        cell.accessibilityTraits = pagination.isLoading ? [.button, .notEnabled] : [.button]
    }

    private func configureFooter(_ footer: RssArticleGridFooter) {
        footer.configure(pagination)
        footer.onLoadMore = { [weak self] in
            guard let self, self.active, !self.isRendering, self.pagination?.isLoading == false else { return }
            self.onLoadMore?()
        }
    }

    func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int { articles.count + (pagination == nil ? 0 : 1) }

    func tableView(_ tableView: UITableView, cellForRowAt path: IndexPath) -> UITableViewCell {
        if path.row == articles.count {
            let cell =
                tableView.dequeueReusableCell(withIdentifier: AndroidReplicaLoadMoreCell.reuseIdentifier, for: path)
                as! AndroidReplicaLoadMoreCell
            configureFooter(cell)
            return cell
        }
        let cell = tableView.dequeueReusableCell(
            withIdentifier: style == .largeImage
                ? RssArticleWideCell.reuseIdentifier : AndroidReplicaRssArticleCell.reuseIdentifier,
            for: path)
        configure(cell, article: articles[path.row])
        return cell
    }

    func tableView(_: UITableView, willDisplay cell: UITableViewCell, forRowAt _: IndexPath) {
        let epoch = generation
        DispatchQueue.main.async { [weak self, weak cell] in
            guard let self, let cell, self.generation == epoch else { return }
            self.resume(cell)
        }
    }

    func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt _: IndexPath) {
        guard !tableView.visibleCells.contains(where: { $0 === cell }) else { return }
        cancel(cell)
        bindings.removeValue(forKey: ObjectIdentifier(cell))
        pendingSizes.removeValue(forKey: ObjectIdentifier(cell))
    }

    func tableView(_ tableView: UITableView, didSelectRowAt path: IndexPath) {
        tableView.deselectRow(at: path, animated: true)
        guard active, !isRendering else { return }
        if path.row == articles.count {
            if pagination?.isLoading == false { onLoadMore?() }
        } else if articles.indices.contains(path.row) {
            onSelectArticle?(articles[path.row])
        }
    }

    func collectionView(_: UICollectionView, numberOfItemsInSection _: Int) -> Int { articles.count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt path: IndexPath) -> UICollectionViewCell {
        let cell =
            collectionView.dequeueReusableCell(withReuseIdentifier: RssArticleGridCell.reuseIdentifier, for: path)
            as! RssArticleGridCell
        configure(cell, article: articles[path.item])
        return cell
    }

    func collectionView(_: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt _: IndexPath) {
        let epoch = generation
        DispatchQueue.main.async { [weak self, weak cell] in
            guard let self, let cell, self.generation == epoch else { return }
            self.resume(cell)
        }
    }

    func collectionView(
        _ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt _: IndexPath
    ) {
        guard !collectionView.visibleCells.contains(where: { $0 === cell }) else { return }
        cancel(cell)
        bindings.removeValue(forKey: ObjectIdentifier(cell))
        pendingSizes.removeValue(forKey: ObjectIdentifier(cell))
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt path: IndexPath) {
        collectionView.deselectItem(at: path, animated: true)
        guard active, !isRendering, articles.indices.contains(path.item) else { return }
        onSelectArticle?(articles[path.item])
    }

    func collectionView(
        _ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String,
        at path: IndexPath
    ) -> UICollectionReusableView {
        let footer =
            collectionView.dequeueReusableSupplementaryView(
                ofKind: kind,
                withReuseIdentifier: RssArticleGridFooter.reuseIdentifier, for: path) as! RssArticleGridFooter
        configureFooter(footer)
        return footer
    }

    func collectionView(
        _ collectionView: UICollectionView, layout _: UICollectionViewLayout, sizeForItemAt path: IndexPath
    ) -> CGSize {
        let scale = max(collectionView.traitCollection.displayScale, 1)
        let width = floor(max(collectionView.bounds.width - 16, 2) / 2 * scale) / scale
        return CGSize(
            width: width,
            height: RssArticleMediaView.preferredGridHeight(
                article: articles[path.item], width: width, traits: collectionView.traitCollection))
    }

    func collectionView(
        _ collectionView: UICollectionView, layout _: UICollectionViewLayout,
        referenceSizeForFooterInSection _: Int
    ) -> CGSize {
        guard let pagination else { return .zero }
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .subheadline, compatibleWith: collectionView.traitCollection)
        label.numberOfLines = 0
        label.text = pagination.title
        let textHeight = label.sizeThatFits(
            CGSize(width: max(1, collectionView.bounds.width - 32), height: .greatestFiniteMagnitude)
        ).height
        return CGSize(
            width: collectionView.bounds.width,
            height: max(60, ceil(textHeight) + 32))
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard active, !isRendering, scrollView.isDragging || scrollView.isDecelerating,
            scrollView.contentOffset.y + scrollView.bounds.height > scrollView.contentSize.height - 120
        else { return }
        onLoadMore?()
    }

    func scrollViewDidEndDragging(_: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { scheduleSizeUpdate() }
    }

    func scrollViewDidEndDecelerating(_: UIScrollView) { scheduleSizeUpdate() }
}

private final class RssArticleGridLayout: UICollectionViewFlowLayout {
    override var flipsHorizontallyInOppositeLayoutDirection: Bool { true }
}

@MainActor
private final class RssArticleGridFooter: UICollectionReusableView {
    static let reuseIdentifier = "RssArticleGridFooter"
    var onLoadMore: (() -> Void)?
    private let button = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        button.accessibilityIdentifier = UIIdentifiers.RSS.loadMoreCell
        button.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.titleLabel?.numberOfLines = 0
        button.titleLabel?.lineBreakMode = .byWordWrapping
        button.contentEdgeInsets = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        button.setTitleColor(AndroidReplicaTheme.secondaryText, for: .normal)
        button.addTarget(self, action: #selector(loadMore), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor), button.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    func configure(_ pagination: RssArticleListController.Pagination?) {
        button.setTitle(pagination?.title, for: .normal)
        button.isEnabled = pagination != nil && pagination?.isLoading == false
        isHidden = pagination == nil
    }

    override func prepareForReuse() { super.prepareForReuse(); onLoadMore = nil; configure(nil) }
    @objc private func loadMore() { onLoadMore?() }
}
