import UIKit

final class AndroidReplicaBookDetailContentView: UIView, UIScrollViewDelegate {
    enum CatalogState: Equatable {
        case ready, loading, failed
    }

    struct Snapshot {
        var name: String
        var author: String? = nil
        var kind: String? = nil
        var wordCount: String? = nil
        var intro: String? = nil
        var originName: String? = nil
        // Retained for existing snapshot producers; Android shows the reading position in tv_toc.
        var readingProgress: String? = nil
        var chapterCount: Int = 0
        var latestChapter: String? = nil
        var catalogState: CatalogState = .ready
        var currentChapterTitle: String? = nil
        var groupName: String? = nil
        var showsCatalog: Bool = true
    }

    let coverImageView: UIImageView = BookDetailCoverImageView(frame: .zero)
    let actionColumnGuide = UILayoutGuide()

    var reservedActionBarHeight: CGFloat = 50 {
        didSet {
            updateActionBarReservation()
            needsScrollRestoration = true
            setNeedsLayout()
        }
    }

    var onTitleTap: (() -> Void)?
    var onAuthorTap: (() -> Void)?
    var onTocTap: (() -> Void)?
    var onSourceTap: (() -> Void)?
    var onSourceChangeTap: (() -> Void)?
    var onGroupTap: (() -> Void)?
    var onCoverTap: (() -> Void)?
    var onCoverLongPress: (() -> Void)?
    var onRefresh: (() -> Void)? {
        didSet { updateRefreshAvailability() }
    }

    var isRefreshEnabled = false {
        didSet { updateRefreshAvailability() }
    }

    var isCoverEnabled = false {
        didSet {
            coverImageView.isUserInteractionEnabled = isCoverEnabled
            coverImageView.accessibilityTraits = isCoverEnabled ? [.image, .button] : [.image, .notEnabled]
        }
    }

    var isGroupEnabled = false {
        didSet {
            groupButton.isEnabled = isGroupEnabled
            groupButton.alpha = isGroupEnabled ? 1 : 0.45
        }
    }

    var isSourceEditEnabled: Bool = false {
        didSet { sourceButton.isEnabled = isSourceEditEnabled }
    }

    var isSourceChangeVisible: Bool = false {
        didSet { updateSourceChangeState() }
    }

    var isSourceChangeEnabled: Bool = false {
        didSet { updateSourceChangeState() }
    }

    var isTocEnabled = true {
        didSet { updateCatalogAvailability() }
    }

    private let primaryScrollView = UIScrollView()
    private let detailsScrollView = UIScrollView()
    private let refreshControl = UIRefreshControl()
    private var isRefreshInFlight = false
    private var didRefreshDuringDrag = false
    private let primaryStack = UIStackView()
    private let summaryView = UIView()
    private let summaryInfoStack = UIStackView()
    private let heroView = UIView()
    private let arcView = ArcBackgroundView()
    private let coverCardView = UIView()
    private let infoStack = UIStackView()
    private let headingStack = UIStackView()
    private let metadataStack = UIStackView()
    private let titleButton = AndroidReplicaBookDetailTextButton(
        fontSize: 18, textColor: AndroidReplicaTheme.primaryText, includesFontPadding: false)
    private let authorButton = AndroidReplicaBookDetailTextButton(
        fontSize: 13, textColor: AndroidReplicaBookDetailTypography.summaryText, includesFontPadding: false)
    private lazy var authorRow = AndroidReplicaBookDetailInfoRow(icon: .author, content: authorButton)
    private let tagStack = UIStackView()
    private let sourceButton = AndroidReplicaBookDetailTextButton(
        fontSize: 13, textColor: AndroidReplicaBookDetailTypography.summaryText, includesFontPadding: false)
    private let sourceContentView = UIView()
    private let sourceChangeButton = AndroidReplicaBookDetailTextButton(
        fontSize: 13, textColor: .white, accentBackground: true)
    private var sourceButtonFullWidthConstraint: NSLayoutConstraint?
    private var sourceButtonWithActionConstraint: NSLayoutConstraint?
    private var sourceActionHeightConstraints: [NSLayoutConstraint] = []
    private let latestLabel = AndroidReplicaBookDetailMetadataLabel()
    private let groupLabel = AndroidReplicaBookDetailMetadataLabel()
    private let groupButton = AndroidReplicaBookDetailTextButton(
        fontSize: 13, textColor: .white, accentBackground: true)
    private let tocLabel = AndroidReplicaBookDetailMetadataLabel()
    private let tocButton = AndroidReplicaBookDetailTextButton(
        fontSize: 13, textColor: .white, accentBackground: true)
    private let introTextView = BookDetailIntroTextView()
    private var displayedTags: [String] = []
    private var tagBadges: [TagBadge] = []
    private var unusedTagBadges: [TagBadge] = []
    private var showsCatalog = true
    private var usesColumns = false
    private var portraitConstraints: [NSLayoutConstraint] = []
    private var columnConstraints: [NSLayoutConstraint] = []
    private var primaryBottomConstraint: NSLayoutConstraint?
    private var detailsBottomConstraint: NSLayoutConstraint?
    private var heroTopConstraint: NSLayoutConstraint?
    private var heroHeightConstraint: NSLayoutConstraint?
    private var arcTopConstraint: NSLayoutConstraint?
    private var coverWidthConstraint: NSLayoutConstraint?
    private var coverHeightConstraint: NSLayoutConstraint?
    private var needsScrollRestoration = true
    private var isRestoringScrollPositions = false
    private var portraitPosition = ScrollPosition()
    private var summaryPosition = ScrollPosition()
    private var detailsPosition = ScrollPosition()
    private var primaryViewportSize = CGSize.zero
    private var primaryContentSize = CGSize.zero
    private var detailsViewportSize = CGSize.zero
    private var detailsContentSize = CGSize.zero

    private struct ScrollPosition {
        var offsetY: CGFloat = 0
        var anchor: UIView? = nil
        var anchorOffset: CGFloat = 0
    }

    private struct TagBadge {
        let view: UIView
        let label: UILabel
    }

    private lazy var titleRow = HorizontalScrollRow(
        content: titleButton,
        height: ceil(AndroidReplicaBookDetailTypography.font(size: 18, compatibleWith: traitCollection).lineHeight)
    )
    private lazy var tagsRow = HorizontalScrollRow(
        content: tagStack,
        height: tagLineHeight
    )
    private lazy var latestRow = AndroidReplicaBookDetailInfoRow(
        icon: .last, content: latestLabel
    )
    private lazy var sourceRow = AndroidReplicaBookDetailInfoRow(
        icon: .web, content: sourceContentView, contentTrailingInset: 0
    )
    private lazy var groupRow = AndroidReplicaBookDetailInfoRow(
        icon: .groups, content: groupLabel, action: groupButton
    )
    private lazy var tocRow = AndroidReplicaBookDetailInfoRow(
        icon: .folder, content: tocLabel, action: tocButton
    )

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear
        isAccessibilityElement = false
        configureCover()
        configureHeading()
        configureMetadata()
        configureLayout()
        updateTypography()
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshPalette), name: .androidReplicaThemeDidChange, object: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateRefreshAvailability()
        setNeedsLayout()
    }

    // Request state only: Android stops the pull animation before refreshBook(). Clear on completion/cancellation.
    func setRefreshing(_ isRefreshing: Bool) {
        isRefreshInFlight = isRefreshing
        refreshControl.endRefreshing()
        updateRefreshAvailability()
    }

    func setUsesColumns(_ usesColumns: Bool) {
        guard self.usesColumns != usesColumns else { return }
        if !needsScrollRestoration {
            saveScrollPositions()
        }
        needsScrollRestoration = true
        NSLayoutConstraint.deactivate(portraitConstraints + columnConstraints)
        self.usesColumns = usesColumns
        applyLayoutMode()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        isRestoringScrollPositions = true
        defer { isRestoringScrollPositions = false }
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        primaryScrollView.layoutIfNeeded()
        detailsScrollView.layoutIfNeeded()
        primaryStack.layoutIfNeeded()
        infoStack.layoutIfNeeded()
        summaryInfoStack.layoutIfNeeded()
        metadataStack.layoutIfNeeded()
        // TextKit can resize the intro while the stacks lay out; cache the settled scroll geometry.
        primaryScrollView.layoutIfNeeded()
        detailsScrollView.layoutIfNeeded()

        if needsScrollRestoration || primaryViewportSize != primaryScrollView.bounds.size
            || primaryContentSize != primaryScrollView.contentSize
        {
            restore(usesColumns ? summaryPosition : portraitPosition, in: primaryScrollView)
        }
        if usesColumns,
            needsScrollRestoration || detailsViewportSize != detailsScrollView.bounds.size
                || detailsContentSize != detailsScrollView.contentSize
        {
            restore(detailsPosition, in: detailsScrollView)
        }
        primaryViewportSize = primaryScrollView.bounds.size
        primaryContentSize = primaryScrollView.contentSize
        detailsViewportSize = detailsScrollView.bounds.size
        detailsContentSize = detailsScrollView.contentSize
        needsScrollRestoration = false
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory
                || previousTraitCollection?.displayScale != traitCollection.displayScale
        else { return }
        if !needsScrollRestoration {
            saveScrollPositions()
        }
        needsScrollRestoration = true
        updateTypography()
        setNeedsLayout()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !needsScrollRestoration, !isRestoringScrollPositions else { return }
        if scrollView === primaryScrollView,
            scrollView.bounds.size == primaryViewportSize, scrollView.contentSize == primaryContentSize
        {
            if usesColumns {
                summaryPosition = position(in: scrollView)
            } else {
                portraitPosition = position(in: scrollView)
            }
        } else if usesColumns, scrollView === detailsScrollView,
            scrollView.bounds.size == detailsViewportSize, scrollView.contentSize == detailsContentSize
        {
            detailsPosition = position(in: scrollView)
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        if scrollView === primaryScrollView {
            didRefreshDuringDrag = false
        }
    }

    func render(_ snapshot: Snapshot) {
        let name = singleLine(snapshot.name) ?? L10n.BookDetail.title
        if titleButton.title(for: .normal) != name {
            titleButton.setTitle(name, for: .normal)
            titleRow.resetOffset()
        }
        titleButton.accessibilityLabel = snapshot.name.nilIfEmpty ?? L10n.BookDetail.title

        let author = singleLine(snapshot.author) ?? L10n.BookDetail.unknownAuthor
        authorButton.setTitle("\(L10n.BookDetail.editBookAuthor)\u{FF1A}\(author)", for: .normal)
        authorButton.accessibilityLabel =
            "\(L10n.BookDetail.editBookAuthor)\u{FF1A}\(snapshot.author?.nilIfEmpty ?? L10n.BookDetail.unknownAuthor)"

        sourceButton.setTitle(
            String(
                format: L10n.BookDetail.sourceFormat,
                singleLine(snapshot.originName) ?? L10n.BookDetail.unknownSource
            ), for: .normal
        )
        sourceButton.accessibilityLabel = String(
            format: L10n.BookDetail.sourceFormat, snapshot.originName?.nilIfEmpty ?? L10n.BookDetail.unknownSource)

        let latest = singleLine(snapshot.latestChapter)
        let latestFormat = Bundle.main.localizedString(
            forKey: "book_detail.android_latest_format", value: "最新：%@", table: nil)
        latestLabel.text = String(format: latestFormat, latest ?? "")
        latestLabel.accessibilityLabel = String(format: latestFormat, snapshot.latestChapter ?? "")

        groupLabel.text = String(
            format: L10n.BookDetail.groupFormat,
            singleLine(snapshot.groupName) ?? L10n.BookDetail.groupFallbackRemote
        )
        groupLabel.accessibilityLabel = String(
            format: L10n.BookDetail.groupFormat, snapshot.groupName?.nilIfEmpty ?? L10n.BookDetail.groupFallbackRemote)

        let catalogText: String
        switch snapshot.catalogState {
        case .ready:
            catalogText =
                singleLine(snapshot.currentChapterTitle)
                ?? String(format: L10n.BookDetail.totalChapters, max(0, snapshot.chapterCount))
        case .loading:
            catalogText = L10n.Common.loadingTitle
        case .failed:
            catalogText = Bundle.main.localizedString(
                forKey: "book_detail.android_catalog_failed", value: "加载目录失败", table: nil)
        }
        tocLabel.text = String(format: L10n.BookDetail.tocFormat, catalogText)
        let rawCatalogText =
            snapshot.catalogState == .ready ? snapshot.currentChapterTitle?.nilIfEmpty ?? catalogText : catalogText
        tocLabel.accessibilityLabel = String(format: L10n.BookDetail.tocFormat, rawCatalogText)
        tocButton.setTitle(
            snapshot.catalogState == .failed ? L10n.BookDetail.refreshChapters : L10n.BookDetail.viewToc,
            for: .normal)
        showsCatalog = snapshot.showsCatalog
        updateCatalogAvailability()
        introTextView.render(snapshot.intro)
        renderTags(snapshot.kind, wordCount: snapshot.wordCount)
        setNeedsLayout()
    }

    private func configureCover() {
        coverCardView.backgroundColor = AndroidReplicaTheme.coverBackground
        coverCardView.layer.cornerRadius = 5
        coverCardView.layer.shadowColor = UIColor.black.cgColor
        coverCardView.layer.shadowOpacity = 0.24
        coverCardView.layer.shadowRadius = 8
        coverCardView.layer.shadowOffset = CGSize(width: 0, height: 3)

        coverImageView.contentMode = .scaleAspectFill
        coverImageView.clipsToBounds = true
        // CardView clips its child outline independently of CoverImageView's own path.
        coverImageView.layer.cornerRadius = 5
        coverImageView.backgroundColor = AndroidReplicaTheme.coverBackground
        coverImageView.isUserInteractionEnabled = isCoverEnabled
        coverImageView.isAccessibilityElement = true
        coverImageView.accessibilityLabel = "封面"
        coverImageView.accessibilityIdentifier = "bookDetail.cover"
        coverImageView.accessibilityTraits = [.image, .notEnabled]
        coverImageView.accessibilityCustomActions = [
            UIAccessibilityCustomAction(
                name: L10n.BookDetail.changeCoverSource, target: self,
                selector: #selector(accessibilityChangeCover)),
            UIAccessibilityCustomAction(
                name: "预览封面", target: self,
                selector: #selector(accessibilityPreviewCover)),
        ]
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleCoverLongPress(_:)))
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleCoverTap))
        tap.require(toFail: longPress)
        coverImageView.addGestureRecognizer(longPress)
        coverImageView.addGestureRecognizer(tap)
    }

    @objc private func handleCoverTap() {
        guard isCoverEnabled else { return }
        onCoverTap?()
    }

    @objc private func handleCoverLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard isCoverEnabled, gesture.state == .began else { return }
        onCoverLongPress?()
    }

    @objc private func accessibilityChangeCover() -> Bool {
        guard isCoverEnabled else { return false }
        onCoverTap?()
        return true
    }

    @objc private func accessibilityPreviewCover() -> Bool {
        guard isCoverEnabled else { return false }
        onCoverLongPress?()
        return true
    }

    private func configureHeading() {
        titleButton.contentHorizontalAlignment = .center
        titleButton.titleLabel?.lineBreakMode = .byClipping
        titleButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleButton.accessibilityIdentifier = UIIdentifiers.BookDetail.headerTitleAction
        titleButton.addTarget(self, action: #selector(handleTitleTap), for: .touchUpInside)

        tagStack.axis = .horizontal
        tagStack.alignment = .fill
        tagStack.spacing = 2
        tagStack.isLayoutMarginsRelativeArrangement = true
        tagStack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 2)
        tagsRow.isHidden = true

        headingStack.axis = .vertical
        headingStack.spacing = 6
        headingStack.isLayoutMarginsRelativeArrangement = true
        updateHeadingMargins()
        headingStack.addArrangedSubview(titleRow)
        headingStack.addArrangedSubview(tagsRow)
    }

    private func configureMetadata() {
        authorButton.contentHorizontalAlignment = .left
        authorButton.titleLabel?.lineBreakMode = .byTruncatingTail
        authorButton.accessibilityIdentifier = UIIdentifiers.BookDetail.headerAuthorAction
        authorButton.addTarget(self, action: #selector(handleAuthorTap), for: .touchUpInside)
        sourceButton.contentHorizontalAlignment = .left
        sourceButton.titleLabel?.textAlignment = .left
        sourceButton.titleLabel?.lineBreakMode = .byTruncatingTail
        sourceButton.clipsToBounds = true
        sourceButton.isEnabled = isSourceEditEnabled
        sourceButton.accessibilityIdentifier = UIIdentifiers.BookDetail.infoSourceRow
        sourceButton.addTarget(self, action: #selector(handleSourceTap), for: .touchUpInside)

        for label in [latestLabel, groupLabel, tocLabel] {
            label.textColor = AndroidReplicaBookDetailTypography.summaryText
            label.adjustsFontForContentSizeCategory = false
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
        }
        latestLabel.accessibilityIdentifier = "bookDetail.info.latestChapter"
        groupLabel.accessibilityIdentifier = UIIdentifiers.BookDetail.infoGroupRow
        groupLabel.text = String(
            format: L10n.BookDetail.groupFormat, L10n.BookDetail.groupFallbackRemote
        )
        tocLabel.accessibilityIdentifier = UIIdentifiers.BookDetail.infoTocRow

        tocButton.setTitle(L10n.BookDetail.viewToc, for: .normal)
        tocButton.accessibilityIdentifier = UIIdentifiers.BookDetail.infoTocAction
        tocButton.addTarget(self, action: #selector(handleTocTap), for: .touchUpInside)
        tocButton.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        tocButton.setContentHuggingPriority(.required, for: .horizontal)

        sourceChangeButton.setTitle(L10n.BookDetail.changeSource, for: .normal)
        sourceChangeButton.accessibilityIdentifier = UIIdentifiers.BookDetail.infoSourceAction
        sourceChangeButton.addTarget(self, action: #selector(handleSourceChangeTap), for: .touchUpInside)
        sourceChangeButton.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        sourceChangeButton.setContentHuggingPriority(.required, for: .horizontal)

        groupButton.setTitle(
            Bundle.main.localizedString(forKey: "book_detail.android_change_group", value: "设置分组", table: nil),
            for: .normal)
        groupButton.isEnabled = isGroupEnabled
        groupButton.alpha = isGroupEnabled ? 1 : 0.45
        groupButton.accessibilityIdentifier = UIIdentifiers.BookDetail.infoGroupAction
        groupButton.addTarget(self, action: #selector(handleGroupTap), for: .touchUpInside)
        groupButton.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        groupButton.setContentHuggingPriority(.required, for: .horizontal)

        for child in [sourceButton, sourceChangeButton] {
            child.translatesAutoresizingMaskIntoConstraints = false
            sourceContentView.addSubview(child)
        }
        sourceButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sourceButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let sourceTop = sourceButton.topAnchor.constraint(greaterThanOrEqualTo: sourceContentView.topAnchor)
        let sourceBottom = sourceButton.bottomAnchor.constraint(lessThanOrEqualTo: sourceContentView.bottomAnchor)
        sourceTop.priority = UILayoutPriority(999)
        sourceBottom.priority = UILayoutPriority(999)
        let sourceActionTop = sourceChangeButton.topAnchor.constraint(
            greaterThanOrEqualTo: sourceContentView.topAnchor)
        let sourceActionBottom = sourceChangeButton.bottomAnchor.constraint(
            lessThanOrEqualTo: sourceContentView.bottomAnchor)
        sourceActionTop.priority = UILayoutPriority(999)
        sourceActionBottom.priority = UILayoutPriority(999)
        sourceActionHeightConstraints = [sourceActionTop, sourceActionBottom]
        NSLayoutConstraint.activate([
            sourceButton.leadingAnchor.constraint(equalTo: sourceContentView.leadingAnchor),
            sourceTop,
            sourceBottom,
            sourceButton.centerYAnchor.constraint(equalTo: sourceContentView.centerYAnchor),
            sourceButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 0),
            sourceChangeButton.trailingAnchor.constraint(equalTo: sourceContentView.trailingAnchor),
            sourceChangeButton.centerYAnchor.constraint(equalTo: sourceContentView.centerYAnchor),
        ])
        sourceButtonFullWidthConstraint = sourceButton.trailingAnchor.constraint(
            equalTo: sourceContentView.trailingAnchor, constant: -6
        )
        sourceButtonWithActionConstraint = sourceButton.trailingAnchor.constraint(
            equalTo: sourceChangeButton.leadingAnchor, constant: -14
        )
        updateSourceChangeState()

        metadataStack.axis = .vertical
        metadataStack.spacing = 0
        metadataStack.isLayoutMarginsRelativeArrangement = true
        metadataStack.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 0, leading: 8, bottom: 8, trailing: 8
        )
        metadataStack.addArrangedSubview(authorRow)
        metadataStack.addArrangedSubview(sourceRow)
        metadataStack.addArrangedSubview(latestRow)
        metadataStack.addArrangedSubview(groupRow)
        metadataStack.addArrangedSubview(tocRow)
        updateCatalogAvailability()
    }

    private func configureLayout() {
        refreshControl.tintColor = AndroidReplicaTheme.accent
        refreshControl.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
        for scrollView in [primaryScrollView, detailsScrollView] {
            scrollView.translatesAutoresizingMaskIntoConstraints = false
            scrollView.showsHorizontalScrollIndicator = false
            scrollView.contentInsetAdjustmentBehavior = .never
            scrollView.isDirectionalLockEnabled = true
            scrollView.delaysContentTouches = false
            scrollView.delegate = self
            addSubview(scrollView)
        }
        detailsScrollView.backgroundColor = AndroidReplicaTheme.background
        detailsScrollView.accessibilityIdentifier = "bookDetail.detailsScroll"
        primaryStack.axis = .vertical
        primaryStack.spacing = 0
        primaryStack.translatesAutoresizingMaskIntoConstraints = false
        primaryScrollView.addSubview(primaryStack)
        primaryStack.addArrangedSubview(summaryView)

        summaryInfoStack.axis = .vertical
        summaryInfoStack.spacing = 0
        summaryInfoStack.backgroundColor = AndroidReplicaTheme.background
        summaryInfoStack.isLayoutMarginsRelativeArrangement = true
        summaryInfoStack.addArrangedSubview(headingStack)

        infoStack.axis = .vertical
        infoStack.spacing = 0
        infoStack.backgroundColor = AndroidReplicaTheme.background
        infoStack.isLayoutMarginsRelativeArrangement = true
        infoStack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 8, bottom: 8, trailing: 8)

        let introContainer = UIView()
        introTextView.translatesAutoresizingMaskIntoConstraints = false
        introContainer.addSubview(introTextView)
        let introBottom = introTextView.bottomAnchor.constraint(equalTo: introContainer.bottomAnchor, constant: -8)
        introBottom.priority = .defaultLow

        for child in [heroView, summaryInfoStack] {
            child.translatesAutoresizingMaskIntoConstraints = false
            summaryView.addSubview(child)
        }
        for child in [arcView, coverCardView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            heroView.addSubview(child)
        }
        coverImageView.translatesAutoresizingMaskIntoConstraints = false
        coverCardView.addSubview(coverImageView)
        infoStack.translatesAutoresizingMaskIntoConstraints = false
        infoStack.addArrangedSubview(metadataStack)
        infoStack.addArrangedSubview(introContainer)
        infoStack.setCustomSpacing(8, after: metadataStack)

        addLayoutGuide(actionColumnGuide)
        primaryBottomConstraint = primaryScrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        detailsBottomConstraint = detailsScrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        heroTopConstraint = heroView.topAnchor.constraint(equalTo: summaryView.topAnchor, constant: 8)
        heroHeightConstraint = heroView.heightAnchor.constraint(equalToConstant: 168)
        arcTopConstraint = arcView.topAnchor.constraint(equalTo: heroView.topAnchor, constant: 90)
        coverWidthConstraint = coverCardView.widthAnchor.constraint(equalToConstant: 110)
        // CoverImageView overrides the XML's nominal height with width * 7 / 5.
        coverHeightConstraint = coverCardView.heightAnchor.constraint(equalToConstant: 154)
        NSLayoutConstraint.activate([
            primaryScrollView.topAnchor.constraint(equalTo: topAnchor),
            primaryScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            primaryBottomConstraint!,
            detailsScrollView.topAnchor.constraint(equalTo: topAnchor),
            detailsScrollView.leadingAnchor.constraint(equalTo: centerXAnchor),
            detailsScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            detailsBottomConstraint!,
            actionColumnGuide.trailingAnchor.constraint(equalTo: trailingAnchor),
            actionColumnGuide.bottomAnchor.constraint(equalTo: bottomAnchor),
            primaryStack.topAnchor.constraint(equalTo: primaryScrollView.contentLayoutGuide.topAnchor),
            primaryStack.leadingAnchor.constraint(equalTo: primaryScrollView.contentLayoutGuide.leadingAnchor),
            primaryStack.trailingAnchor.constraint(equalTo: primaryScrollView.contentLayoutGuide.trailingAnchor),
            primaryStack.bottomAnchor.constraint(equalTo: primaryScrollView.contentLayoutGuide.bottomAnchor),
            primaryStack.widthAnchor.constraint(equalTo: primaryScrollView.frameLayoutGuide.widthAnchor),
            primaryStack.heightAnchor.constraint(greaterThanOrEqualTo: primaryScrollView.frameLayoutGuide.heightAnchor),
            heroTopConstraint!,
            heroView.leadingAnchor.constraint(equalTo: summaryView.leadingAnchor),
            heroView.trailingAnchor.constraint(equalTo: summaryView.trailingAnchor),
            heroHeightConstraint!,
            arcTopConstraint!,
            arcView.leadingAnchor.constraint(equalTo: heroView.leadingAnchor),
            arcView.trailingAnchor.constraint(equalTo: heroView.trailingAnchor),
            arcView.heightAnchor.constraint(equalToConstant: 78),
            coverCardView.topAnchor.constraint(equalTo: heroView.topAnchor, constant: 3),
            coverCardView.centerXAnchor.constraint(equalTo: heroView.centerXAnchor),
            coverWidthConstraint!,
            coverHeightConstraint!,
            coverImageView.topAnchor.constraint(equalTo: coverCardView.topAnchor),
            coverImageView.leadingAnchor.constraint(equalTo: coverCardView.leadingAnchor),
            coverImageView.trailingAnchor.constraint(equalTo: coverCardView.trailingAnchor),
            coverImageView.bottomAnchor.constraint(equalTo: coverCardView.bottomAnchor),
            summaryInfoStack.topAnchor.constraint(equalTo: heroView.bottomAnchor),
            summaryInfoStack.leadingAnchor.constraint(equalTo: summaryView.leadingAnchor),
            summaryInfoStack.trailingAnchor.constraint(equalTo: summaryView.trailingAnchor),
            summaryInfoStack.bottomAnchor.constraint(equalTo: summaryView.bottomAnchor),
            introContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
            introTextView.topAnchor.constraint(equalTo: introContainer.topAnchor),
            introTextView.leadingAnchor.constraint(equalTo: introContainer.leadingAnchor, constant: 8),
            introTextView.trailingAnchor.constraint(equalTo: introContainer.trailingAnchor),
            introTextView.bottomAnchor.constraint(lessThanOrEqualTo: introContainer.bottomAnchor, constant: -8),
            introBottom,
        ])
        portraitConstraints = [
            primaryScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            actionColumnGuide.leadingAnchor.constraint(equalTo: leadingAnchor),
        ]
        columnConstraints = [
            primaryScrollView.trailingAnchor.constraint(equalTo: centerXAnchor),
            actionColumnGuide.leadingAnchor.constraint(equalTo: centerXAnchor),
            infoStack.topAnchor.constraint(equalTo: detailsScrollView.contentLayoutGuide.topAnchor),
            infoStack.leadingAnchor.constraint(equalTo: detailsScrollView.contentLayoutGuide.leadingAnchor),
            infoStack.trailingAnchor.constraint(equalTo: detailsScrollView.contentLayoutGuide.trailingAnchor),
            infoStack.bottomAnchor.constraint(equalTo: detailsScrollView.contentLayoutGuide.bottomAnchor),
            infoStack.widthAnchor.constraint(equalTo: detailsScrollView.frameLayoutGuide.widthAnchor),
            infoStack.heightAnchor.constraint(greaterThanOrEqualTo: detailsScrollView.frameLayoutGuide.heightAnchor),
        ]
        applyLayoutMode()
    }

    private func applyLayoutMode() {
        // Move the same controls so render values, accessibility elements and targets stay intact.
        primaryStack.removeArrangedSubview(infoStack)
        infoStack.removeFromSuperview()
        metadataStack.removeArrangedSubview(authorRow)
        summaryInfoStack.removeArrangedSubview(authorRow)
        authorRow.removeFromSuperview()
        if usesColumns {
            detailsScrollView.addSubview(infoStack)
            // The landscape author container is match_parent with centered content,
            // so the row itself, rather than a spacer below it, fills the remaining height.
            summaryInfoStack.insertArrangedSubview(authorRow, at: 1)
        } else {
            primaryStack.addArrangedSubview(infoStack)
            metadataStack.insertArrangedSubview(authorRow, at: 0)
        }

        heroTopConstraint?.constant = usesColumns ? 30 : 8
        heroHeightConstraint?.constant = usesColumns ? 206 : 168
        arcTopConstraint?.constant = usesColumns ? 128 : 90
        coverWidthConstraint?.constant = usesColumns ? 130 : 110
        coverHeightConstraint?.constant = usesColumns ? 182 : 154
        summaryInfoStack.directionalLayoutMargins =
            usesColumns
            ? NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 3, trailing: 16)
            : NSDirectionalEdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8)
        updateHeadingMargins()
        infoStack.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: usesColumns ? 16 : 0, leading: 8, bottom: 8, trailing: 8
        )
        authorRow.setContentCentered(usesColumns)
        authorButton.contentHorizontalAlignment = usesColumns ? .center : .left
        detailsScrollView.isHidden = !usesColumns
        primaryScrollView.accessibilityIdentifier = usesColumns ? "bookDetail.summaryScroll" : "bookDetail.scroll"
        primaryScrollView.scrollsToTop = !usesColumns
        detailsScrollView.scrollsToTop = usesColumns
        NSLayoutConstraint.activate(usesColumns ? columnConstraints : portraitConstraints)
        updateActionBarReservation()
        updateRefreshAvailability()
    }

    private func updateRefreshAvailability() {
        let hasRefreshControl = !usesColumns && isRefreshEnabled && onRefresh != nil
        let canRefresh = hasRefreshControl && window != nil && !isRefreshInFlight
        if !canRefresh {
            refreshControl.endRefreshing()
        }
        refreshControl.isEnabled = canRefresh
        primaryScrollView.alwaysBounceVertical = hasRefreshControl
        if hasRefreshControl {
            if primaryScrollView.refreshControl !== refreshControl {
                primaryScrollView.refreshControl = refreshControl
            }
        } else if primaryScrollView.refreshControl != nil {
            primaryScrollView.refreshControl = nil
        }
    }

    @objc private func handleRefresh() {
        guard !usesColumns, isRefreshEnabled, window != nil,
            !isRefreshInFlight, !didRefreshDuringDrag, let onRefresh
        else {
            refreshControl.endRefreshing()
            return
        }
        didRefreshDuringDrag = true
        isRefreshInFlight = true
        refreshControl.endRefreshing()
        updateRefreshAvailability()
        onRefresh()
    }

    private func updateHeadingMargins() {
        // In portrait the empty LabelsBar's HorizontalScrollView still has its 6dp bottom margin.
        headingStack.directionalLayoutMargins =
            usesColumns
            ? NSDirectionalEdgeInsets(top: 8, leading: 0, bottom: 6, trailing: 0)
            : NSDirectionalEdgeInsets(
                top: 8, leading: 10, bottom: displayedTags.isEmpty ? 15 : 9, trailing: 10)
    }

    private func updateActionBarReservation() {
        let height = reservedActionBarHeight.isFinite ? max(0, reservedActionBarHeight) : 0
        primaryBottomConstraint?.constant = usesColumns ? 0 : -height
        detailsBottomConstraint?.constant = -height
    }

    private func saveScrollPositions() {
        guard primaryScrollView.bounds.width > 0, primaryScrollView.bounds.height > 0 else { return }
        if usesColumns {
            summaryPosition = position(in: primaryScrollView)
            detailsPosition = position(in: detailsScrollView)
        } else {
            portraitPosition = position(in: primaryScrollView)
        }
    }

    private func position(in scrollView: UIScrollView) -> ScrollPosition {
        let offsetY = clampedOffset(scrollView.contentOffset.y, in: scrollView)
        var result = ScrollPosition(offsetY: offsetY)
        let anchors = [
            heroView, headingStack, authorRow, sourceRow,
            latestRow, groupRow, tocRow, introTextView,
        ]
        for anchor in anchors where !anchor.isHidden && anchor.isDescendant(of: scrollView) {
            let top = anchor.convert(anchor.bounds, to: scrollView).minY
            if top <= offsetY {
                result.anchor = anchor
                result.anchorOffset = offsetY - top
            }
        }
        return result
    }

    private func restore(_ position: ScrollPosition, in scrollView: UIScrollView) {
        var offsetY = position.offsetY
        if let anchor = position.anchor, !anchor.isHidden, anchor.isDescendant(of: scrollView) {
            offsetY = anchor.convert(anchor.bounds, to: scrollView).minY + position.anchorOffset
        }
        let target = CGPoint(x: 0, y: clampedOffset(offsetY, in: scrollView))
        if scrollView.contentOffset != target {
            scrollView.setContentOffset(target, animated: false)
        }
    }

    private func clampedOffset(_ offsetY: CGFloat, in scrollView: UIScrollView) -> CGFloat {
        min(max(0, offsetY), max(0, scrollView.contentSize.height - scrollView.bounds.height))
    }

    private func updateSourceChangeState() {
        sourceChangeButton.isHidden = !isSourceChangeVisible
        sourceChangeButton.isEnabled = isSourceChangeEnabled
        sourceChangeButton.alpha = isSourceChangeEnabled ? 1 : 0.45
        if isSourceChangeVisible {
            sourceButtonFullWidthConstraint?.isActive = false
            sourceButtonWithActionConstraint?.isActive = true
            NSLayoutConstraint.activate(sourceActionHeightConstraints)
        } else {
            sourceButtonWithActionConstraint?.isActive = false
            sourceButtonFullWidthConstraint?.isActive = true
            NSLayoutConstraint.deactivate(sourceActionHeightConstraints)
        }
        sourceContentView.setNeedsUpdateConstraints()
        sourceContentView.setNeedsLayout()
        metadataStack.setNeedsLayout()
        infoStack.setNeedsLayout()
        setNeedsUpdateConstraints()
        setNeedsLayout()
    }

    private func updateCatalogAvailability() {
        tocRow.isHidden = !showsCatalog
        tocRow.accessibilityElementsHidden = !showsCatalog
        let isEnabled = showsCatalog && isTocEnabled
        tocButton.isEnabled = isEnabled
        tocButton.alpha = isEnabled ? 1 : 0.45
    }

    private func updateTypography() {
        let titleFont = AndroidReplicaBookDetailTypography.font(size: 18, compatibleWith: traitCollection)
        let tagFont = AndroidReplicaBookDetailTypography.font(size: 12, compatibleWith: traitCollection)
        let infoFont = AndroidReplicaBookDetailTypography.font(size: 13, compatibleWith: traitCollection)
        for button in [titleButton, authorButton, sourceButton, sourceChangeButton, groupButton, tocButton] {
            button.refreshTypography(compatibleWith: traitCollection)
        }
        for label in [latestLabel, groupLabel, tocLabel] {
            label.font = infoFont
        }
        for badge in tagBadges + unusedTagBadges {
            badge.label.font = tagFont
        }
        // The source XML adds no lineSpacingExtra or multiplier; keep the font's natural line height.
        introTextView.refreshTypography(compatibleWith: traitCollection)
        titleRow.setHeight(ceil(titleFont.lineHeight))
        tagsRow.setHeight(tagLineHeight)
        for row in [authorRow, sourceRow, latestRow, groupRow, tocRow] {
            row.refreshMetrics(compatibleWith: traitCollection)
        }
    }

    private var tagLineHeight: CGFloat {
        let font = AndroidReplicaBookDetailTypography.font(size: 12, compatibleWith: traitCollection)
        let padding = AndroidExploreTextMetrics.padding(font: font, scale: traitCollection.displayScale)
        return ceil(font.lineHeight + padding.top + padding.bottom)
    }

    @objc private func refreshPalette() {
        if !needsScrollRestoration { saveScrollPositions() }
        needsScrollRestoration = true
        for button in [sourceChangeButton, groupButton, tocButton] { button.refreshPalette() }
        for badge in tagBadges + unusedTagBadges {
            badge.view.backgroundColor = AndroidReplicaTheme.accent
            badge.label.textColor = BookDetailActionPalette.accentText
        }
        arcView.setNeedsDisplay()
        setNeedsLayout()
    }

    private func renderTags(_ kind: String?, wordCount: String?) {
        var tags: [String] = []
        // BaseBook.getKindList keeps wordCount as one verbatim label before splitting kind.
        if let wordCount, !wordCount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tags.append(wordCount)
        }
        tags += (kind ?? "")
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard tags != displayedTags else { return }
        displayedTags = tags
        while tagBadges.count > tags.count {
            let badge = tagBadges.removeLast()
            tagStack.removeArrangedSubview(badge.view)
            badge.view.removeFromSuperview()
            unusedTagBadges.append(badge)
        }
        while tagBadges.count < tags.count {
            let badge = unusedTagBadges.popLast() ?? makeTagBadge()
            tagStack.addArrangedSubview(badge.view)
            tagBadges.append(badge)
        }
        for (badge, tag) in zip(tagBadges, tags) where badge.label.text != tag {
            badge.label.text = tag
        }
        tagsRow.isHidden = tags.isEmpty
        updateHeadingMargins()
        tagsRow.resetOffset()
    }

    private func makeTagBadge() -> TagBadge {
        let badge = UIView()
        badge.backgroundColor = AndroidReplicaTheme.accent
        badge.layer.cornerRadius = 2
        let label = AndroidExploreTextLabel()
        label.font = AndroidReplicaBookDetailTypography.font(size: 12, compatibleWith: traitCollection)
        label.adjustsFontForContentSizeCategory = false
        label.textColor = BookDetailActionPalette.accentText
        label.numberOfLines = 1
        label.isAccessibilityElement = true
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: badge.topAnchor),
            label.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: 3),
            label.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: -3),
            label.bottomAnchor.constraint(equalTo: badge.bottomAnchor),
        ])
        return TagBadge(view: badge, label: label)
    }

    private func singleLine(_ text: String?) -> String? {
        text?.sanitizedDisplayText.components(separatedBy: .newlines).joined(separator: " ").nilIfEmpty
    }

    @objc private func handleTitleTap() {
        onTitleTap?()
    }

    @objc private func handleAuthorTap() {
        onAuthorTap?()
    }

    @objc private func handleGroupTap() {
        guard isGroupEnabled else { return }
        onGroupTap?()
    }

    @objc private func handleTocTap() {
        guard showsCatalog, isTocEnabled else { return }
        onTocTap?()
    }

    @objc private func handleSourceTap() {
        guard isSourceEditEnabled else { return }
        onSourceTap?()
    }

    @objc private func handleSourceChangeTap() {
        guard isSourceChangeVisible, isSourceChangeEnabled else { return }
        onSourceChangeTap?()
    }
}

// The image owns clipping because its bounds settle after the containing stack's layout.
private final class BookDetailCoverImageView: UIImageView {
    private let clipLayer = CAShapeLayer()
    private var clippedSize = CGSize.zero
    private var clippedScale: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.mask = clipLayer
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        setNeedsLayout()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.displayScale != traitCollection.displayScale { setNeedsLayout() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = bounds.size
        let scale = max(window?.screen.scale ?? traitCollection.displayScale, 1)
        guard size.width > 0, size.height > 0, size != clippedSize || scale != clippedScale else { return }
        clippedSize = size
        clippedScale = scale
        let radius: CGFloat = 10 / scale
        let path = UIBezierPath()
        path.move(to: CGPoint(x: radius, y: 0))
        path.addLine(to: CGPoint(x: size.width - radius, y: 0))
        path.addQuadCurve(to: CGPoint(x: size.width, y: radius), controlPoint: CGPoint(x: size.width, y: 0))
        path.addLine(to: CGPoint(x: size.width, y: size.height - radius))
        path.addQuadCurve(
            to: CGPoint(x: size.width - radius, y: size.height),
            controlPoint: CGPoint(x: size.width, y: size.height))
        path.addLine(to: CGPoint(x: radius, y: size.height))
        path.addQuadCurve(to: CGPoint(x: 0, y: size.height - radius), controlPoint: CGPoint(x: 0, y: size.height))
        path.addLine(to: CGPoint(x: 0, y: radius))
        path.addQuadCurve(to: CGPoint(x: radius, y: 0), controlPoint: .zero)
        path.close()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clipLayer.contentsScale = scale
        clipLayer.frame = bounds
        clipLayer.path = path.cgPath
        CATransaction.commit()
    }
}

extension AndroidReplicaBookDetailContentView {
    fileprivate final class HorizontalScrollRow: UIView {
        private let scrollView = ActionScrollView()
        private var viewportSize = CGSize.zero
        private var contentSize = CGSize.zero
        private var rowHeightConstraint: NSLayoutConstraint!

        init(content: UIView, height: CGFloat) {
            super.init(frame: .zero)
            scrollView.translatesAutoresizingMaskIntoConstraints = false
            scrollView.showsHorizontalScrollIndicator = false
            scrollView.showsVerticalScrollIndicator = false
            scrollView.contentInsetAdjustmentBehavior = .never
            scrollView.isDirectionalLockEnabled = true
            scrollView.delaysContentTouches = false
            addSubview(scrollView)
            content.translatesAutoresizingMaskIntoConstraints = false
            scrollView.addSubview(content)

            // Center short content; only the viewport narrows when the title or labels overflow.
            let fittingWidth = scrollView.widthAnchor.constraint(equalTo: content.widthAnchor)
            fittingWidth.priority = .defaultHigh
            rowHeightConstraint = heightAnchor.constraint(equalToConstant: height)
            rowHeightConstraint.priority = UILayoutPriority(999)
            NSLayoutConstraint.activate([
                rowHeightConstraint,
                scrollView.centerXAnchor.constraint(equalTo: centerXAnchor),
                scrollView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
                scrollView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
                scrollView.topAnchor.constraint(equalTo: topAnchor),
                scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
                fittingWidth,
                content.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
                content.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
                content.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
                content.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
            ])
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            preconditionFailure("init(coder:) is unavailable")
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            scrollView.layoutIfNeeded()
            guard viewportSize != scrollView.bounds.size || contentSize != scrollView.contentSize else { return }
            viewportSize = scrollView.bounds.size
            contentSize = scrollView.contentSize
            let maximumOffset = max(0, contentSize.width - viewportSize.width)
            let offset = min(max(0, scrollView.contentOffset.x), maximumOffset)
            if scrollView.contentOffset.x != offset {
                scrollView.setContentOffset(CGPoint(x: offset, y: 0), animated: false)
            }
        }

        func resetOffset() {
            scrollView.setContentOffset(.zero, animated: false)
        }

        func setHeight(_ height: CGFloat) {
            rowHeightConstraint.constant = height
            setNeedsLayout()
        }

        private final class ActionScrollView: UIScrollView {
            override func touchesShouldCancel(in view: UIView) -> Bool {
                view is UIControl || super.touchesShouldCancel(in: view)
            }
        }
    }

    fileprivate final class ArcBackgroundView: UIView {
        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isOpaque = false
            contentMode = .redraw
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            preconditionFailure("init(coder:) is unavailable")
        }

        override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
            super.traitCollectionDidChange(previousTraitCollection)
            if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
                setNeedsDisplay()
            }
        }

        override func draw(_ rect: CGRect) {
            guard !bounds.isEmpty else { return }
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 0, y: 36))
            path.addQuadCurve(to: CGPoint(x: bounds.width, y: 36), controlPoint: CGPoint(x: bounds.midX, y: 0))
            path.addLine(to: CGPoint(x: bounds.width, y: bounds.height))
            path.addLine(to: CGPoint(x: 0, y: bounds.height))
            path.close()
            AndroidReplicaTheme.background.setFill()
            path.fill()
        }
    }
}
