import UIKit
import shared

final class AndroidReplicaBookshelfCell: UICollectionViewCell {
    static let reuseIdentifier = "AndroidReplicaBookshelfCell"

    static func preferredSize(
        width: CGFloat, isGrid: Bool, contentSizeCategory: UIContentSizeCategory,
        displayScale: CGFloat = UIScreen.main.scale, unreadCount: Int = 0, showsUnread: Bool = true,
        layoutDirection: UIUserInterfaceLayoutDirection = .leftToRight
    ) -> CGSize {
        let metrics = LayoutMetrics(contentSizeCategory: contentSizeCategory, displayScale: displayScale)
        let countText = showsUnread && unreadCount > 0 ? "\(unreadCount)" : nil
        let height: CGFloat
        if isGrid {
            height =
                metrics.gridInfoTop(width: width, countText: countText, layoutDirection: layoutDirection)
                + metrics.gridTitleHeight
        } else {
            let coverHeight = 16 + LayoutMetrics.listCoverHeight + 12
            let textHeight =
                12 + metrics.listTitleHeight(width: width, countText: countText, layoutDirection: layoutDirection)
                + metrics.metadataRowHeights.reduce(0, +)
                + metrics.minimumListSpacing * 5 + 8
            height = max(coverHeight, textHeight)
        }
        return CGSize(width: width, height: ceil(height))
    }

    var onOpenDetails: (() -> Void)? {
        didSet {
            accessibilityCustomActions =
                onOpenDetails == nil
                ? nil
                : [
                    UIAccessibilityCustomAction(
                        name: "书籍详情", target: self, selector: #selector(openDetailsFromAccessibility(_:)))
                ]
        }
    }

    private let coverClipView = AndroidBookCoverClipView()
    private let defaultCoverView = AndroidDefaultBookCoverView()
    private let coverView = UIImageView()
    private let infoStack = UIStackView()
    private let titleRow = UIView()
    private let nameLabel = UILabel()
    private let authorIconView = UIImageView()
    private let authorLabel = BookshelfEndPaddedLabel()
    private let latestUpdateTimeLabel = BookshelfEndPaddedLabel()
    private let progressIconView = UIImageView()
    private let progressLabel = UILabel()
    private let latestIconView = UIImageView()
    // tv_last alone retains TextView's default includeFontPadding.
    private let latestLabel = AndroidExploreTextLabel()
    private let statusView = UIView()
    private let badgeLabel = BookshelfUnreadBadgeLabel()
    private let loadingIndicator = BookshelfBookStatusLoadingView()
    private let feedbackView = BookshelfItemFeedbackView()
    private var metadataRows: [UIView] = []
    private var listSpacingViews: [UIView] = []
    private var minimumListSpacingConstraint: NSLayoutConstraint?
    private var metadataHeightConstraints: [NSLayoutConstraint] = []
    private var iconSizeConstraints: [NSLayoutConstraint] = []
    private var authorMinimumWidthConstraint: NSLayoutConstraint?
    private var gridConstraints: [NSLayoutConstraint] = []
    private var listConstraints: [NSLayoutConstraint] = []
    private lazy var listCoverLeftConstraint = coverClipView.leftAnchor.constraint(equalTo: contentView.leftAnchor)
    private lazy var listInfoRightConstraint = infoStack.rightAnchor.constraint(equalTo: contentView.rightAnchor)
    private lazy var listStatusRightConstraint = statusView.rightAnchor.constraint(equalTo: contentView.rightAnchor)
    private lazy var gridInfoTopConstraint = infoStack.topAnchor.constraint(equalTo: coverClipView.bottomAnchor, constant: 14)
    private lazy var titleHeightConstraint = titleRow.heightAnchor.constraint(equalToConstant: 0)
    private lazy var statusWidthConstraint = statusView.widthAnchor.constraint(equalToConstant: 22)
    private lazy var statusHeightConstraint = statusView.heightAnchor.constraint(equalToConstant: 22)
    private lazy var spinnerWidthConstraint = loadingIndicator.widthAnchor.constraint(equalToConstant: 22)
    private lazy var spinnerHeightConstraint = loadingIndicator.heightAnchor.constraint(equalToConstant: 22)
    private var isGridLayout: Bool?
    private var canRefresh = false
    private var showsUnread = false
    private var unreadCount = 0
    private var hasFreshChapters = false
    private var isRefreshing = false
    private var accessibilityMetadata: [String] = []
    private var latestUpdateTimestamp: Int64?
    private var imageTask: Task<Void, Never>?
    private var coverRequestID: UUID?
    private var coverRequest: CoverRequest?
    private var feedbackObservations: [NSKeyValueObservation] = []
    private var appliedLayoutDirection: UIUserInterfaceLayoutDirection?

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureViews()
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshPalette), name: .androidReplicaThemeDidChange, object: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    deinit {
        imageTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted, canShowPressedFeedback else {
                clearPressedFeedback()
                return
            }
            feedbackView.isHidden = false
            observePressedAvailability()
        }
    }

    override var isUserInteractionEnabled: Bool {
        didSet {
            if !isUserInteractionEnabled { clearPressedFeedback() }
        }
    }

    override var isHidden: Bool {
        didSet {
            if isHidden { clearPressedFeedback() }
        }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow !== window { clearPressedFeedback() }
        super.willMove(toWindow: newWindow)
    }

    override func willMove(toSuperview newSuperview: UIView?) {
        if newSuperview !== superview { clearPressedFeedback() }
        super.willMove(toSuperview: newSuperview)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        clearPressedFeedback()
        imageTask?.cancel()
        imageTask = nil
        coverRequestID = nil
        coverRequest = nil
        defaultCoverView.onLoadingPolicyChange = nil
        coverView.image = nil
        defaultCoverView.configure(name: "", author: "")
        defaultCoverView.isHidden = false
        for label in [nameLabel, authorLabel, latestUpdateTimeLabel, progressLabel, latestLabel] {
            label.text = nil
        }
        latestUpdateTimeLabel.isHidden = true
        onOpenDetails = nil
        canRefresh = false
        showsUnread = false
        unreadCount = 0
        hasFreshChapters = false
        accessibilityMetadata = []
        latestUpdateTimestamp = nil
        setRefreshing(false)
        accessibilityLabel = nil
        accessibilityValue = nil
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateStatusAppearance()
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory
            || previousTraitCollection?.displayScale != traitCollection.displayScale
        {
            updateTypography()
        }
        updateDirectionalMargins()
    }

    override func layoutSubviews() {
        updateDirectionalMargins()
        updateStatusSize()
        super.layoutSubviews()
        feedbackView.frame = contentView.bounds
        loadingIndicator.updateAnimationVisibility()
    }

    private var canShowPressedFeedback: Bool {
        guard window != nil else { return false }
        var ancestor: UIView? = self
        while let view = ancestor {
            guard view.isUserInteractionEnabled, !view.isHidden, view.alpha > 0.01 else { return false }
            ancestor = view.superview
        }
        return true
    }

    private func clearPressedFeedback() {
        feedbackObservations.removeAll()
        // super.prepareForReuse already resets highlight; also cover detach/disable/rebind.
        super.isHighlighted = false
        feedbackView.isHidden = true
    }

    private func observePressedAvailability() {
        guard feedbackObservations.isEmpty else { return }
        var ancestor: UIView? = self
        while let view = ancestor {
            let changed: () -> Void = { [weak self] in
                guard let self, !self.canShowPressedFeedback else { return }
                self.clearPressedFeedback()
            }
            feedbackObservations.append(view.observe(\.isUserInteractionEnabled, options: [.new]) { _, _ in changed() })
            feedbackObservations.append(view.observe(\.isHidden, options: [.new]) { _, _ in changed() })
            feedbackObservations.append(view.observe(\.alpha, options: [.new]) { _, _ in changed() })
            ancestor = view.superview
        }
    }

    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        loadingIndicator.updateAnimationVisibility()
    }

    private func configureViews() {
        contentView.backgroundColor = AndroidReplicaTheme.background
        isAccessibilityElement = true
        accessibilityIdentifier = UIIdentifiers.Bookshelf.bookCell
        accessibilityTraits = .button
        contentView.isAccessibilityElement = false

        coverView.backgroundColor = .clear
        coverView.contentMode = .scaleAspectFill
        coverView.clipsToBounds = true

        nameLabel.textColor = AndroidReplicaTheme.primaryText
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.adjustsFontSizeToFitWidth = false
        nameLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        for label in [authorLabel, latestUpdateTimeLabel, progressLabel, latestLabel] {
            label.textColor = AndroidReplicaTheme.summaryText
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            label.adjustsFontSizeToFitWidth = false
        }
        latestUpdateTimeLabel.textAlignment = .natural
        latestUpdateTimeLabel.setContentHuggingPriority(.required, for: .horizontal)
        authorLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // BadgeView reads the default raw 8px, then passes that number through dip2Px.
        // Neither bookshelf XML overrides radius, so its resulting logical radius is 8dp.
        badgeLabel.layer.cornerRadius = 8
        badgeLabel.layer.masksToBounds = true
        badgeLabel.textAlignment = .center
        badgeLabel.numberOfLines = 0
        badgeLabel.lineBreakMode = .byCharWrapping
        badgeLabel.adjustsFontSizeToFitWidth = false
        badgeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        badgeLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        badgeLabel.isHidden = true
        updateStatusAppearance()

        configureMetaIcon(authorIconView, assetName: "BookDetailAndroidAuthor")
        configureMetaIcon(progressIconView, assetName: "BookshelfAndroidHistory")
        configureMetaIcon(latestIconView, assetName: "BookDetailAndroidBookLast")

        infoStack.axis = .vertical
        infoStack.alignment = .fill
        infoStack.distribution = .fill
        infoStack.spacing = 0
        for item in [coverClipView, infoStack, statusView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            item.isAccessibilityElement = false
            contentView.addSubview(item)
        }
        for item in [defaultCoverView, coverView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            item.isAccessibilityElement = false
            coverClipView.addSubview(item)
        }
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.isAccessibilityElement = false
        titleRow.addSubview(nameLabel)
        metadataRows = [
            makeMetadataRow(icon: authorIconView, label: authorLabel, trailingLabel: latestUpdateTimeLabel),
            makeMetadataRow(icon: progressIconView, label: progressLabel),
            makeMetadataRow(icon: latestIconView, label: latestLabel),
        ]
        // ConstraintLayout's default spread chain includes equal gaps before and after its four text rows.
        listSpacingViews = (0..<5).map { _ in UIView() }
        for (index, row) in ([titleRow] + metadataRows).enumerated() {
            infoStack.addArrangedSubview(listSpacingViews[index])
            infoStack.addArrangedSubview(row)
        }
        infoStack.addArrangedSubview(listSpacingViews[4])
        let minimumSpacing = listSpacingViews[0].heightAnchor.constraint(greaterThanOrEqualToConstant: 0)
        minimumListSpacingConstraint = minimumSpacing
        NSLayoutConstraint.activate(
            [minimumSpacing]
                + listSpacingViews.dropFirst().map {
                    $0.heightAnchor.constraint(equalTo: listSpacingViews[0].heightAnchor)
                })
        for item in [badgeLabel, loadingIndicator] {
            item.translatesAutoresizingMaskIntoConstraints = false
            item.isAccessibilityElement = false
            statusView.addSubview(item)
        }
        installConstraints()
        applyLayout(isGrid: true)
        contentView.addSubview(feedbackView)
    }

    func configure(book: Book, isGrid: Bool, preferences: AppUiPreferences?, isRefreshing: Bool = false) {
        if coverRequest?.bookURL != book.bookUrl { clearPressedFeedback() }
        applyLayout(isGrid: isGrid)
        accessibilityLabel = book.name
        nameLabel.text = isGrid ? book.name : singleLineText(book.name)
        authorLabel.text = singleLineText(book.author)
        progressLabel.text = singleLineText(book.durChapterTitle)
        latestLabel.text = singleLineText(book.latestChapterTitle)
        let supportsLatestUpdateTime = preferences?.bookGroupStyle != 1
        latestUpdateTimestamp =
            supportsLatestUpdateTime && preferences?.showLastUpdateTime == true && !book.isLocal
            ? book.latestChapterTime : nil
        latestUpdateTimeLabel.isHidden = isGrid || latestUpdateTimestamp == nil
        canRefresh = !book.isLocal
        showsUnread = preferences?.showUnread ?? true
        unreadCount = Int(book.unreadChapterCount)
        hasFreshChapters = book.lastCheckCount > 0

        accessibilityMetadata = []
        if !book.author.isEmpty {
            accessibilityMetadata.append("作者：\(book.author)")
        }
        if let chapter = book.durChapterTitle, !chapter.isEmpty {
            accessibilityMetadata.append("阅读章节：\(chapter)")
        }
        if let chapter = book.latestChapterTitle, !chapter.isEmpty {
            accessibilityMetadata.append("最新章节：\(chapter)")
        }
        setRefreshing(isRefreshing)
        loadCover(book)
    }

    // Refresh-only updates deliberately leave the cover request and bound metadata untouched.
    func setRefreshing(_ refreshing: Bool) {
        let isRefreshing = refreshing && canRefresh
        self.isRefreshing = isRefreshing
        badgeLabel.countText = showsUnread && unreadCount > 0 ? "\(unreadCount)" : nil
        badgeLabel.isHidden = isRefreshing || badgeLabel.countText == nil
        updateStatusAppearance()
        loadingIndicator.setRefreshing(isRefreshing)
        updateStatusSize()
        refreshLatestUpdateTime()
    }

    // Android's lastUpdateTime payload changes no cover, chapter text or refresh animation.
    func refreshLatestUpdateTime(now: Date = Date()) {
        let time = latestUpdateTimestamp.map { AppUI.Bookshelf.formattedLatestUpdateTime($0, now: now) }
        let visibleTime = latestUpdateTimeLabel.isHidden ? nil : time
        if latestUpdateTimeLabel.text != visibleTime { latestUpdateTimeLabel.text = visibleTime }

        var metadata = accessibilityMetadata
        if let time {
            metadata.append("最近更新：\(time)")
        }
        if showsUnread, unreadCount > 0 {
            metadata.append("未读章节：\(unreadCount)")
        }
        if isRefreshing {
            metadata.append("正在刷新")
        }
        accessibilityValue = metadata.isEmpty ? nil : metadata.joined(separator: "，")
    }

    private func makeMetadataRow(icon: UIImageView, label: UILabel, trailingLabel: UILabel? = nil) -> UIView {
        let row = UIView()
        let iconSlot = UIView()
        for item in [iconSlot, label] {
            item.translatesAutoresizingMaskIntoConstraints = false
            item.isAccessibilityElement = false
            row.addSubview(item)
        }
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.isAccessibilityElement = false
        iconSlot.addSubview(icon)
        let height = row.heightAnchor.constraint(equalToConstant: 18)
        // Hidden arranged rows collapse in grid mode without conflicting with UIStackView.
        height.priority = .init(999)
        metadataHeightConstraints.append(height)
        let iconWidth = iconSlot.widthAnchor.constraint(equalToConstant: 18)
        let iconHeight = iconSlot.heightAnchor.constraint(equalToConstant: 18)
        iconSizeConstraints.append(contentsOf: [iconWidth, iconHeight])
        var constraints = [
            height, iconWidth, iconHeight,
            iconSlot.leftAnchor.constraint(equalTo: row.leftAnchor),
            iconSlot.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            // item_bookshelf_list.xml: desc_icon_size = 18sp, horizontal padding = 2dp.
            icon.leftAnchor.constraint(equalTo: iconSlot.leftAnchor, constant: 2),
            icon.rightAnchor.constraint(equalTo: iconSlot.rightAnchor, constant: -2),
            icon.topAnchor.constraint(equalTo: iconSlot.topAnchor),
            icon.bottomAnchor.constraint(equalTo: iconSlot.bottomAnchor),
            label.leftAnchor.constraint(equalTo: iconSlot.rightAnchor),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 0),
        ]
        if let trailingLabel {
            let minimumAuthorWidth = label.widthAnchor.constraint(greaterThanOrEqualToConstant: 0)
            minimumAuthorWidth.priority = .init(999)
            authorMinimumWidthConstraint = minimumAuthorWidth
            trailingLabel.translatesAutoresizingMaskIntoConstraints = false
            trailingLabel.isAccessibilityElement = false
            row.addSubview(trailingLabel)
            constraints.append(contentsOf: [
                minimumAuthorWidth,
                label.rightAnchor.constraint(equalTo: trailingLabel.leftAnchor),
                trailingLabel.rightAnchor.constraint(equalTo: row.rightAnchor),
                trailingLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                trailingLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 0),
            ])
        } else {
            constraints.append(label.rightAnchor.constraint(equalTo: row.rightAnchor))
        }
        NSLayoutConstraint.activate(constraints)
        return row
    }

    private func installConstraints() {
        NSLayoutConstraint.activate([
            coverView.leftAnchor.constraint(equalTo: coverClipView.leftAnchor),
            coverView.rightAnchor.constraint(equalTo: coverClipView.rightAnchor),
            coverView.topAnchor.constraint(equalTo: coverClipView.topAnchor),
            coverView.bottomAnchor.constraint(equalTo: coverClipView.bottomAnchor),
            defaultCoverView.leftAnchor.constraint(equalTo: coverClipView.leftAnchor),
            defaultCoverView.rightAnchor.constraint(equalTo: coverClipView.rightAnchor),
            defaultCoverView.topAnchor.constraint(equalTo: coverClipView.topAnchor),
            defaultCoverView.bottomAnchor.constraint(equalTo: coverClipView.bottomAnchor),
            nameLabel.topAnchor.constraint(equalTo: titleRow.topAnchor),
            nameLabel.bottomAnchor.constraint(lessThanOrEqualTo: titleRow.bottomAnchor),
            nameLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 0),
            titleHeightConstraint, statusWidthConstraint, statusHeightConstraint,
            spinnerWidthConstraint, spinnerHeightConstraint,
            // Both XMLs align loading to top/right, independently of the invisible badge's size.
            loadingIndicator.topAnchor.constraint(equalTo: statusView.topAnchor),
            loadingIndicator.rightAnchor.constraint(equalTo: statusView.rightAnchor),
        ])
        gridConstraints = [
            coverClipView.leftAnchor.constraint(equalTo: contentView.leftAnchor, constant: 16),
            coverClipView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            coverClipView.heightAnchor.constraint(
                equalTo: coverClipView.widthAnchor, multiplier: LayoutMetrics.coverAspectRatio),
            coverClipView.rightAnchor.constraint(equalTo: contentView.rightAnchor, constant: -16),
            gridInfoTopConstraint,
            infoStack.leftAnchor.constraint(equalTo: contentView.leftAnchor, constant: 8),
            infoStack.rightAnchor.constraint(equalTo: contentView.rightAnchor, constant: -8),
            infoStack.heightAnchor.constraint(equalTo: titleRow.heightAnchor),
            infoStack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
            nameLabel.leftAnchor.constraint(equalTo: titleRow.leftAnchor),
            nameLabel.rightAnchor.constraint(equalTo: titleRow.rightAnchor),
            statusView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            statusView.rightAnchor.constraint(equalTo: contentView.rightAnchor, constant: -8),
            badgeLabel.topAnchor.constraint(equalTo: statusView.topAnchor),
            badgeLabel.rightAnchor.constraint(equalTo: statusView.rightAnchor),
        ]
        listConstraints = [
            listCoverLeftConstraint,
            coverClipView.widthAnchor.constraint(equalToConstant: LayoutMetrics.listCoverWidth),
            coverClipView.heightAnchor.constraint(
                equalTo: coverClipView.widthAnchor, multiplier: LayoutMetrics.coverAspectRatio),
            coverClipView.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 16),
            coverClipView.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -12),
            coverClipView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor, constant: 2),
            infoStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            infoStack.leftAnchor.constraint(equalTo: coverClipView.rightAnchor, constant: 10),
            listInfoRightConstraint,
            infoStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            nameLabel.leftAnchor.constraint(equalTo: titleRow.leftAnchor, constant: 2),
            nameLabel.rightAnchor.constraint(equalTo: statusView.leftAnchor),
            nameLabel.bottomAnchor.constraint(lessThanOrEqualTo: titleRow.bottomAnchor, constant: -4),
            statusView.centerYAnchor.constraint(equalTo: titleRow.centerYAnchor),
            listStatusRightConstraint,
            badgeLabel.topAnchor.constraint(equalTo: statusView.topAnchor, constant: 5),
            badgeLabel.rightAnchor.constraint(equalTo: statusView.rightAnchor, constant: -5),
        ]
    }

    private func applyLayout(isGrid: Bool) {
        guard isGridLayout != isGrid else { return }
        if let previousIsGrid = isGridLayout {
            NSLayoutConstraint.deactivate(previousIsGrid ? gridConstraints : listConstraints)
        }
        isGridLayout = isGrid
        nameLabel.numberOfLines = isGrid ? 2 : 1
        nameLabel.textAlignment = isGrid ? .center : .natural
        for row in metadataRows { row.isHidden = isGrid }
        for spacer in listSpacingViews { spacer.isHidden = isGrid }
        NSLayoutConstraint.activate(isGrid ? gridConstraints : listConstraints)
        updateTypography()
    }

    private func updateTypography() {
        let metrics = LayoutMetrics(
            contentSizeCategory: traitCollection.preferredContentSizeCategory,
            displayScale: traitCollection.displayScale)
        let isGrid = isGridLayout ?? true
        nameLabel.font = isGrid ? metrics.gridTitleFont : metrics.listTitleFont
        for label in [authorLabel, latestUpdateTimeLabel, progressLabel, latestLabel] {
            label.font = metrics.metadataFont
        }
        badgeLabel.font = metrics.badgeFont
        badgeLabel.updateTextLayout()
        for (constraint, height) in zip(metadataHeightConstraints, metrics.metadataRowHeights) {
            constraint.constant = height
        }
        minimumListSpacingConstraint?.constant = isGrid ? 0 : metrics.minimumListSpacing
        for constraint in iconSizeConstraints { constraint.constant = metrics.metadataIconSize }
        authorMinimumWidthConstraint?.constant = ceil(metrics.metadataFont.pointSize) + 6
        spinnerWidthConstraint.constant = isGrid ? 22 : 26
        spinnerHeightConstraint.constant = isGrid ? 22 : 26
        updateStatusSize()
    }

    private func updateDirectionalMargins() {
        // Physical Left/Right constraints do not mirror. Only the XML's relative
        // margins resolve: cover marginStart and status marginEnd move off their anchors in RTL.
        let direction = effectiveUserInterfaceLayoutDirection
        let inset: CGFloat = direction == .rightToLeft ? 0 : 16
        listCoverLeftConstraint.constant = inset
        listInfoRightConstraint.constant = -inset
        listStatusRightConstraint.constant = -inset
        if appliedLayoutDirection != direction {
            appliedLayoutDirection = direction
            authorLabel.setNeedsDisplay()
            latestUpdateTimeLabel.setNeedsDisplay()
        }
    }

    private func updateStatusSize() {
        guard bounds.width > 0 else { return }
        let isGrid = isGridLayout ?? true
        let metrics = LayoutMetrics(
            contentSizeCategory: traitCollection.preferredContentSizeCategory,
            displayScale: traitCollection.displayScale)
        let direction = effectiveUserInterfaceLayoutDirection
        let countText = showsUnread && unreadCount > 0 ? "\(unreadCount)" : nil
        titleHeightConstraint.constant =
            isGrid
            ? metrics.gridTitleHeight
            : metrics.listTitleHeight(
                width: bounds.width, countText: countText, layoutDirection: direction)
        let coverBottom = 16 + max(0, bounds.width - 32) * LayoutMetrics.coverAspectRatio
        gridInfoTopConstraint.constant =
            metrics.gridInfoTop(
                width: bounds.width, countText: countText, layoutDirection: direction) - coverBottom
        badgeLabel.maximumWidth = metrics.badgeWidthLimit(width: bounds.width, isGrid: isGrid, layoutDirection: direction)
        let badgeSize = badgeLabel.intrinsicContentSize
        let margin: CGFloat = isGrid ? 0 : 10
        // BadgeView is INVISIBLE, never GONE, even with empty text. Only list loading is
        // GONE when stopped; grid loading keeps its 22dp measure. The 5dp margins are
        // on the list badge alone, not the 26dp loading view (FrameLayout max, not sum).
        let loadingSize: CGFloat = isGrid ? 22 : (isRefreshing ? 26 : 0)
        statusWidthConstraint.constant = max(loadingSize, badgeSize.width + margin)
        statusHeightConstraint.constant = max(loadingSize, badgeSize.height + margin)
    }

    private func updateStatusAppearance() {
        let background = hasFreshChapters ? AndroidReplicaTheme.accent : Self.inactiveBadgeColor
        let resolvedBackground = background.resolvedColor(with: traitCollection)
        badgeLabel.backgroundColor = resolvedBackground
        badgeLabel.textColor = Self.badgeTextColor(on: resolvedBackground)
    }

    @objc private func refreshPalette() {
        contentView.backgroundColor = AndroidReplicaTheme.background
        nameLabel.textColor = AndroidReplicaTheme.primaryText
        for label in [authorLabel, latestUpdateTimeLabel, progressLabel, latestLabel] {
            label.textColor = AndroidReplicaTheme.summaryText
        }
        for icon in [authorIconView, progressIconView, latestIconView] {
            icon.tintColor = AndroidReplicaTheme.summaryText
        }
        updateStatusAppearance()
        loadingIndicator.setNeedsDisplay()
    }

    private func singleLineText(_ text: String?) -> String? {
        // TextView's singleLine transformation preserves all text instead of stopping at a newline.
        text?.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: "\u{FEFF}")
    }

    private static func badgeTextColor(on color: UIColor) -> UIColor {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: nil) else { return .white }
        func linear(_ component: CGFloat) -> CGFloat {
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        // BadgeView -> ColorUtils.isColorLight: sRGB luminance >= 0.5, ignoring alpha.
        let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        return luminance >= 0.5 ? .black : .white
    }

    @objc private func openDetailsFromAccessibility(_: UIAccessibilityCustomAction) -> Bool {
        guard let onOpenDetails else { return false }
        onOpenDetails()
        return true
    }

    private static let inactiveBadgeColor = UIColor { traits in
        let component: CGFloat = ReaderPaletteColor.isNightResource(traits: traits) ? 102.0 / 255.0 : 170.0 / 255.0
        return UIColor(white: component, alpha: component)
    }

    private func configureMetaIcon(_ imageView: UIImageView, assetName: String) {
        imageView.image = UIImage(named: assetName)?.withRenderingMode(.alwaysTemplate)
        imageView.tintColor = AndroidReplicaTheme.summaryText
        imageView.contentMode = .scaleAspectFit
    }

    private func loadCover(_ book: Book) {
        let request = CoverRequest(book: book)
        guard coverRequest != request else { return }
        imageTask?.cancel()
        let requestID = UUID()
        coverRequestID = requestID
        coverRequest = request
        defaultCoverView.onLoadingPolicyChange = { [weak self] in
            guard let self, self.coverRequestID == requestID else { return }
            self.loadCover(book)
        }
        coverView.image = nil
        defaultCoverView.configure(name: book.name, author: book.author)
        defaultCoverView.isHidden = false

        let path = book.displayCoverUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty, path != "use_default_cover" else {
            imageTask = nil
            return
        }
        imageTask = Task { @MainActor [weak self] in
            let image = await BookCoverImageLoader.loadDecodedCover(book: book)
            guard !Task.isCancelled, let self, self.coverRequestID == requestID, self.coverRequest == request else {
                return
            }
            self.imageTask = nil
            self.coverView.image = image
            self.defaultCoverView.isHidden = image != nil
        }
    }

    private struct CoverRequest: Equatable {
        let loaderCacheKey: String
        let loadingPolicy: String
        let bookURL: String
        let origin: String
        let name: String
        let author: String
        let coverURL: String?
        let customCoverURL: String?
        let variable: String?

        init(book: Book) {
            // Keep the loader's key plus rule inputs it currently omits; Book equality only compares bookUrl.
            loaderCacheKey = BookCoverImageLoader.coverCacheKey(for: book) as String
            loadingPolicy = CoverConfigurationLoadingPolicy().signature
            bookURL = book.bookUrl
            origin = book.origin
            name = book.name
            author = book.author
            coverURL = book.coverUrl
            customCoverURL = book.customCoverUrl
            variable = book.variable
        }
    }

    private struct LayoutMetrics {
        static let coverAspectRatio: CGFloat = 7.0 / 5.0
        static let listCoverWidth: CGFloat = 66
        // CoverImageView.onMeasure overrides the XML height with width * 7 / 5.
        static let listCoverHeight = listCoverWidth * coverAspectRatio

        let gridTitleFont: UIFont
        let listTitleFont: UIFont
        let metadataFont: UIFont
        let badgeFont: UIFont
        let metadataIconSize: CGFloat
        let latestFontPadding: UIEdgeInsets

        var gridTitleHeight: CGFloat { ceil(gridTitleFont.lineHeight * 2) }
        var metadataRowHeights: [CGFloat] {
            let naturalHeight = ceil(metadataFont.lineHeight)
            return [
                naturalHeight, naturalHeight,
                ceil(metadataFont.lineHeight + latestFontPadding.top + latestFontPadding.bottom),
            ]
        }
        var listTitleHeight: CGFloat { ceil(listTitleFont.lineHeight) + 4 }

        func badgeWidthLimit(
            width: CGFloat, isGrid: Bool, layoutDirection: UIUserInterfaceLayoutDirection
        ) -> CGFloat {
            if isGrid { return max(16, width - 16) }
            // Reserve one full-size title glyph, its 2dp padding and the badge's 5dp margins.
            let inset: CGFloat = layoutDirection == .rightToLeft ? 0 : 16
            let textWidth = width - inset - Self.listCoverWidth - 10 - inset - 2
            return max(16, textWidth - ceil(listTitleFont.pointSize) - 10)
        }

        private func badgeSize(
            width: CGFloat, isGrid: Bool, countText: String?, layoutDirection: UIUserInterfaceLayoutDirection
        ) -> CGSize {
            return BookshelfUnreadBadgeLabel.measurement(
                text: countText, font: badgeFont,
                maximumWidth: badgeWidthLimit(width: width, isGrid: isGrid, layoutDirection: layoutDirection))
        }

        func listTitleHeight(
            width: CGFloat, countText: String?, layoutDirection: UIUserInterfaceLayoutDirection
        ) -> CGFloat {
            let badgeHeight = badgeSize(
                width: width, isGrid: false, countText: countText, layoutDirection: layoutDirection
            ).height
            let singleLineHeight = max(16, ceil(badgeFont.lineHeight) + 2)
            return badgeHeight > singleLineHeight ? max(listTitleHeight, badgeHeight + 10) : listTitleHeight
        }

        func gridInfoTop(
            width: CGFloat, countText: String?, layoutDirection: UIUserInterfaceLayoutDirection
        ) -> CGFloat {
            let coverBottom = 16 + max(0, width - 32) * Self.coverAspectRatio
            let statusBottom =
                8
                + badgeSize(
                    width: width, isGrid: true, countText: countText, layoutDirection: layoutDirection
                ).height
            return max(coverBottom, statusBottom) + 14
        }

        var minimumListSpacing: CGFloat {
            // Keep the XML spread chain; at large sizes its gaps must also contain
            // the centered 18sp icons and the badge's two 5dp margins.
            let iconOverflow = max(0, (metadataIconSize - ceil(metadataFont.lineHeight)) / 2)
            let badgeHeight = max(16, ceil(badgeFont.lineHeight) + 2) + 10
            let statusOverflow = max(0, (max(26, badgeHeight) - listTitleHeight) / 2)
            return max(iconOverflow * 2, statusOverflow + iconOverflow)
        }

        init(contentSizeCategory: UIContentSizeCategory, displayScale: CGFloat) {
            let traits = UITraitCollection(preferredContentSizeCategory: contentSizeCategory)
            gridTitleFont = ReaderAndroidDefaultFont.scaledFont(
                size: 12, textStyle: .caption1, compatibleWith: traits)
            listTitleFont = ReaderAndroidDefaultFont.scaledFont(
                size: 16, textStyle: .body, compatibleWith: traits)
            metadataFont = ReaderAndroidDefaultFont.scaledFont(
                size: 13, textStyle: .caption1, compatibleWith: traits)
            badgeFont = ReaderAndroidDefaultFont.scaledFont(
                size: 11, textStyle: .caption2, compatibleWith: traits)
            metadataIconSize = ceil(UIFontMetrics(forTextStyle: .caption1).scaledValue(for: 18, compatibleWith: traits))
            latestFontPadding = AndroidExploreTextMetrics.padding(font: metadataFont, scale: displayScale)
        }
    }
}

private final class BookshelfUnreadBadgeLabel: UILabel {
    var countText: String? {
        didSet { updateTextLayout() }
    }

    var maximumWidth: CGFloat = .greatestFiniteMagnitude {
        didSet {
            if maximumWidth != oldValue { updateTextLayout() }
        }
    }

    override var intrinsicContentSize: CGSize {
        Self.measurement(text: countText, font: font, maximumWidth: maximumWidth)
    }

    func updateTextLayout() {
        // Keep UILabel.text as the real number; wrapping belongs to measurement/drawing.
        text = countText
        invalidateIntrinsicContentSize()
        setNeedsDisplay()
    }

    static func measurement(text: String?, font: UIFont, maximumWidth: CGFloat) -> CGSize {
        let naturalWidth = ceil(((text ?? "") as NSString).size(withAttributes: [.font: font]).width) + 10
        let lineHeight = ceil(font.lineHeight)
        let limit = max(16, maximumWidth)
        guard let text, naturalWidth > limit else {
            return CGSize(width: max(16, naturalWidth), height: max(16, lineHeight + 2))
        }

        // BadgeView is wrap_content without singleLine. Keep the actual digits and sp
        // size, wrapping only at the narrow/large-type boundary instead of overflowing
        // into another cell or consuming the list title's entire width.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: max(1, limit - 10), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font, .paragraphStyle: paragraph], context: nil)
        // Retain the measured width so UILabel wraps at precisely the same boundary.
        return CGSize(width: limit, height: max(16, ceil(max(lineHeight, bounds.height)) + 2))
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.insetBy(dx: 5, dy: 1))
    }
}

private final class BookshelfEndPaddedLabel: UILabel {
    private var endPadding: UIEdgeInsets {
        effectiveUserInterfaceLayoutDirection == .rightToLeft
            ? UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
            : UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 6)
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: max(0, size.width) + 6, height: size.height)
    }

    override func drawText(in rect: CGRect) {
        let padding = endPadding
        super.drawText(
            in: CGRect(
                x: rect.minX + min(padding.left, rect.width), y: rect.minY,
                width: max(0, rect.width - 6), height: rect.height))
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.layoutDirection != traitCollection.layoutDirection {
            setNeedsDisplay()
        }
    }
}
