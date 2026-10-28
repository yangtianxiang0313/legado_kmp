import UIKit
import shared

/// activity_explore_show.xml / TitleBar at Legado 5f5d314, excluding the status-bar inset.
final class ExploreResultsToolbarView: UIView {
    let backButton = ExploreAndroidSelectableButton(frame: .zero)
    var onBack: (() -> Void)?

    private let titleLabel = AndroidExploreTextLabel()
    private var minimumHeightConstraint: NSLayoutConstraint?
    private var backButtonHeightConstraint: NSLayoutConstraint?
    private var backButtonLeadingConstraint: NSLayoutConstraint?
    private var titleTrailingConstraint: NSLayoutConstraint?
    private var availableSize: CGSize = .zero

    private var resourceHeight: CGFloat {
        AndroidToolbarLayout.minimumHeight(for: availableSize)
    }

    private var toolbarHeight: CGFloat {
        let padding = titleLabel.fontPadding
        return max(
            resourceHeight,
            ceil(titleLabel.font.lineHeight + padding.top + padding.bottom + AndroidToolbarLayout.titleVerticalMargins))
    }

    override init(frame: CGRect = .zero) {
        super.init(frame: frame)
        backgroundColor = AndroidReplicaTheme.toolbarBackground
        isAccessibilityElement = false

        backButton.configuration = nil
        backButton.automaticallyUpdatesConfiguration = false
        backButton.backgroundColor = .clear
        backButton.feedback = .navigation
        backButton.dimsWhenDisabled = false
        backButton.contentEdgeInsets = .zero
        backButton.imageView?.contentMode = .center
        backButton.tintColor = AndroidReplicaTheme.toolbarText
        backButton.setImage(ReaderMenuAndroidIcon.back.image(), for: .normal)
        backButton.accessibilityLabel = L10n.Reader.backAction
        backButton.accessibilityIdentifier = UIIdentifiers.Common.drillDownBackButton
        backButton.addInteraction(UIToolTipInteraction(defaultToolTip: L10n.Reader.backAction))
        backButton.addTarget(self, action: #selector(handleBack), for: .touchUpInside)

        titleLabel.textColor = AndroidReplicaTheme.toolbarText
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.adjustsFontSizeToFitWidth = false
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.accessibilityTraits = [.header, .staticText]
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        for child in [backButton, titleLabel] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        accessibilityElements = [backButton, titleLabel]
        minimumHeightConstraint = heightAnchor.constraint(greaterThanOrEqualToConstant: toolbarHeight)
        backButtonHeightConstraint = backButton.heightAnchor.constraint(equalToConstant: resourceHeight)
        backButtonLeadingConstraint = backButton.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor)
        titleTrailingConstraint = titleLabel.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -4)
        NSLayoutConstraint.activate([
            minimumHeightConstraint!,
            backButtonHeightConstraint!,
            backButtonLeadingConstraint!,
            titleTrailingConstraint!,
            // AppCompat buttonGravity=top keeps navigation in the resource-height row.
            backButton.topAnchor.constraint(equalTo: topAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 56),
            // This screen sets contentInsetStartWithNavigation to zero; only titleMargin remains.
            titleLabel.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 4),
            titleLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 0),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.topAnchor.constraint(
                greaterThanOrEqualTo: topAnchor, constant: AndroidToolbarLayout.titleVerticalMargins / 2),
            titleLabel.bottomAnchor.constraint(
                lessThanOrEqualTo: bottomAnchor, constant: -AndroidToolbarLayout.titleVerticalMargins / 2),
        ])
        updateTypography()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: toolbarHeight)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: toolbarHeight)
    }

    /// Pass only exploreName, not the source name or an additional subtitle.
    func setTitle(_ title: String) {
        let display = title.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: "\u{FEFF}")
        titleLabel.attributedText = NSAttributedString(string: display, attributes: [.kern: CGFloat(0)])
        titleLabel.accessibilityLabel = title
    }

    /// The root supplies its available size; toolbar bounds do not identify the resource configuration.
    func updateLayout(availableSize: CGSize) {
        guard availableSize.width.isFinite, availableSize.height.isFinite,
            availableSize.width > 0, availableSize.height > 0, self.availableSize != availableSize
        else { return }
        self.availableSize = availableSize
        let padding = AndroidToolbarLayout.horizontalPadding(for: availableSize)
        backButtonLeadingConstraint?.constant = padding
        titleTrailingConstraint?.constant = -padding - 4
        backButtonHeightConstraint?.constant = resourceHeight
        updateToolbarHeight()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateTypography()
        applyPalette()
    }

    func setInteractionEnabled(_ enabled: Bool) {
        backButton.isEnabled = enabled
    }

    private func applyPalette() {
        backgroundColor = AndroidReplicaTheme.toolbarBackground
        titleLabel.textColor = AndroidReplicaTheme.toolbarText
        backButton.tintColor = AndroidReplicaTheme.toolbarText
    }

    private func updateTypography() {
        titleLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 20, textStyle: .headline, weight: 500, compatibleWith: traitCollection)
        titleLabel.adjustsFontForContentSizeCategory = false
        updateToolbarHeight()
    }

    private func updateToolbarHeight() {
        minimumHeightConstraint?.constant = toolbarHeight
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    @objc private func handleBack() {
        guard backButton.canReceiveActivation else { return }
        onBack?()
    }
}

/// LoadMoreView / view_load_more.xml at Legado 5f5d314, rendered as a self-sizing footer row.
final class ExploreResultsFooterCell: UITableViewCell {
    static let reuseIdentifier = "ExploreResultsFooterCell"

    enum State: Equatable {
        case loading, ready, empty, end
        case error(String)
    }

    var onActivate: (() -> Void)? {
        didSet { updateInteraction() }
    }

    private(set) var state: State = .ready

    /// The host uses this unmodified value for the error dialog and its retry action.
    var errorMessage: String? {
        guard case .error(let message) = state else { return nil }
        return message
    }

    private enum Text {
        static let empty = NSLocalizedString(
            "discovery.results.footer.empty", value: "空", comment: "Legado string empty")
        static let end = NSLocalizedString(
            "discovery.results.footer.end", value: "我是有底线的", comment: "Legado string bottom_line")
        static let error = NSLocalizedString(
            "discovery.results.footer.error", value: "加载失败\n点击查看详情",
            comment: "Legado error_load_msg with LoadMoreView's detail action")
        static let loading = NSLocalizedString(
            "discovery.results.footer.loading", value: "加载中…", comment: "Legado string loading; accessibility only")
    }

    private let statusLabel = AndroidExploreTextLabel()
    private let spinner = BookshelfBookStatusLoadingView()
    private let activationButton = ExploreAndroidSelectableButton(frame: .zero)
    private var minimumHeightConstraint: NSLayoutConstraint?
    private var isPresentationActive = true

    private var canActivate: Bool {
        isPresentationActive && state != .loading && onActivate != nil
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = AndroidReplicaTheme.background
        contentView.backgroundColor = .clear
        selectionStyle = .none
        indentationWidth = 0
        accessibilityIdentifier = UIIdentifiers.Discovery.loadMoreCell
        contentView.accessibilityElementsHidden = true

        activationButton.configuration = nil
        activationButton.automaticallyUpdatesConfiguration = false
        activationButton.backgroundColor = .clear
        activationButton.feedback = .bounded
        activationButton.usesToolbarPalette = false
        activationButton.dimsWhenDisabled = false
        activationButton.isAccessibilityElement = false
        activationButton.addTarget(self, action: #selector(handleActivate), for: .touchUpInside)

        statusLabel.textColor = AndroidReplicaTheme.secondaryText
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 1
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.adjustsFontSizeToFitWidth = false
        statusLabel.adjustsFontForContentSizeCategory = false
        statusLabel.isUserInteractionEnabled = false
        statusLabel.isAccessibilityElement = false
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        spinner.loadingWidth = 2

        for child in [activationButton, statusLabel, spinner] {
            child.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(child)
        }
        minimumHeightConstraint = contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 48)
        minimumHeightConstraint?.isActive = true
        NSLayoutConstraint.activate([
            activationButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            activationButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            activationButton.topAnchor.constraint(equalTo: contentView.topAnchor),
            activationButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.leadingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.trailingAnchor, constant: -10),
            statusLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            statusLabel.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 10),
            statusLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -10),
            spinner.centerXAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 36),
            spinner.heightAnchor.constraint(equalToConstant: 36),
            spinner.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 6),
            spinner.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -6),
        ])
        updateTypography()
        configure(.ready)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    func configure(_ state: State) {
        updateTypography()
        activationButton.cancelPendingActivation()
        self.state = state
        let text: String?
        switch state {
        case .loading, .ready: text = nil
        case .empty: text = Text.empty
        case .end: text = Text.end
        case .error: text = Text.error
        }
        // Android's singleLine transformation replaces the resource's newline with a space.
        statusLabel.attributedText = text.map {
            NSAttributedString(
                string: $0.replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\r", with: "\u{FEFF}"),
                attributes: [.kern: CGFloat(0)])
        }
        statusLabel.isHidden = text == nil
        spinner.setRefreshing(state == .loading)
        // The invisible TextView retains geometry but has no selectable feedback.
        activationButton.showsFeedback = text != nil
        updateInteraction()
    }

    /// Defaults to active for existing callers. The host gates departure, overlays and scene state.
    func setPresentationActive(_ active: Bool) {
        isPresentationActive = active
        accessibilityElementsHidden = !active
        spinner.setPresentationActive(active)
        if !active { activationButton.cancelPendingActivation() }
        updateInteraction()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onActivate = nil
        configure(.ready)
        setPresentationActive(true)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The original selectable background belongs to the padded text, not the whole 48dp row.
        let inset = max(0, (contentView.bounds.height - statusLabel.bounds.height - 20) / 2)
        activationButton.feedbackInsets = UIEdgeInsets(top: inset, left: 0, bottom: inset, right: 0)
    }

    override func systemLayoutSizeFitting(
        _ targetSize: CGSize,
        withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority
    ) -> CGSize {
        updateTypography()
        return super.systemLayoutSizeFitting(
            targetSize,
            withHorizontalFittingPriority: horizontalFittingPriority,
            verticalFittingPriority: verticalFittingPriority)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateTypography()
        backgroundColor = AndroidReplicaTheme.background
        statusLabel.textColor = AndroidReplicaTheme.secondaryText
    }

    override func accessibilityActivate() -> Bool {
        activate()
    }

    private func updateTypography() {
        statusLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .subheadline, compatibleWith: traitCollection)
        // Keep the same width and height through state changes, including the blank ready state.
        let padding = statusLabel.fontPadding
        minimumHeightConstraint?.constant = max(
            48, ceil(statusLabel.font.lineHeight) + padding.top + padding.bottom + 20)
        setNeedsLayout()
    }

    private func updateInteraction() {
        activationButton.isEnabled = canActivate
        isAccessibilityElement = state != .ready || canActivate
        accessibilityTraits = canActivate ? .button : .staticText
        accessibilityValue = nil
        accessibilityHint = nil
        switch state {
        case .loading:
            accessibilityLabel = Text.loading
        case .ready:
            accessibilityLabel = L10n.Common.loadMore
        case .empty:
            accessibilityLabel = Text.empty
            accessibilityHint = canActivate ? L10n.Common.retry : nil
        case .end:
            accessibilityLabel = Text.end
            accessibilityHint = canActivate ? L10n.Common.retry : nil
        case .error:
            accessibilityLabel = Text.error
        }
    }

    @discardableResult
    private func activate() -> Bool {
        guard canActivate, activationButton.canReceiveActivation, let onActivate else { return false }
        onActivate()
        return true
    }

    @objc private func handleActivate() {
        activate()
    }
}

/// ExploreShowAdapter / item_search.xml. Keep discovery geometry independent of search aggregation.
final class ExploreResultsBookCell: UITableViewCell {
    static let reuseIdentifier = "ExploreResultsBookCell"
    var onActivate: (() -> Void)?

    private struct CoverKey: Equatable {
        let url: String
        let origin: String
        let cover: String?
        let name: String
        let author: String
        let originName: String
        let toc: String
        let variable: String?

        init(_ book: SearchBook) {
            url = book.bookUrl
            origin = book.origin
            cover = book.coverUrl
            name = book.name
            author = book.author
            originName = book.originName
            toc = book.tocUrl
            variable = book.variable
        }
    }

    private let coverView = AndroidBookCoverClipView(frame: .zero)
    private let defaultCover = AndroidDefaultBookCoverView()
    private let coverImage = UIImageView()
    private let titleLabel = AndroidExploreTextLabel()
    private let bookshelfDot = UIView()
    private let metadata = ExploreResultsBookMetadataView()
    private var titleLeading: NSLayoutConstraint!
    private var coverKey: CoverKey?
    private var coverBook: SearchBook?
    private var coverRequestID = UUID()
    private var coverTask: Task<Void, Never>?
    // Paused loads remain pending; completed failures wait for the next full bind to retry.
    private var needsCoverLoad = false
    private var isPresentationActive = false

    var needsCoverRetry: Bool {
        guard let coverKey, !needsCoverLoad, coverTask == nil, coverImage.image == nil else { return false }
        let path = coverKey.cover?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !path.isEmpty && path != "use_default_cover"
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = AndroidReplicaTheme.background
        contentView.backgroundColor = AndroidReplicaTheme.background
        selectionStyle = .default
        let selected = UIView()
        selected.backgroundColor = AndroidReplicaTheme.activeIndicator
        selectedBackgroundView = selected
        isAccessibilityElement = true
        accessibilityIdentifier = UIIdentifiers.Discovery.resultCell
        accessibilityTraits = .button
        accessibilityHint = L10n.Bookshelf.openDetailHint
        contentView.accessibilityElementsHidden = true

        coverImage.contentMode = .scaleAspectFill
        coverImage.clipsToBounds = true
        titleLabel.textColor = AndroidReplicaTheme.primaryText
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.adjustsFontForContentSizeCategory = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        bookshelfDot.backgroundColor = UIColor(red: 67 / 255, green: 160 / 255, blue: 71 / 255, alpha: 1)
        bookshelfDot.layer.cornerRadius = 4

        for child in [defaultCover, coverImage] {
            child.translatesAutoresizingMaskIntoConstraints = false
            coverView.addSubview(child)
            NSLayoutConstraint.activate([
                child.topAnchor.constraint(equalTo: coverView.topAnchor),
                child.bottomAnchor.constraint(equalTo: coverView.bottomAnchor),
                child.leadingAnchor.constraint(equalTo: coverView.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: coverView.trailingAnchor),
            ])
        }
        for child in [coverView, titleLabel, bookshelfDot, metadata] {
            child.translatesAutoresizingMaskIntoConstraints = false
            child.isAccessibilityElement = false
            contentView.addSubview(child)
        }
        titleLeading = titleLabel.leadingAnchor.constraint(equalTo: coverView.trailingAnchor, constant: 8)
        NSLayoutConstraint.activate([
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 128),
            coverView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            coverView.widthAnchor.constraint(equalToConstant: 80),
            // CoverImageView overrides the XML height in both setLayoutParams and onMeasure.
            coverView.heightAnchor.constraint(equalTo: coverView.widthAnchor, multiplier: 7.0 / 5.0),
            coverView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            coverView.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 8),
            coverView.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -8),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            titleLeading,
            // BadgeView stays INVISIBLE at zero: retain its 16dp slot and both 8dp margins.
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -32),
            titleLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 0),
            bookshelfDot.leadingAnchor.constraint(equalTo: coverView.trailingAnchor, constant: 8),
            bookshelfDot.topAnchor.constraint(equalTo: titleLabel.topAnchor, constant: 8),
            bookshelfDot.widthAnchor.constraint(equalToConstant: 8),
            bookshelfDot.heightAnchor.constraint(equalToConstant: 8),
            metadata.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            metadata.leadingAnchor.constraint(equalTo: coverView.trailingAnchor, constant: 8),
            metadata.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            metadata.bottomAnchor.constraint(equalTo: coverView.bottomAnchor),
            metadata.heightAnchor.constraint(greaterThanOrEqualToConstant: 0),
        ])
        updateTypography()
        setInBookshelf(false)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit { coverTask?.cancel() }

    func configure(book: SearchBook, isInBookshelf: Bool) {
        // item_search uses singleLine, not just maxLines=1: line breaks become inline text.
        titleLabel.text = book.name.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: "\u{FEFF}")
        metadata.configure(book)
        accessibilityLabel = book.name
        setInBookshelf(isInBookshelf)
        configureCover(book)
    }

    func setInBookshelf(_ value: Bool) {
        bookshelfDot.isHidden = !value
        titleLeading.constant = value ? 24 : 8
        accessibilityValue = metadata.accessibilitySummary + (value ? "，已在书架" : "，未在书架")
    }

    func setPresentationActive(_ active: Bool) {
        isPresentationActive = active
        accessibilityElementsHidden = !active
        if active { loadCoverIfNeeded() } else { cancelCoverLoading() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { cancelCoverLoading() } else { loadCoverIfNeeded() }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        setPresentationActive(false)
        coverKey = nil
        coverBook = nil
        defaultCover.onLoadingPolicyChange = nil
        needsCoverLoad = false
        coverImage.image = nil
        defaultCover.configure(name: nil, author: nil)
        defaultCover.isHidden = false
        titleLabel.text = nil
        metadata.reset()
        onActivate = nil
        setInBookshelf(false)
        accessibilityLabel = nil
        accessibilityValue = nil
    }

    override func accessibilityActivate() -> Bool {
        guard isPresentationActive, ExploreAndroidGraphics.isAvailableForInteraction(self), let onActivate else { return false }
        onActivate()
        return true
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateTypography()
        setNeedsLayout()
    }

    private func updateTypography() {
        titleLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 16, textStyle: .body, compatibleWith: traitCollection)
    }

    private func configureCover(_ book: SearchBook) {
        defaultCover.onLoadingPolicyChange = { [weak self] in
            guard let self, let book = self.coverBook else { return }
            self.coverKey = nil
            self.configureCover(book)
        }
        let key = CoverKey(book)
        // A full Android bind retries failed covers; keep successful and in-flight requests intact.
        if coverKey != key {
            cancelCoverLoading()
            coverKey = key
            coverImage.image = nil
            defaultCover.configure(name: book.name, author: book.author)
            defaultCover.isHidden = false
            let path = book.coverUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            needsCoverLoad = !path.isEmpty && path != "use_default_cover"
        } else if needsCoverRetry {
            needsCoverLoad = true
        }
        coverBook = book
        loadCoverIfNeeded()
    }

    private func cancelCoverLoading() {
        coverRequestID = UUID()
        coverTask?.cancel()
        coverTask = nil
    }

    private func loadCoverIfNeeded() {
        guard isPresentationActive, window?.windowScene?.activationState == .foregroundActive,
            needsCoverLoad, coverTask == nil, let book = coverBook
        else { return }
        let request = coverRequestID
        coverTask = Task { @MainActor [weak self] in
            let image = await BookCoverImageLoader.loadDecodedCover(searchBook: book)
            guard !Task.isCancelled, let self, self.coverRequestID == request else { return }
            self.coverTask = nil
            guard self.isPresentationActive, self.window?.windowScene?.activationState == .foregroundActive else { return }
            self.needsCoverLoad = false
            self.coverImage.image = image
            self.defaultCover.isHidden = image != nil
        }
    }
}

private final class ExploreResultsBookMetadataView: UIView {
    private let author = AndroidExploreTextLabel()
    private let latest = AndroidExploreTextLabel()
    private let intro = ExploreResultsIntroLabel()
    private var kinds: [ExploreResultsKindLabel] = []
    private var kindValues: [String] = []
    private(set) var accessibilitySummary = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        for label in [author, latest, intro] {
            label.textColor = AndroidReplicaTheme.primaryText
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            label.adjustsFontForContentSizeCategory = false
            addSubview(label)
        }
        updateTypography()
    }

    convenience init() { self.init(frame: .zero) }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    func configure(_ book: SearchBook) {
        author.text = "作者：\(book.author)"
        latest.text = book.latestChapterTitle.flatMap { $0.isEmpty ? nil : "最新：\($0)" }
        latest.isHidden = latest.text == nil
        let description = book.intro?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        intro.text = "简介：" + (description.isEmpty ? "暂无简介" : description)
        var values: [String] = []
        if let count = book.wordCount, !count.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { values.append(count) }
        values += (book.kind ?? "").components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        kindValues = values
        while kinds.count < values.count {
            let label = ExploreResultsKindLabel()
            kinds.append(label)
            addSubview(label)
        }
        for (index, label) in kinds.enumerated() {
            label.text = index < values.count ? values[index] : nil
            label.isHidden = index >= values.count
        }
        accessibilitySummary = [author.text, values.isEmpty ? nil : values.joined(separator: "，"), latest.text, intro.text]
            .compactMap { $0 }.joined(separator: "，")
        updateTypography()
        setNeedsLayout()
    }

    func reset() {
        for label in [author, latest, intro] { label.text = nil }
        for label in kinds {
            label.text = nil
            label.isHidden = true
        }
        kindValues = []
        accessibilitySummary = ""
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateTypography()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let authorHeight = ceil(author.intrinsicContentSize.height)
        author.frame = CGRect(x: 0, y: 0, width: bounds.width, height: authorHeight)
        var y = authorHeight
        if !kindValues.isEmpty {
            let kindHeight = kinds.prefix(kindValues.count).map { ceil($0.intrinsicContentSize.height) }.max() ?? 0
            let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
            var x: CGFloat = 0
            for label in kinds.prefix(kindValues.count) {
                let available = max(0, bounds.width - x - 2)
                let width = min(available, label.intrinsicContentSize.width)
                label.isHidden = available <= 0
                label.frame = CGRect(
                    x: isRTL ? bounds.width - x - width : x, y: y, width: width, height: kindHeight)
                x += width + 2
            }
            y += kindHeight
        }
        if !latest.isHidden {
            let latestHeight = ceil(latest.intrinsicContentSize.height)
            latest.frame = CGRect(x: 0, y: y, width: bounds.width, height: latestHeight)
            y += latestHeight
        }
        let height = max(0, bounds.height - y)
        let lines = max(0, Int(floor(height / max(1, ceil(intro.font.lineHeight)))))
        intro.isHidden = lines == 0
        intro.numberOfLines = max(1, lines)
        intro.frame = CGRect(x: 0, y: y, width: bounds.width, height: height)
    }

    private func updateTypography() {
        let font = ReaderAndroidDefaultFont.scaledFont(
            size: 12, textStyle: .caption1, compatibleWith: traitCollection)
        for label in [author, latest, intro] + kinds { label.font = font }
    }
}

private final class ExploreResultsKindLabel: AndroidExploreTextLabel {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = AndroidReplicaTheme.accent
        textColor = UIColor { traits in
            let color = AndroidReplicaTheme.accent.resolvedColor(with: traits)
            var r: CGFloat = 0
            var g: CGFloat = 0
            var b: CGFloat = 0
            var a: CGFloat = 0
            guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return .white }
            func linear(_ value: CGFloat) -> CGFloat {
                value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b) >= 0.5 ? .black : .white
        }
        layer.cornerRadius = 2
        clipsToBounds = true
        numberOfLines = 1
        lineBreakMode = .byClipping
    }

    convenience init() { self.init(frame: .zero) }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: ceil(size.width) + 6, height: ceil(size.height))
    }

    override func drawText(in rect: CGRect) {
        let inset = min(3, rect.width / 2)
        super.drawText(in: rect.insetBy(dx: inset, dy: 0))
    }
}

private final class ExploreResultsIntroLabel: AndroidExploreTextLabel {
    override func drawText(in rect: CGRect) {
        let padding = fontPadding
        let textBounds = rect.inset(by: padding)
        guard textBounds.width > 0, textBounds.height > 0 else { return }
        let height = min(
            textBounds.height, ceil(textRect(forBounds: textBounds, limitedToNumberOfLines: numberOfLines).height))
        super.drawText(
            in: CGRect(
                x: rect.minX, y: rect.minY, width: rect.width,
                height: height + padding.top + padding.bottom))
    }
}
