import UIKit
import shared

final class AndroidReplicaBookshelfCell: UICollectionViewCell {
    static let reuseIdentifier = "AndroidReplicaBookshelfCell"

    static func preferredSize(
        width: CGFloat, isGrid: Bool, contentSizeCategory: UIContentSizeCategory,
        displayScale: CGFloat = UIScreen.main.scale
    ) -> CGSize {
        let metrics = LayoutMetrics(contentSizeCategory: contentSizeCategory, displayScale: displayScale)
        let height: CGFloat
        if isGrid {
            height = 16 + max(0, width - 32) * LayoutMetrics.coverAspectRatio + 14 + metrics.gridTitleHeight
        } else {
            let coverHeight = 16 + LayoutMetrics.listCoverHeight + 12
            let textHeight =
                12 + metrics.listTitleHeight + metrics.metadataRowHeights.reduce(0, +)
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

    private let defaultCoverView = AndroidDefaultBookCoverView()
    private let coverView = UIImageView()
    private let infoStack = UIStackView()
    private let titleRow = UIView()
    private let nameLabel = UILabel()
    private let authorIconView = UIImageView()
    private let authorLabel = UILabel()
    private let latestUpdateTimeLabel = UILabel()
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
    private var gridConstraints: [NSLayoutConstraint] = []
    private var listConstraints: [NSLayoutConstraint] = []
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
        didSet { feedbackView.isHidden = !isHighlighted }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
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
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        feedbackView.frame = contentView.bounds
        loadingIndicator.updateAnimationVisibility()
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
        coverView.layer.cornerRadius = 2

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
        badgeLabel.isHidden = true
        updateStatusAppearance()

        configureMetaIcon(authorIconView, assetName: "BookDetailAndroidAuthor")
        configureMetaIcon(progressIconView, assetName: "BookshelfAndroidHistory")
        configureMetaIcon(latestIconView, assetName: "BookDetailAndroidBookLast")

        infoStack.axis = .vertical
        infoStack.alignment = .fill
        infoStack.distribution = .fill
        infoStack.spacing = 0
        for item in [defaultCoverView, coverView, infoStack, statusView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            item.isAccessibilityElement = false
            contentView.addSubview(item)
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
        badgeLabel.text = showsUnread && unreadCount > 0 ? "\(unreadCount)" : nil
        badgeLabel.isHidden = isRefreshing || badgeLabel.text == nil
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
            iconSlot.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            iconSlot.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            // item_bookshelf_list.xml: desc_icon_size = 18sp, horizontal padding = 2dp.
            icon.leadingAnchor.constraint(equalTo: iconSlot.leadingAnchor, constant: 2),
            icon.trailingAnchor.constraint(equalTo: iconSlot.trailingAnchor, constant: -2),
            icon.topAnchor.constraint(equalTo: iconSlot.topAnchor),
            icon.bottomAnchor.constraint(equalTo: iconSlot.bottomAnchor),
            label.leadingAnchor.constraint(equalTo: iconSlot.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 0),
        ]
        if let trailingLabel {
            trailingLabel.translatesAutoresizingMaskIntoConstraints = false
            trailingLabel.isAccessibilityElement = false
            row.addSubview(trailingLabel)
            constraints.append(contentsOf: [
                label.trailingAnchor.constraint(equalTo: trailingLabel.leadingAnchor, constant: -6),
                trailingLabel.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -6),
                trailingLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                trailingLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 0),
            ])
        } else {
            constraints.append(label.trailingAnchor.constraint(equalTo: row.trailingAnchor))
        }
        NSLayoutConstraint.activate(constraints)
        return row
    }

    private func installConstraints() {
        NSLayoutConstraint.activate([
            coverView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            defaultCoverView.leadingAnchor.constraint(equalTo: coverView.leadingAnchor),
            defaultCoverView.trailingAnchor.constraint(equalTo: coverView.trailingAnchor),
            defaultCoverView.topAnchor.constraint(equalTo: coverView.topAnchor),
            defaultCoverView.bottomAnchor.constraint(equalTo: coverView.bottomAnchor),
            nameLabel.topAnchor.constraint(equalTo: titleRow.topAnchor),
            nameLabel.bottomAnchor.constraint(lessThanOrEqualTo: titleRow.bottomAnchor),
            nameLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 0),
            titleHeightConstraint, statusWidthConstraint, statusHeightConstraint,
            spinnerWidthConstraint, spinnerHeightConstraint,
            // Both XMLs align loading to top/right, independently of the invisible badge's size.
            loadingIndicator.topAnchor.constraint(equalTo: statusView.topAnchor),
            loadingIndicator.trailingAnchor.constraint(equalTo: statusView.trailingAnchor),
        ])
        gridConstraints = [
            coverView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            coverView.heightAnchor.constraint(
                equalTo: coverView.widthAnchor, multiplier: LayoutMetrics.coverAspectRatio),
            coverView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            infoStack.topAnchor.constraint(equalTo: coverView.bottomAnchor, constant: 14),
            infoStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            infoStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            infoStack.heightAnchor.constraint(equalTo: titleRow.heightAnchor),
            infoStack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: titleRow.leadingAnchor),
            nameLabel.trailingAnchor.constraint(equalTo: titleRow.trailingAnchor),
            statusView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            statusView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            badgeLabel.topAnchor.constraint(equalTo: statusView.topAnchor),
            badgeLabel.trailingAnchor.constraint(equalTo: statusView.trailingAnchor),
        ]
        listConstraints = [
            coverView.widthAnchor.constraint(equalToConstant: LayoutMetrics.listCoverWidth),
            coverView.heightAnchor.constraint(
                equalTo: coverView.widthAnchor, multiplier: LayoutMetrics.coverAspectRatio),
            coverView.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 16),
            coverView.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -12),
            coverView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor, constant: 2),
            infoStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            infoStack.leadingAnchor.constraint(equalTo: coverView.trailingAnchor, constant: 10),
            infoStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            infoStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            nameLabel.leadingAnchor.constraint(equalTo: titleRow.leadingAnchor, constant: 2),
            nameLabel.trailingAnchor.constraint(equalTo: statusView.leadingAnchor),
            nameLabel.bottomAnchor.constraint(lessThanOrEqualTo: titleRow.bottomAnchor, constant: -4),
            statusView.centerYAnchor.constraint(equalTo: titleRow.centerYAnchor),
            statusView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            badgeLabel.topAnchor.constraint(equalTo: statusView.topAnchor, constant: 5),
            badgeLabel.trailingAnchor.constraint(equalTo: statusView.trailingAnchor, constant: -5),
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
        badgeLabel.invalidateIntrinsicContentSize()
        titleHeightConstraint.constant = isGrid ? metrics.gridTitleHeight : metrics.listTitleHeight
        for (constraint, height) in zip(metadataHeightConstraints, metrics.metadataRowHeights) {
            constraint.constant = height
        }
        minimumListSpacingConstraint?.constant = isGrid ? 0 : metrics.minimumListSpacing
        for constraint in iconSizeConstraints { constraint.constant = metrics.metadataIconSize }
        spinnerWidthConstraint.constant = isGrid ? 22 : 26
        spinnerHeightConstraint.constant = isGrid ? 22 : 26
        updateStatusSize()
    }

    private func updateStatusSize() {
        let isGrid = isGridLayout ?? true
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
        defaultCoverView.onLoadingPolicyChange = { [weak self] in self?.loadCover(book) }
        let request = CoverRequest(book: book)
        guard coverRequest != request else { return }
        imageTask?.cancel()
        let requestID = UUID()
        coverRequestID = requestID
        coverRequest = request
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
    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: max(16, ceil(size.width) + 10), height: max(16, ceil(font.lineHeight) + 2))
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.insetBy(dx: 5, dy: 1))
    }
}
