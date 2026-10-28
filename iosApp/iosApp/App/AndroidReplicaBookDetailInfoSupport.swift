import UIKit

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
final class AndroidReplicaBookDetailTextButton: UIButton {
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

    override var intrinsicContentSize: CGSize {
        let font = textFont
        let title = currentTitle ?? ""
        let titleSize = title.size(withAttributes: [.font: font])
        var titleHeight = max(font.lineHeight, titleSize.height)
        if hasAccentBackground, bounds.width > 0 {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            let textWidth = max(1, bounds.width - contentEdgeInsets.left - contentEdgeInsets.right)
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
        backgroundColor = isHighlighted ? BookDetailActionPalette.pressedAccent : AndroidReplicaTheme.accent
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
