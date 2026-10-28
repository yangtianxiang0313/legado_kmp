import UIKit
import shared

final class AndroidSearchResultCell: UITableViewCell {
    static let reuseIdentifier = "AndroidSearchResultCell"

    var onActivate: (() -> Void)?

    private let coverClipView = AndroidBookCoverClipView(frame: .zero)
    private let defaultCoverView = AndroidDefaultBookCoverView()
    private let coverImageView = UIImageView()
    private let bookshelfDotView = UIView()
    private let titleLabel = AndroidExploreTextLabel()
    private let originBadge = AndroidSearchInsetLabel(
        insets: UIEdgeInsets(top: 1, left: 5, bottom: 1, right: 5),
        minimumSize: CGSize(width: 16, height: 16)
    )
    private let authorLabel = AndroidExploreTextLabel()
    private let kindBar = AndroidSearchKindBar()
    private let latestLabel = AndroidExploreTextLabel()
    private let introLabel = AndroidSearchIntroLabel()
    private lazy var metadataView = AndroidSearchMetadataView(
        rows: [authorLabel, kindBar, latestLabel], introView: introLabel
    )
    private var metadataAccessibilityValue = ""
    private var coverTask: Task<Void, Never>?
    private var coverRequestID = UUID()
    private var coverRequestKey: CoverRequestKey?
    private var coverBook: SearchBook?
    private var needsCoverLoad = false
    private var isPresentationActive = false
    private var titleLeadingConstraint: NSLayoutConstraint?

    private struct CoverRequestKey: Equatable {
        let bookUrl: String
        let origin: String
        let coverUrl: String?
        let name: String
        let author: String
        let originName: String
        let tocUrl: String
        let variable: String?

        init(book: SearchBook) {
            bookUrl = book.bookUrl
            origin = book.origin
            coverUrl = book.coverUrl
            name = book.name
            author = book.author
            originName = book.originName
            tocUrl = book.tocUrl
            variable = book.variable
        }
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        configureViews()
        installConstraints()
        updateFonts()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    deinit { coverTask?.cancel() }

    override func prepareForReuse() {
        super.prepareForReuse()
        setPresentationActive(false)
        coverRequestKey = nil
        coverBook = nil
        defaultCoverView.onLoadingPolicyChange = nil
        needsCoverLoad = false
        coverImageView.image = nil
        defaultCoverView.configure(name: "", author: "")
        defaultCoverView.isHidden = false
        titleLabel.text = nil
        authorLabel.text = nil
        kindBar.setLabels([])
        latestLabel.text = nil
        latestLabel.isHidden = true
        introLabel.text = nil
        originBadge.text = nil
        originBadge.isHidden = true
        bookshelfDotView.isHidden = true
        titleLeadingConstraint?.constant = 8
        onActivate = nil
        accessibilityLabel = nil
        accessibilityValue = nil
        metadataAccessibilityValue = ""
    }

    override func accessibilityActivate() -> Bool {
        guard isPresentationActive else { return false }
        guard let onActivate else { return super.accessibilityActivate() }
        onActivate()
        return true
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

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory
            || previousTraitCollection?.displayScale != traitCollection.displayScale
        {
            updateFonts()
        }
    }

    func configure(book: SearchBook, isInBookshelf: Bool, showsOriginCount: Bool = true) {
        // item_search's singleLine transformation keeps the rest of a multiline name inline.
        titleLabel.text = book.name.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: "\u{FEFF}")
        // tv_author / tv_lasted use lines=1, not singleLine; retain their source text.
        authorLabel.text = "作者：\(book.author)"

        let kinds = kindLabels(for: book)
        kindBar.setLabels(kinds)
        // SearchAdapter.upLasted checks isNullOrEmpty; whitespace remains a visible row.
        let latest = book.latestChapterTitle
        latestLabel.text = latest.flatMap { $0.isEmpty ? nil : "最新：\($0)" }
        latestLabel.isHidden = latestLabel.text == nil
        let intro = book.intro?.trimmingCharacters(in: .whitespacesAndNewlines)
        introLabel.text = "简介：\(intro.flatMap { $0.isEmpty ? nil : $0 } ?? "暂无简介")"

        // Android BadgeView 隐藏零计数，但仍保留最小占位尺寸。
        let originCount = book.origins.count
        originBadge.text = originCount == 0 ? nil : String(originCount)
        originBadge.isHidden = !showsOriginCount || originCount == 0

        accessibilityLabel = book.name
        metadataAccessibilityValue = [
            "作者：\(book.author)",
            kinds.isEmpty ? nil : kinds.joined(separator: "，"),
            latestLabel.isHidden ? nil : "最新：\(book.latestChapterTitle ?? "")",
            introLabel.text,
            "书源数量：\(originCount)",
        ].compactMap { $0 }.joined(separator: "，")
        setInBookshelf(isInBookshelf)
        configureCover(book: book)
        metadataView.setNeedsLayout()
        setNeedsLayout()
    }

    private func configureCover(book: SearchBook) {
        defaultCoverView.onLoadingPolicyChange = { [weak self] in
            guard let self, let book = self.coverBook else { return }
            self.coverRequestKey = nil
            self.configureCover(book: book)
        }
        let key = CoverRequestKey(book: book)
        // Count/latest-chapter payloads must not restart the same cover or flash its placeholder.
        guard coverRequestKey != key else {
            loadCoverIfNeeded()
            return
        }
        cancelCoverLoading()
        coverRequestKey = key
        coverBook = book
        coverImageView.image = nil
        defaultCoverView.configure(name: book.name, author: book.author)
        defaultCoverView.isHidden = false
        let path = book.coverUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        needsCoverLoad = !path.isEmpty && path != "use_default_cover"
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
        let requestID = coverRequestID
        coverTask = Task { @MainActor [weak self] in
            let image = await BookCoverImageLoader.loadDecodedCover(searchBook: book)
            guard !Task.isCancelled, let self, self.coverRequestID == requestID
            else { return }
            self.coverTask = nil
            guard self.isPresentationActive, self.window?.windowScene?.activationState == .foregroundActive else { return }
            self.needsCoverLoad = false
            self.coverImageView.image = image
            self.defaultCoverView.isHidden = image != nil
        }
    }

    func setInBookshelf(_ isInBookshelf: Bool) {
        // SearchAdapter uses isVisible (GONE), unlike the badge's INVISIBLE zero state.
        bookshelfDotView.isHidden = !isInBookshelf
        titleLeadingConstraint?.constant = isInBookshelf ? 24 : 8
        accessibilityValue = metadataAccessibilityValue + (isInBookshelf ? "，已在书架" : "，未在书架")
        setNeedsLayout()
    }

    private func configureViews() {
        backgroundColor = AndroidReplicaTheme.background
        contentView.backgroundColor = AndroidReplicaTheme.background
        accessoryType = .none
        selectionStyle = .default
        let selectedView = UIView()
        selectedView.backgroundColor = AndroidReplicaTheme.activeIndicator
        selectedBackgroundView = selectedView

        isAccessibilityElement = true
        accessibilityTraits = [.button]
        accessibilityIdentifier = UIIdentifiers.Search.resultCell
        accessibilityHint = L10n.Bookshelf.openDetailHint
        contentView.isAccessibilityElement = false
        contentView.accessibilityElementsHidden = true

        coverImageView.contentMode = .scaleAspectFill
        coverImageView.clipsToBounds = true

        bookshelfDotView.backgroundColor = UIColor(red: 67 / 255, green: 160 / 255, blue: 71 / 255, alpha: 1)
        bookshelfDotView.layer.cornerRadius = 4
        bookshelfDotView.isHidden = true

        for label in [titleLabel, authorLabel, latestLabel, introLabel] {
            label.textColor = AndroidReplicaTheme.primaryText
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentCompressionResistancePriority(.required, for: .vertical)
            label.setContentHuggingPriority(.required, for: .vertical)
            label.isAccessibilityElement = false
        }
        introLabel.numberOfLines = 0
        introLabel.setContentHuggingPriority(UILayoutPriority(249), for: .vertical)
        latestLabel.isHidden = true

        originBadge.font = .systemFont(ofSize: 11)
        originBadge.textColor = UIColor { traits in SearchScopeStyle.checkedTextColor(traits: traits) }
        originBadge.backgroundColor = AndroidReplicaTheme.accent
        originBadge.layer.cornerRadius = 8
        originBadge.clipsToBounds = true
        originBadge.textAlignment = .center
        originBadge.numberOfLines = 1
        originBadge.isHidden = true
        originBadge.setContentHuggingPriority(.required, for: .horizontal)
        originBadge.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        for item in [defaultCoverView, coverImageView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            item.isAccessibilityElement = false
            coverClipView.addSubview(item)
        }
        for item in [coverClipView, bookshelfDotView, titleLabel, originBadge, metadataView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            item.isAccessibilityElement = false
            contentView.addSubview(item)
        }
    }

    private func installConstraints() {
        let titleLeading = titleLabel.leadingAnchor.constraint(equalTo: coverClipView.trailingAnchor, constant: 8)
        titleLeadingConstraint = titleLeading
        NSLayoutConstraint.activate([
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 128),
            coverClipView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            coverClipView.widthAnchor.constraint(equalToConstant: 80),
            coverClipView.heightAnchor.constraint(equalToConstant: 112),
            coverClipView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            coverClipView.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 8),
            coverClipView.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -8),
            defaultCoverView.topAnchor.constraint(equalTo: coverClipView.topAnchor),
            defaultCoverView.leadingAnchor.constraint(equalTo: coverClipView.leadingAnchor),
            defaultCoverView.trailingAnchor.constraint(equalTo: coverClipView.trailingAnchor),
            defaultCoverView.bottomAnchor.constraint(equalTo: coverClipView.bottomAnchor),
            coverImageView.topAnchor.constraint(equalTo: coverClipView.topAnchor),
            coverImageView.leadingAnchor.constraint(equalTo: coverClipView.leadingAnchor),
            coverImageView.trailingAnchor.constraint(equalTo: coverClipView.trailingAnchor),
            coverImageView.bottomAnchor.constraint(equalTo: coverClipView.bottomAnchor),

            originBadge.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            originBadge.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            originBadge.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -8),

            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            titleLeading,
            titleLabel.trailingAnchor.constraint(equalTo: originBadge.leadingAnchor, constant: -8),
            titleLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 0),
            bookshelfDotView.leadingAnchor.constraint(equalTo: coverClipView.trailingAnchor, constant: 8),
            bookshelfDotView.topAnchor.constraint(equalTo: titleLabel.topAnchor, constant: 8),
            bookshelfDotView.widthAnchor.constraint(equalToConstant: 8),
            bookshelfDotView.heightAnchor.constraint(equalToConstant: 8),

            metadataView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            metadataView.leadingAnchor.constraint(equalTo: coverClipView.trailingAnchor, constant: 8),
            metadataView.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            metadataView.bottomAnchor.constraint(equalTo: coverClipView.bottomAnchor),
            metadataView.heightAnchor.constraint(greaterThanOrEqualToConstant: 0),
        ])
    }

    private func updateFonts() {
        titleLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 16, textStyle: .body, compatibleWith: traitCollection)
        let detailFont = ReaderAndroidDefaultFont.scaledFont(
            size: 12, textStyle: .caption1, compatibleWith: traitCollection)
        for label in [authorLabel, latestLabel, introLabel] {
            label.font = detailFont
            label.invalidateIntrinsicContentSize()
        }
        kindBar.font = detailFont
        originBadge.font = ReaderAndroidDefaultFont.scaledFont(
            size: 11, textStyle: .caption2, compatibleWith: traitCollection)
        metadataView.setNeedsLayout()
        setNeedsLayout()
    }

    private func kindLabels(for book: SearchBook) -> [String] {
        var labels: [String] = []
        if let wordCount = book.wordCount, !wordCount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            labels.append(wordCount)
        }
        labels += (book.kind ?? "").components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return labels
    }
}

private final class AndroidSearchMetadataView: UIView {
    private let rows: [UIView]
    private let introView: UIView

    init(rows: [UIView], introView: UIView) {
        self.rows = rows
        self.introView = introView
        super.init(frame: .zero)
        clipsToBounds = true
        for view in rows + [introView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Android's fixed-height LinearLayout clips metadata; the intro gets only its remainder.
        var y: CGFloat = 0
        for view in rows where !view.isHidden {
            let height = max(0, ceil(view.intrinsicContentSize.height))
            view.frame = CGRect(x: 0, y: y, width: bounds.width, height: height)
            y += height
        }
        introView.frame = CGRect(x: 0, y: y, width: bounds.width, height: max(0, bounds.height - y))
    }
}

// 简介只占剩余行高，不以完整文本高度撑开搜索结果。
private final class AndroidSearchIntroLabel: AndroidExploreTextLabel {
    override var intrinsicContentSize: CGSize {
        CGSize(
            width: UIView.noIntrinsicMetric,
            height: ceil(font.lineHeight) + fontPadding.top + fontPadding.bottom)
    }

    override func layoutSubviews() {
        let lines = max(1, Int(floor(bounds.height / max(1, ceil(font.lineHeight)))))
        if numberOfLines != lines { numberOfLines = lines }
        super.layoutSubviews()
    }

    override func drawText(in rect: CGRect) {
        let lineHeight = max(1, ceil(font.lineHeight))
        let lines = Int(floor(rect.height / lineHeight))
        guard lines > 0, rect.width > 0 else { return }
        let padding = fontPadding
        let textBounds = rect.inset(by: padding)
        guard textBounds.height > 0 else { return }
        let height = min(textBounds.height, ceil(textRect(forBounds: textBounds, limitedToNumberOfLines: lines).height))
        super.drawText(
            in: CGRect(
                x: rect.minX, y: rect.minY, width: rect.width,
                height: height + padding.top + padding.bottom))
    }
}

private final class AndroidSearchInsetLabel: AndroidExploreTextLabel {
    private let insets: UIEdgeInsets
    private let minimumSize: CGSize

    init(insets: UIEdgeInsets, minimumSize: CGSize = .zero) {
        self.insets = insets
        self.minimumSize = minimumSize
        super.init(frame: .zero)
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(
            width: max(minimumSize.width, ceil(size.width) + insets.left + insets.right),
            height: max(minimumSize.height, ceil(size.height) + insets.top + insets.bottom)
        )
    }

    override func drawText(in rect: CGRect) {
        let textRect = rect.inset(by: insets)
        guard textRect.width > 0, textRect.height > 0 else { return }
        super.drawText(in: textRect)
    }
}

private final class AndroidSearchKindBar: UIView {
    var font = UIFont.systemFont(ofSize: 12) {
        didSet {
            for label in labels { label.font = font }
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }

    private var labels: [AndroidSearchInsetLabel] = []
    private var labelValues: [String] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        isHidden = true
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(
            width: UIView.noIntrinsicMetric,
            height: labels.prefix(labelValues.count).map { $0.intrinsicContentSize.height }.max() ?? 0
        )
    }

    func setLabels(_ values: [String]) {
        guard labelValues != values else { return }
        labelValues = values
        while labels.count < values.count {
            let label = makeLabel()
            labels.append(label)
            addSubview(label)
        }
        for (index, label) in labels.enumerated() {
            if index < values.count {
                label.text = values[index]
                label.isHidden = false
            } else {
                label.text = nil
                label.isHidden = true
                label.frame = .zero
            }
        }
        isHidden = values.isEmpty
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private func makeLabel() -> AndroidSearchInsetLabel {
        let label = AndroidSearchInsetLabel(insets: UIEdgeInsets(top: 0, left: 3, bottom: 0, right: 3))
        label.font = font
        label.numberOfLines = 1
        label.lineBreakMode = .byClipping
        label.textAlignment = .natural
        label.backgroundColor = AndroidReplicaTheme.accent
        // BadgeView and AccentBgTextView use the same accent luminance threshold.
        label.textColor = UIColor { traits in SearchScopeStyle.checkedTextColor(traits: traits) }
        label.layer.cornerRadius = 2
        label.clipsToBounds = true
        return label
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
        var offset: CGFloat = 0
        for label in labels.prefix(labelValues.count) {
            let remainingWidth = max(0, bounds.width - offset - 2)
            label.isHidden = remainingWidth <= 0
            guard !label.isHidden else {
                label.frame = .zero
                continue
            }
            let width = min(label.intrinsicContentSize.width, remainingWidth)
            let x = isRTL ? bounds.maxX - offset - width : bounds.minX + offset
            label.frame = CGRect(x: x, y: bounds.minY, width: width, height: max(0, bounds.height))
            offset += width + 2
        }
    }
}
