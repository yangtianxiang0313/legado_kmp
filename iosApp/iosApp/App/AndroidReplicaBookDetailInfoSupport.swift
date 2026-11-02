import UIKit

enum BookDetailPresentationText {
    static var authorFormat: String {
        Bundle.main.localizedString(forKey: "book_detail.author_format", value: "作者：%@", table: nil)
    }

    static var coverLabel: String {
        Bundle.main.localizedString(forKey: "book_detail.cover_accessibility_label", value: "封面", table: nil)
    }

    static var previewCover: String {
        Bundle.main.localizedString(forKey: "book_detail.preview_cover", value: "预览封面", table: nil)
    }

    static var loading: String {
        Bundle.main.localizedString(forKey: "book_detail.android_loading", value: "加载中…", table: nil)
    }
}

enum BookDetailActionPalette {
    static let shelfText = UIColor { traits in
        ReaderPaletteColor.primaryText(on: AndroidReplicaTheme.bottomBackground.resolvedColor(with: traits))
    }

    static let accentText = UIColor { traits in
        ReaderPaletteColor.isLight(AndroidReplicaTheme.accent.resolvedColor(with: traits)) ? .black : .white
    }

    static let pressedAccent = UIColor { traits in
        let color = AndroidReplicaTheme.accent.resolvedColor(with: traits)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return UIColor(red: red * 0.9, green: green * 0.9, blue: blue * 0.9, alpha: alpha)
    }
}

enum AndroidReplicaBookDetailTypography {
    // activity_book_info.xml uses tv_text_summary, not secondaryText, for the info rows.
    static let summaryText = AndroidReplicaTheme.summaryText

    static func font(size: CGFloat, compatibleWith traits: UITraitCollection) -> UIFont {
        ReaderAndroidDefaultFont.scaledFont(size: size, textStyle: .body, compatibleWith: traits)
    }

    static func iconSize(compatibleWith traits: UITraitCollection) -> CGFloat {
        UIFontMetrics(forTextStyle: .body).scaledValue(for: 18, compatibleWith: traits)
    }
}

// Asset names are reserved for the original drawables at Legado 5f5d31404.
enum AndroidReplicaBookDetailInfoIcon: String {
    case author = "BookDetailAndroidAuthor"  // drawable/ic_author.xml
    case web = "BookDetailAndroidWeb"  // drawable/ic_web_outline.xml
    case last = "BookDetailAndroidBookLast"  // drawable/ic_book_last.xml
    case groups = "BookDetailAndroidGroups"  // drawable/ic_groups.xml
    case folder = "BookDetailAndroidFolderOpen"  // drawable/ic_folder_open.xml

    var image: UIImage? {
        let fallback: String
        switch self {
        case .author: fallback = "person.crop.circle"
        case .web: fallback = "globe"
        case .last: fallback = "safari"
        case .groups: fallback = "flowchart"
        case .folder: fallback = "folder"
        }
        return (UIImage(named: rawValue) ?? UIImage(systemName: fallback))?
            .withRenderingMode(.alwaysTemplate)
    }
}

// Metadata TextViews disable includeFontPadding; LabelsBar badges and accent actions keep their defaults.
final class AndroidReplicaBookDetailMetadataLabel: AndroidExploreTextLabel {
    override var fontPadding: UIEdgeInsets { .zero }
}

// AccentBgTextView is text with a 2dp background, without platform button chrome or minimum height.
final class AndroidReplicaBookDetailTextButton: ReaderMenuPressButton {
    private let fontSize: CGFloat
    private let hasAccentBackground: Bool
    private let includesFontPadding: Bool
    private var textFont = UIFont.systemFont(ofSize: 13)

    override var bounds: CGRect {
        didSet {
            if hasAccentBackground, bounds.width != oldValue.width {
                invalidateIntrinsicContentSize()
            }
        }
    }

    init(
        fontSize: CGFloat, textColor: UIColor, accentBackground: Bool = false,
        includesFontPadding: Bool = true
    ) {
        self.fontSize = fontSize
        hasAccentBackground = accentBackground
        self.includesFontPadding = includesFontPadding
        super.init(frame: .zero)
        showsBorderlessFeedback = false
        configuration = nil
        automaticallyUpdatesConfiguration = false
        contentEdgeInsets = UIEdgeInsets(
            top: 0, left: accentBackground ? 5 : 0, bottom: 0, right: accentBackground ? 5 : 0)
        setTitleColor(textColor, for: .normal)
        setTitleColor(textColor, for: .disabled)
        // Only the metadata TextViews are singleLine; AccentBgTextView actions can wrap.
        titleLabel?.numberOfLines = accentBackground ? 0 : 1
        titleLabel?.lineBreakMode = accentBackground ? .byWordWrapping : .byTruncatingTail
        titleLabel?.textAlignment = accentBackground ? .center : .natural
        titleLabel?.adjustsFontForContentSizeCategory = false
        titleLabel?.adjustsFontSizeToFitWidth = false
        setContentCompressionResistancePriority(.required, for: .vertical)
        layer.cornerRadius = accentBackground ? 2 : 0
        refreshTypography()
        refreshPalette()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override var isHighlighted: Bool {
        didSet { updateBackground() }
    }

    override var isEnabled: Bool {
        didSet {
            updateBackground()
        }
    }

    override func setTitle(_ title: String?, for state: UIControl.State) {
        if title != self.title(for: state) { cancelTracking(with: nil) }
        super.setTitle(title, for: state)
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override var intrinsicContentSize: CGSize {
        measuredSize(constrainedTo: hasAccentBackground && bounds.width > 0 ? bounds.width : .greatestFiniteMagnitude)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let measured = measuredSize(constrainedTo: max(1, size.width))
        return CGSize(width: min(max(0, size.width), measured.width), height: measured.height)
    }

    private func measuredSize(constrainedTo width: CGFloat) -> CGSize {
        let font = textFont
        let title = currentTitle ?? ""
        let titleSize = title.size(withAttributes: [.font: font])
        var titleHeight = max(font.lineHeight, titleSize.height)
        if hasAccentBackground, width.isFinite {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            let textWidth = max(1, width - contentEdgeInsets.left - contentEdgeInsets.right)
            let wrappedSize = (title as NSString).boundingRect(
                with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font, .paragraphStyle: paragraph], context: nil)
            titleHeight = max(titleHeight, wrappedSize.height)
        }
        return CGSize(
            width: ceil(titleSize.width) + contentEdgeInsets.left + contentEdgeInsets.right,
            height: ceil(titleHeight + contentEdgeInsets.top + contentEdgeInsets.bottom))
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory
            || previousTraitCollection?.displayScale != traitCollection.displayScale
        {
            refreshTypography()
        }
    }

    func refreshTypography(compatibleWith traits: UITraitCollection? = nil) {
        let traits = traits ?? traitCollection
        textFont = AndroidReplicaBookDetailTypography.font(size: fontSize, compatibleWith: traits)
        titleLabel?.font = textFont
        let padding =
            includesFontPadding
            ? AndroidExploreTextMetrics.padding(font: textFont, scale: traits.displayScale) : .zero
        contentEdgeInsets = UIEdgeInsets(
            top: padding.top, left: hasAccentBackground ? 5 : 0,
            bottom: padding.bottom, right: hasAccentBackground ? 5 : 0)
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    func refreshPalette() {
        guard hasAccentBackground else { return }
        setTitleColor(BookDetailActionPalette.accentText, for: .normal)
        setTitleColor(BookDetailActionPalette.accentText, for: .disabled)
        updateBackground()
    }

    private func updateBackground() {
        guard hasAccentBackground else { return }
        backgroundColor =
            isEnabled && isHighlighted ? BookDetailActionPalette.pressedAccent : AndroidReplicaTheme.accent
    }
}

final class AndroidReplicaBookDetailInfoRow: UIView {
    private let iconView = UIImageView()
    private let contentStack = UIStackView()
    private var fullWidthConstraints: [NSLayoutConstraint] = []
    private var centeredConstraints: [NSLayoutConstraint] = []
    private var iconWidthConstraint: NSLayoutConstraint!
    private var iconHeightConstraint: NSLayoutConstraint!
    private var preferredHeightConstraint: NSLayoutConstraint!
    private var iconTrailingPadding: CGFloat = 2

    init(
        icon: AndroidReplicaBookDetailInfoIcon, content: UIView,
        action: UIButton? = nil, contentTrailingInset: CGFloat = 6
    ) {
        super.init(frame: .zero)
        iconView.image = icon.image
        iconView.contentMode = .scaleAspectFit
        iconView.tintColor = AndroidReplicaBookDetailTypography.summaryText
        iconView.isAccessibilityElement = false
        contentStack.axis = .horizontal
        contentStack.alignment = .center
        contentStack.spacing = 2
        contentStack.addArrangedSubview(iconView)
        contentStack.addArrangedSubview(content)
        content.setContentHuggingPriority(.defaultLow, for: .horizontal)
        content.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if let action {
            contentStack.addArrangedSubview(action)
            // TextView's 6dp right padding plus the action's 8dp start margin.
            contentStack.setCustomSpacing(14, after: content)
        }
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)
        iconWidthConstraint = iconView.widthAnchor.constraint(equalToConstant: 16)
        iconHeightConstraint = iconView.heightAnchor.constraint(equalToConstant: 18)
        preferredHeightConstraint = heightAnchor.constraint(equalToConstant: 24)
        preferredHeightConstraint.priority = .defaultHigh
        let top = contentStack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 3)
        let bottom = contentStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -3)
        let contentWidth = content.widthAnchor.constraint(greaterThanOrEqualToConstant: 0)
        // Hidden arranged rows must collapse, but visible rows must fit scaled text and icons.
        top.priority = UILayoutPriority(999)
        bottom.priority = UILayoutPriority(999)
        fullWidthConstraints = [
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentStack.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: action == nil ? -contentTrailingInset : 0),
        ]
        centeredConstraints = [
            contentStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ]
        NSLayoutConstraint.activate(
            [
                iconWidthConstraint, iconHeightConstraint, preferredHeightConstraint, top, bottom, contentWidth,
                contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            ] + fullWidthConstraints)
        refreshMetrics()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory
            || previousTraitCollection?.displayScale != traitCollection.displayScale
        {
            refreshMetrics()
        }
    }

    func setContentCentered(_ centered: Bool) {
        NSLayoutConstraint.deactivate(fullWidthConstraints + centeredConstraints)
        NSLayoutConstraint.activate(centered ? centeredConstraints : fullWidthConstraints)
        iconTrailingPadding = centered ? 4 : 2
        contentStack.spacing = iconTrailingPadding
        refreshMetrics()
    }

    func refreshMetrics(compatibleWith traits: UITraitCollection? = nil) {
        let side = AndroidReplicaBookDetailTypography.iconSize(compatibleWith: traits ?? traitCollection)
        // Android paddingRight is inside the 18sp ImageView, not extra horizontal space.
        iconWidthConstraint.constant = max(0, side - iconTrailingPadding)
        iconHeightConstraint.constant = side
        preferredHeightConstraint.constant = ceil(side + 6)
        setNeedsLayout()
    }
}

final class BookDetailActionScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is UIControl || super.touchesShouldCancel(in: view)
    }
}

final class BookDetailHorizontalScrollRow: UIView {
    private let scrollView = BookDetailActionScrollView()
    private var viewportSize = CGSize.zero
    private var contentSize = CGSize.zero
    private var rowHeightConstraint: NSLayoutConstraint!

    init(content: UIView, height: CGFloat) {
        super.init(frame: .zero)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.scrollsToTop = false
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
}

// LabelsBar owns its badges, reuse pool and scroll geometry independently of the detail page.
final class BookDetailTagsView: UIView {
    private struct Badge {
        let view: UIView
        let label: UILabel
    }

    private let stack = UIStackView()
    private lazy var row = BookDetailHorizontalScrollRow(content: stack, height: 0)
    private var displayedTags: [String] = []
    private var badges: [Badge] = []
    private var unusedBadges: [Badge] = []

    var hasTags: Bool { !displayedTags.isEmpty }

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .horizontal
        stack.alignment = .fill
        stack.spacing = 2
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 2)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isHidden = true
        refreshTypography(compatibleWith: traitCollection)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    func render(kind: String?, wordCount: String?) {
        var tags: [String] = []
        // BaseBook.getKindList keeps wordCount verbatim before splitting kind.
        if let wordCount, !wordCount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tags.append(wordCount)
        }
        tags += (kind ?? "")
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard tags != displayedTags else { return }
        displayedTags = tags
        while badges.count > tags.count {
            let badge = badges.removeLast()
            stack.removeArrangedSubview(badge.view)
            badge.view.removeFromSuperview()
            unusedBadges.append(badge)
        }
        while badges.count < tags.count {
            let badge = unusedBadges.popLast() ?? makeBadge()
            stack.addArrangedSubview(badge.view)
            badges.append(badge)
        }
        for (badge, tag) in zip(badges, tags) where badge.label.text != tag {
            badge.label.text = tag
        }
        isHidden = tags.isEmpty
        row.resetOffset()
    }

    func refreshTypography(compatibleWith traits: UITraitCollection) {
        let font = AndroidReplicaBookDetailTypography.font(size: 12, compatibleWith: traits)
        let padding = AndroidExploreTextMetrics.padding(font: font, scale: traits.displayScale)
        row.setHeight(ceil(font.lineHeight + padding.top + padding.bottom))
        for badge in badges + unusedBadges { badge.label.font = font }
    }

    func refreshPalette() {
        for badge in badges + unusedBadges {
            badge.view.backgroundColor = AndroidReplicaTheme.accent
            badge.label.textColor = BookDetailActionPalette.accentText
        }
    }

    private func makeBadge() -> Badge {
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
        return Badge(view: badge, label: label)
    }
}
