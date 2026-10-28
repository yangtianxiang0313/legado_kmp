import UIKit
import shared

final class BookshelfFolderViewController: UIViewController,
    UICollectionViewDataSource, UICollectionViewDelegateFlowLayout
{
    var onOpen: ((Book) -> Void)?
    var onDetails: ((Book) -> Void)?
    var onOpenGroup: ((Int64) -> Void)?
    var onEditGroup: ((Int64) -> Void)?
    var onRefresh: (() -> Void)?
    var onRetry: (() -> Void)?

    private typealias Identity = BookshelfFolderPresentationCoordinator.Identity
    private typealias Item = BookshelfFolderPresentationCoordinator.Item
    private typealias Status = BookshelfFolderPresentationCoordinator.Status

    private struct ScrollAnchor {
        let identity: Identity?
        let fallbackIndex: Int
        let distanceFromTop: CGFloat

        static let top = ScrollAnchor(identity: nil, fallbackIndex: 0, distanceFromTop: 0)
    }

    private struct Geometry: Equatable {
        let size: CGSize
        let insets: UIEdgeInsets
        let contentSizeCategory: UIContentSizeCategory
    }

    private let collectionView: UICollectionView
    private let refreshControl = UIRefreshControl()
    private lazy var presentation = BookshelfFolderPresentationCoordinator(
        owner: self, collectionView: collectionView)
    private var items: [Item] = []
    private var groupID: Int64?
    private var layoutMode: BookshelfLayoutMode = .grid3
    private var preferences: AppUiPreferences?
    private var canRefresh = true
    private var isRefreshing = false
    private var refreshingBookURLs: Set<String> = []
    private var status: Status = .idle
    private var anchors: [Int64: ScrollAnchor] = [:]
    private var pendingAnchor: ScrollAnchor?
    private var geometry: Geometry?
    private var isUpdatingContent = false

    init() {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 0
        layout.minimumLineSpacing = 0
        layout.sectionInset = .zero
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override func loadView() {
        let content = BookshelfFolderPresentationView()
        content.onVisibilityChange = { [weak self] in self?.refreshPresentation() }
        view = content
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AndroidReplicaTheme.background
        collectionView.backgroundColor = AndroidReplicaTheme.background
        collectionView.accessibilityIdentifier = "bookshelf.folder.books"
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.alwaysBounceVertical = true
        collectionView.contentInsetAdjustmentBehavior = .always
        collectionView.refreshControl = refreshControl
        collectionView.register(
            AndroidReplicaBookshelfCell.self,
            forCellWithReuseIdentifier: AndroidReplicaBookshelfCell.reuseIdentifier)
        collectionView.register(
            BookshelfFolderGroupCell.self,
            forCellWithReuseIdentifier: BookshelfFolderGroupCell.reuseIdentifier)
        collectionView.register(
            BookshelfFolderStatusView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionFooter,
            withReuseIdentifier: BookshelfFolderStatusView.reuseIdentifier)
        presentation.currentGroupID = { [weak self] in
            (self?.parent as? AndroidReplicaBookshelfViewController)?.screen.currentSelectedGroupId
        }
        presentation.isCovered = { [weak self] in
            (self?.parent as? AndroidReplicaBookshelfViewController)?.bookshelfOverflowMenu?.superview != nil
        }
        presentation.onGroupChange = { [weak self] in self?.rememberPosition() }
        presentation.onDeliver = { [weak self] snapshot, needsLayout, scrollToTop in
            self?.apply(snapshot, needsLayout: needsLayout, scrollToTop: scrollToTop)
        }
        presentation.onLongPress = { [weak self] item in self?.openDetails(for: item) }
        refreshControl.tintColor = AndroidReplicaTheme.accent
        refreshControl.addTarget(self, action: #selector(refresh), for: .valueChanged)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        updateRefreshControl()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        presentation.setVisible(true)
    }

    override func viewWillDisappear(_ animated: Bool) {
        rememberPosition()
        presentation.setVisible(false)
        super.viewWillDisappear(animated)
    }

    func refreshPresentation() {
        guard isViewLoaded else { return }
        presentation.resumeDelivery()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !isUpdatingContent, collectionView.bounds.width > 0,
            geometry != currentGeometry || (pendingAnchor != nil && !items.isEmpty && status != .loading)
        else { return }
        presentation.invalidateLayout()
    }

    override func viewWillTransition(
        to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator
    ) {
        rememberPosition()
        pendingAnchor = pendingAnchor ?? savedAnchor ?? readingAnchor()
        presentation.setTransitioning(true)
        super.viewWillTransition(to: size, with: coordinator)
        let scheduled = coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.presentation.setTransitioning(false)
        }
        if !scheduled { presentation.setTransitioning(false) }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard isViewLoaded,
            previousTraitCollection?.preferredContentSizeCategory
                != traitCollection.preferredContentSizeCategory
        else { return }
        presentation.invalidateLayout()
    }

    func configure(layoutMode: BookshelfLayoutMode, preferences: AppUiPreferences?, canRefresh: Bool) {
        loadViewIfNeeded()
        presentation.configure(layoutMode: layoutMode, preferences: preferences, canRefresh: canRefresh)
    }

    func render(groups: [BookGroup], books: [Book], groupID: Int64) {
        let folders = groupID == BookshelfScreenAdapter.rootGroupId ? groups.map(Item.group) : []
        loadViewIfNeeded()
        presentation.stage(items: folders + books.map(Item.book), groupID: groupID, status: .loaded)
    }

    func prepare(groups: [BookGroup], groupID: Int64) {
        let folders = groupID == BookshelfScreenAdapter.rootGroupId ? groups.map(Item.group) : []
        loadViewIfNeeded()
        presentation.stage(items: folders, groupID: groupID, status: .loading)
    }

    func showLoading() {
        loadViewIfNeeded()
        refreshControl.endRefreshing()
        presentation.setStatus(.loading)
    }

    func showFailure(_ message: String) {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        loadViewIfNeeded()
        refreshControl.endRefreshing()
        presentation.setStatus(.failure(message.isEmpty ? L10n.Common.loadFailedTitle : message))
    }

    func setRefreshing(bookURLs: Set<String>, isRefreshing: Bool) {
        loadViewIfNeeded()
        // Android style2 ends the pull immediately; each book owns its background spinner.
        refreshControl.endRefreshing()
        presentation.setRefreshing(bookURLs: bookURLs, isRefreshing: isRefreshing)
    }

    func scrollToTop() {
        loadViewIfNeeded()
        if let groupID = presentation.requestedGroupID { anchors[groupID] = .top }
        presentation.scrollToTop()
    }

    private var currentGeometry: Geometry {
        Geometry(
            size: collectionView.bounds.size, insets: collectionView.adjustedContentInset,
            contentSizeCategory: traitCollection.preferredContentSizeCategory)
    }

    private var savedAnchor: ScrollAnchor? { groupID.flatMap { anchors[$0] } }

    private var visibleStatus: Status? {
        if items.isEmpty { return status == .idle ? nil : status }
        if case .failure = status { return status }
        return nil
    }

    private var contentWidth: CGFloat {
        let insets = collectionView.adjustedContentInset
        return max(1, collectionView.bounds.width - insets.left - insets.right)
    }

    private func positionForUpdate() -> ScrollAnchor {
        if let pendingAnchor { return pendingAnchor }
        if isViewLoaded, geometry == currentGeometry, let anchor = readingAnchor() { return anchor }
        return savedAnchor ?? .top
    }

    private func apply(
        _ snapshot: BookshelfFolderPresentationCoordinator.Snapshot, needsLayout: Bool, scrollToTop: Bool
    ) {
        let switchingGroups = groupID != snapshot.context.groupID
        let anchor: ScrollAnchor
        if scrollToTop {
            anchor = .top
        } else if switchingGroups {
            rememberPosition()
            anchor = snapshot.context.groupID.flatMap { anchors[$0] } ?? .top
        } else {
            anchor = positionForUpdate()
        }
        let identitiesChanged = items.map(\.identity) != snapshot.items.map(\.identity)
        let layoutChanged = layoutMode != snapshot.layoutMode
        let previousStatus = visibleStatus
        isUpdatingContent = true
        defer {
            isUpdatingContent = false
            if pendingAnchor == nil { rememberPosition() }
        }
        groupID = snapshot.context.groupID
        items = snapshot.items
        status = snapshot.status
        layoutMode = snapshot.layoutMode
        preferences = snapshot.preferences
        canRefresh = snapshot.canRefresh
        isRefreshing = snapshot.isRefreshing
        refreshingBookURLs = snapshot.refreshingBookURLs
        collectionView.accessibilityValue = String(items.count)
        updateRefreshControl()
        UIView.performWithoutAnimation {
            if switchingGroups || identitiesChanged {
                updateLayout(keeping: anchor, reload: true)
            } else {
                reconfigureVisibleCells()
                if needsLayout || layoutChanged || geometry != currentGeometry
                    || previousStatus != visibleStatus || pendingAnchor != nil || scrollToTop
                {
                    updateLayout(keeping: anchor, reload: false)
                } else {
                    reconfigureVisibleFooters()
                }
            }
        }
    }

    private func updateRefreshControl() {
        refreshControl.endRefreshing()
        refreshControl.isEnabled = canRefresh && !items.isEmpty && !isRefreshing
    }

    private func updateLayout(keeping anchor: ScrollAnchor, reload: Bool) {
        pendingAnchor = anchor
        if reload { collectionView.reloadData() }
        collectionView.collectionViewLayout.invalidateLayout()
        reconfigureVisibleFooters()
        collectionView.layoutIfNeeded()
        geometry = currentGeometry
        if collectionView.bounds.width > 0, collectionView.bounds.height > 0 {
            restore(anchor)
            // Root folders may arrive before its books; keep the pre-entry book anchor until the snapshot is ready.
            if status != .loading, !items.isEmpty { pendingAnchor = nil }
        }
        view.setNeedsLayout()
    }

    private func item(at path: IndexPath) -> Item? {
        guard path.section == 0, items.indices.contains(path.item) else { return nil }
        return items[path.item]
    }

    private func reconfigureVisibleCells() {
        for path in collectionView.indexPathsForVisibleItems {
            guard let item = item(at: path), let cell = collectionView.cellForItem(at: path) else {
                continue
            }
            configure(cell, item: item, at: path)
        }
    }

    private func reconfigureVisibleFooters() {
        for view in collectionView.visibleSupplementaryViews(
            ofKind: UICollectionView.elementKindSectionFooter)
        {
            if let footer = view as? BookshelfFolderStatusView { configure(footer) }
        }
    }

    private func configure(_ cell: UICollectionViewCell, item: Item, at path: IndexPath) {
        let binding = presentation.bind(cell, item: item, at: path)
        switch item {
        case .group(let group):
            guard let cell = cell as? BookshelfFolderGroupCell else { return }
            cell.configure(group: group, isGrid: layoutMode != .list)
            cell.onEdit = { [weak self, weak cell] in
                guard let self, let cell,
                    let item = self.presentation.consumeDetails(from: cell, binding: binding)
                else { return }
                self.openDetails(for: item)
            }
        case .book(let book):
            guard let cell = cell as? AndroidReplicaBookshelfCell else { return }
            cell.configure(
                book: book, isGrid: layoutMode != .list, preferences: preferences,
                isRefreshing: refreshingBookURLs.contains(book.bookUrl))
            cell.onOpenDetails = { [weak self, weak cell] in
                guard let self, let cell,
                    let item = self.presentation.consumeDetails(from: cell, binding: binding)
                else { return }
                self.openDetails(for: item)
            }
        }
    }

    private func configure(_ footer: BookshelfFolderStatusView) {
        let message: String?
        let loading: Bool
        let canRetry: Bool
        switch visibleStatus {
        case .loading?:
            message = nil
            loading = true
            canRetry = false
        case .loaded?:
            message = BookshelfEmptyState.message
            loading = false
            canRetry = false
        case .failure(let failure)?:
            message = failure
            loading = false
            canRetry = true
        default:
            message = nil
            loading = false
            canRetry = false
        }
        footer.configure(message: message, loading: loading, canRetry: canRetry)
        let context = presentation.presented.context
        let status = self.status
        footer.onRetry = { [weak self, weak footer] in
            guard let self, let footer,
                self.presentation.canRetry(from: footer, context: context, status: status)
            else { return }
            self.onRetry?()
        }
    }

    private func readingAnchor() -> ScrollAnchor? {
        guard isViewLoaded, !items.isEmpty else { return nil }
        let top = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        if top <= 0.5 { return .top }
        let paths = collectionView.indexPathsForVisibleItems.sorted()
        guard
            let path = paths.first(where: {
                collectionView.layoutAttributesForItem(at: $0).map { $0.frame.maxY > top } ?? false
            }), let item = item(at: path),
            let frame = collectionView.layoutAttributesForItem(at: path)?.frame
        else { return nil }
        return ScrollAnchor(
            identity: item.identity, fallbackIndex: path.item, distanceFromTop: frame.minY - top)
    }

    private func rememberPosition() {
        guard !isUpdatingContent, pendingAnchor == nil, isViewLoaded,
            geometry == currentGeometry, let groupID, let anchor = readingAnchor()
        else { return }
        anchors[groupID] = anchor
    }

    private func restore(_ anchor: ScrollAnchor) {
        let insets = collectionView.adjustedContentInset
        var y = -insets.top
        if let identity = anchor.identity, !items.isEmpty {
            let index =
                items.firstIndex(where: { $0.identity == identity })
                ?? min(anchor.fallbackIndex, items.count - 1)
            if let frame = collectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?
                .frame
            {
                let distance = max(anchor.distanceFromTop, -max(0, frame.height - 1))
                y = frame.minY - distance - insets.top
            }
        }
        let maximum = max(
            -insets.top, collectionView.contentSize.height - collectionView.bounds.height + insets.bottom)
        collectionView.setContentOffset(
            CGPoint(x: -insets.left, y: min(max(y, -insets.top), maximum)), animated: false)
    }

    @objc private func refresh() {
        refreshControl.endRefreshing()
        guard presentation.canRefresh else { return }
        onRefresh?()
    }

    private func openDetails(for item: Item) {
        switch item {
        case .group(let group): onEditGroup?(group.groupId)
        case .book(let book): onDetails?(book)
        }
    }

    func scrollViewDidScroll(_: UIScrollView) { rememberPosition() }

    func scrollViewWillBeginDragging(_: UIScrollView) { presentation.beganDragging() }

    func scrollViewDidEndDragging(_: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { presentation.resumeDelivery() }
    }

    func scrollViewDidEndDecelerating(_: UIScrollView) { presentation.resumeDelivery() }
    func scrollViewDidEndScrollingAnimation(_: UIScrollView) { presentation.resumeDelivery() }
    func scrollViewDidScrollToTop(_: UIScrollView) { presentation.resumeDelivery() }

    func collectionView(_: UICollectionView, numberOfItemsInSection _: Int) -> Int { items.count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath)
        -> UICollectionViewCell
    {
        let item = items[indexPath.item]
        let identifier: String
        switch item {
        case .group: identifier = BookshelfFolderGroupCell.reuseIdentifier
        case .book: identifier = AndroidReplicaBookshelfCell.reuseIdentifier
        }
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: identifier, for: indexPath)
        configure(cell, item: item, at: indexPath)
        return cell
    }

    func collectionView(
        _: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath
    ) {
        guard !presentation.isBound(cell, at: indexPath), let item = item(at: indexPath) else { return }
        configure(cell, item: item, at: indexPath)
    }

    func collectionView(_: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        presentation.shouldHighlight(at: indexPath)
    }

    func collectionView(_: UICollectionView, didUnhighlightItemAt _: IndexPath) {
        presentation.resumeDelivery()
    }

    func collectionView(_: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        presentation.shouldSelect(at: indexPath)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard let item = presentation.consumeSelection(at: indexPath) else { return }
        switch item {
        case .book(let book): onOpen?(book)
        case .group(let group):
            guard let onOpenGroup else { return }
            presentation.selectGroup(group.groupId)
            onOpenGroup(group.groupId)
        }
    }

    func collectionView(
        _: UICollectionView, layout _: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        let isGrid = layoutMode != .list
        let columns = isGrid ? CGFloat(min(6, max(3, Int(layoutMode.columnCount)))) : 1
        let scale = max(1, traitCollection.displayScale)
        let width = max(1 / scale, floor(contentWidth / columns * scale) / scale)
        let category = traitCollection.preferredContentSizeCategory
        if case .group? = item(at: indexPath) {
            return BookshelfFolderGroupCell.preferredSize(
                width: width, isGrid: isGrid, contentSizeCategory: category)
        }
        return AndroidReplicaBookshelfCell.preferredSize(
            width: width, isGrid: isGrid, contentSizeCategory: category)
    }

    func collectionView(
        _ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String,
        at indexPath: IndexPath
    ) -> UICollectionReusableView {
        let footer =
            collectionView.dequeueReusableSupplementaryView(
                ofKind: kind, withReuseIdentifier: BookshelfFolderStatusView.reuseIdentifier, for: indexPath
            )
            as! BookshelfFolderStatusView
        configure(footer)
        return footer
    }

    func collectionView(
        _: UICollectionView, layout _: UICollectionViewLayout, referenceSizeForFooterInSection _: Int
    ) -> CGSize {
        guard let visibleStatus else { return .zero }
        let message: String?
        let canRetry: Bool
        switch visibleStatus {
        case .failure(let failure):
            message = failure
            canRetry = true
        case .loaded:
            message = BookshelfEmptyState.message
            canRetry = false
        default:
            message = nil
            canRetry = false
        }
        let height = BookshelfFolderStatusView.preferredHeight(
            width: contentWidth, message: message, canRetry: canRetry,
            contentSizeCategory: traitCollection.preferredContentSizeCategory)
        let insets = collectionView.adjustedContentInset
        let viewportHeight = max(1, collectionView.bounds.height - insets.top - insets.bottom)
        return CGSize(width: contentWidth, height: items.isEmpty ? max(viewportHeight, height) : height)
    }
}

private final class BookshelfFolderStatusView: UICollectionReusableView {
    static let reuseIdentifier = "BookshelfFolderStatusView"
    var onRetry: (() -> Void)?

    private let stack = UIStackView()
    private let label = UILabel()
    private let indicator = UIActivityIndicatorView(style: .medium)
    private let retryButton = UIButton(type: .system)

    static func preferredHeight(
        width: CGFloat, message: String?, canRetry: Bool, contentSizeCategory: UIContentSizeCategory
    ) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: contentSizeCategory)
        let font =
            canRetry
            ? UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
            : BookshelfEmptyState.font(compatibleWith: traits)
        let textHeight =
            message.map {
                ($0 as NSString).boundingRect(
                    with: CGSize(width: max(1, width - 32), height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font],
                    context: nil
                ).height
            } ?? 20
        let buttonHeight = canRetry ? max(44, ceil(font.lineHeight) + 16) + 8 : 0
        return ceil(textHeight) + buttonHeight + 32
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = AndroidReplicaTheme.background
        label.textColor = AndroidReplicaTheme.primaryText
        label.font = BookshelfEmptyState.font(compatibleWith: traitCollection)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.textAlignment = .center
        indicator.color = AndroidReplicaTheme.accent
        indicator.hidesWhenStopped = true
        indicator.accessibilityIdentifier = "bookshelf.folder.loading"
        indicator.isAccessibilityElement = true
        indicator.accessibilityLabel = L10n.Bookshelf.loading
        retryButton.setTitle(L10n.Common.retry, for: .normal)
        retryButton.setImage(UIImage(systemName: "arrow.clockwise"), for: .normal)
        retryButton.titleLabel?.font = .preferredFont(forTextStyle: .body)
        retryButton.titleLabel?.adjustsFontForContentSizeCategory = true
        retryButton.tintColor = AndroidReplicaTheme.accent
        retryButton.accessibilityIdentifier = "bookshelf.folder.retry"
        retryButton.addTarget(self, action: #selector(retry), for: .touchUpInside)
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        for item in [indicator, label, retryButton] { stack.addArrangedSubview(item) }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let buttonHeight = retryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        buttonHeight.priority = .init(999)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -16),
            label.widthAnchor.constraint(equalTo: stack.widthAnchor),
            retryButton.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            buttonHeight,
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onRetry = nil
        indicator.stopAnimating()
    }

    func configure(message: String?, loading: Bool, canRetry: Bool) {
        label.text = message
        label.textColor = canRetry ? AndroidReplicaTheme.secondaryText : AndroidReplicaTheme.primaryText
        label.font =
            canRetry
            ? .preferredFont(forTextStyle: .body)
            : BookshelfEmptyState.font(compatibleWith: traitCollection)
        label.isHidden = message == nil
        label.accessibilityIdentifier = canRetry ? "bookshelf.folder.failure" : "bookshelf.folder.empty"
        indicator.isHidden = !loading
        if loading { indicator.startAnimating() } else { indicator.stopAnimating() }
        retryButton.isHidden = !canRetry
    }

    @objc private func retry() { onRetry?() }
}
