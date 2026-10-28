import CoreText
import UIKit
import shared

final class AndroidExploreSourceCell: UITableViewCell {
    static let reuseIdentifier = "AndroidExploreSourceCell"

    var onToggle: (() -> Void)?
    var onKindSelected: ((ExploreKind) -> Void)?
    var onShowMenu: ((UIView) -> Void)?

    private let stack = UIStackView()
    private let headerButton = AndroidExploreSourceHeaderButton(type: .custom)
    private let nameLabel = AndroidExploreTextLabel()
    private let loadingIndicator = BookshelfBookStatusLoadingView()
    private let statusImageView = UIImageView()
    private let kindsContainer = UIView()
    private let flowView = AndroidExploreKindFlowView()
    private var sourceURL: String?
    private var isExpanded = false
    private var isPresentationActive = true
    private var menuLongPress: UILongPressGestureRecognizer?
    private var bottomConstraint: NSLayoutConstraint?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        configureViews()
        installConstraints()
        updateFonts()
        resetContent()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        resetContent()
        setPresentationActive(true)
    }

    /// Optional host gate for a covered/off-page discovery list; old callers stay active.
    func setPresentationActive(_ active: Bool) {
        isPresentationActive = active
        accessibilityElementsHidden = !active
        loadingIndicator.setPresentationActive(active)
        headerButton.isEnabled = active && sourceURL != nil
        menuLongPress?.isEnabled = active && sourceURL != nil
        if !active {
            headerButton.resetInteraction()
        }
    }

    override func systemLayoutSizeFitting(
        _ targetSize: CGSize,
        withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority
    ) -> CGSize {
        // Resolve wrapping before automaticDimension asks Auto Layout for the row height.
        prepareTextLayout(width: targetSize.width)
        return super.systemLayoutSizeFitting(
            targetSize,
            withHorizontalFittingPriority: horizontalFittingPriority,
            verticalFittingPriority: verticalFittingPriority
        )
    }

    override func layoutSubviews() {
        prepareTextLayout(width: contentView.bounds.width)
        super.layoutSubviews()
    }

    private func prepareTextLayout(width: CGFloat) {
        guard width.isFinite, width > 0 else { return }
        flowView.prepareLayout(width: max(0, width - 48))
        // item_find_book: outer 16dp, title 10dp, arrow 20dp; loading adds 20dp + 4dp.
        let nameWidth = max(0, width - 72 - (loadingIndicator.isHidden ? 0 : 24))
        if nameLabel.preferredMaxLayoutWidth != nameWidth {
            nameLabel.preferredMaxLayoutWidth = nameWidth
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            updateFonts()
        }
        if sourceURL != nil, previousTraitCollection?.displayScale != traitCollection.displayScale {
            updateStatusImage()
        }
    }

    // Bind callbacks after configuring a newly represented source.
    func configure(
        source: BookSourcePart,
        isExpanded: Bool,
        isLoading: Bool,
        kinds: [ExploreKind],
        isLast: Bool = false
    ) {
        if sourceURL != source.bookSourceUrl {
            resetContent()
        }
        sourceURL = source.bookSourceUrl
        self.isExpanded = isExpanded
        bottomConstraint?.constant = isLast ? -12 : 0
        nameLabel.text = source.bookSourceName
        headerButton.accessibilityLabel = source.bookSourceName
        headerButton.accessibilityHint = isExpanded ? "收起分类" : "展开分类"
        headerButton.accessibilityTraits = isExpanded ? [.button, .selected] : [.button]
        headerButton.accessibilityValue = isExpanded && isLoading ? L10n.Discovery.loadingKinds : nil
        updateStatusImage()
        loadingIndicator.setRefreshing(isExpanded && isLoading)

        flowView.setKinds(isExpanded ? kinds : []) { [weak self] kind in
            guard let self, self.isExpanded, self.isPresentationActive,
                ExploreAndroidGraphics.isAvailableForInteraction(self)
            else { return }
            self.onKindSelected?(kind)
        }
        kindsContainer.isHidden = !isExpanded || kinds.isEmpty

        headerButton.isEnabled = isPresentationActive
        menuLongPress?.isEnabled = isPresentationActive
        stack.setCustomSpacing(kindsContainer.isHidden ? 0 : 8, after: headerButton)
        var accessibleItems: [Any] = [headerButton]
        if !kindsContainer.isHidden { accessibleItems.append(contentsOf: flowView.accessibilityElements ?? []) }
        accessibilityElements = accessibleItems
        setNeedsLayout()
    }

    private func configureViews() {
        backgroundColor = AndroidReplicaTheme.background
        contentView.backgroundColor = AndroidReplicaTheme.background
        selectionStyle = .none
        accessoryType = .none
        indentationWidth = 0
        isAccessibilityElement = false
        accessibilityIdentifier = UIIdentifiers.Discovery.sourceCell
        contentView.isAccessibilityElement = false

        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 0
        contentView.addSubview(stack)
        for item in [headerButton, kindsContainer] { stack.addArrangedSubview(item) }

        headerButton.layer.cornerRadius = 6
        headerButton.clipsToBounds = true
        headerButton.isAccessibilityElement = true
        headerButton.accessibilityIdentifier = "discovery.sourceHeader"
        headerButton.addTarget(self, action: #selector(toggleSource), for: .touchUpInside)
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(showMenu(_:)))
        longPress.cancelsTouchesInView = true
        headerButton.addGestureRecognizer(longPress)
        menuLongPress = longPress
        headerButton.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "更多操作", target: self, selector: #selector(accessibilityShowMenu))
        ]
        nameLabel.textColor = AndroidReplicaTheme.primaryText
        nameLabel.numberOfLines = 0
        nameLabel.lineBreakMode = .byWordWrapping
        nameLabel.isAccessibilityElement = false
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        loadingIndicator.loadingWidth = 1
        statusImageView.tintColor = AndroidReplicaTheme.secondaryText
        statusImageView.contentMode = .center
        statusImageView.isUserInteractionEnabled = false
        statusImageView.isAccessibilityElement = false

        kindsContainer.addSubview(flowView)
    }

    private func installConstraints() {
        stack.translatesAutoresizingMaskIntoConstraints = false
        flowView.translatesAutoresizingMaskIntoConstraints = false

        let statusStack = UIStackView(arrangedSubviews: [loadingIndicator, statusImageView])
        statusStack.axis = .horizontal
        statusStack.alignment = .center
        // GONE removes the loading slot AND its right margin; there is no name/arrow gap.
        statusStack.spacing = 0
        statusStack.setCustomSpacing(4, after: loadingIndicator)
        statusStack.isUserInteractionEnabled = false
        statusStack.setContentHuggingPriority(.required, for: .horizontal)
        statusStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        let titleStack = UIStackView(arrangedSubviews: [nameLabel, statusStack])
        titleStack.axis = .horizontal
        titleStack.alignment = .center
        titleStack.spacing = 0
        titleStack.isUserInteractionEnabled = false
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        headerButton.addSubview(titleStack)

        let loadingWidth = loadingIndicator.widthAnchor.constraint(equalToConstant: 20)
        loadingWidth.priority = UILayoutPriority(999)
        bottomConstraint = stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            bottomConstraint!,
            titleStack.topAnchor.constraint(equalTo: headerButton.topAnchor, constant: 6),
            titleStack.bottomAnchor.constraint(equalTo: headerButton.bottomAnchor, constant: -6),
            titleStack.leadingAnchor.constraint(equalTo: headerButton.leadingAnchor, constant: 10),
            titleStack.trailingAnchor.constraint(equalTo: headerButton.trailingAnchor, constant: -10),
            loadingWidth,
            loadingIndicator.heightAnchor.constraint(equalToConstant: 20),
            statusImageView.widthAnchor.constraint(equalToConstant: 20),
            statusImageView.heightAnchor.constraint(equalToConstant: 20),
            flowView.topAnchor.constraint(equalTo: kindsContainer.topAnchor),
            flowView.bottomAnchor.constraint(equalTo: kindsContainer.bottomAnchor),
            flowView.leadingAnchor.constraint(equalTo: kindsContainer.leadingAnchor, constant: 8),
            flowView.trailingAnchor.constraint(equalTo: kindsContainer.trailingAnchor, constant: -8),
        ])
    }

    private func updateFonts() {
        let font = AndroidExploreTextMetrics.font(compatibleWith: traitCollection)
        nameLabel.font = font
        nameLabel.adjustsFontForContentSizeCategory = false
        flowView.updateFonts()
        setNeedsLayout()
    }

    private func updateStatusImage() {
        statusImageView.image = ExploreAndroidGraphics.arrow(
            isExpanded ? .down : .right, scale: traitCollection.displayScale)
    }

    private func resetContent() {
        onToggle = nil
        onKindSelected = nil
        onShowMenu = nil
        sourceURL = nil
        isExpanded = false
        menuLongPress?.isEnabled = false
        headerButton.isEnabled = false
        headerButton.resetInteraction()
        nameLabel.text = nil
        headerButton.accessibilityLabel = nil
        headerButton.accessibilityValue = nil
        headerButton.accessibilityHint = nil
        headerButton.accessibilityTraits = .button
        loadingIndicator.setRefreshing(false)
        statusImageView.image = nil
        flowView.setKinds([], onSelect: nil)
        kindsContainer.isHidden = true
        bottomConstraint?.constant = 0
        stack.setCustomSpacing(0, after: headerButton)
        accessibilityElements = []
    }

    @objc private func toggleSource() {
        guard sourceURL != nil, headerButton.isEnabled, !headerButton.suppressesCurrentTap,
            ExploreAndroidGraphics.isAvailableForInteraction(headerButton)
        else { return }
        onToggle?()
    }

    @objc private func showMenu(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, sourceURL != nil, headerButton.isEnabled,
            ExploreAndroidGraphics.isAvailableForInteraction(headerButton)
        else { return }
        headerButton.consumeLongPress()
        onShowMenu?(headerButton)
    }

    @objc private func accessibilityShowMenu() -> Bool {
        guard sourceURL != nil, headerButton.isEnabled,
            ExploreAndroidGraphics.isAvailableForInteraction(headerButton), let onShowMenu
        else { return false }
        headerButton.consumeLongPress()
        onShowMenu(headerButton)
        return true
    }
}

/// TextView's default sans-serif and includeFontPadding also apply to source names and kinds.
/// Keep these metrics in Discovery; reader font preferences must not change this screen.
internal enum AndroidExploreTextMetrics {
    static func font(compatibleWith traits: UITraitCollection) -> UIFont {
        // Scaling the unregistered file-backed font can substitute Helvetica on UIKit.
        let size = UIFontMetrics(forTextStyle: .subheadline).scaledValue(for: 14, compatibleWith: traits)
        return ReaderAndroidDefaultFont.font(size: size) ?? .systemFont(ofSize: size)
    }

    static func padding(font: UIFont, scale: CGFloat) -> UIEdgeInsets {
        let bounds = CTFontGetBoundingBox(font as CTFont)
        let scale = max(1, scale)
        return UIEdgeInsets(
            top: max(0, ceil(bounds.maxY * scale) / scale - font.ascender), left: 0,
            bottom: max(0, -floor(bounds.minY * scale) / scale + font.descender), right: 0)
    }
}

internal class AndroidExploreTextLabel: UILabel {
    var fontPadding: UIEdgeInsets {
        AndroidExploreTextMetrics.padding(font: font, scale: traitCollection.displayScale)
    }

    override var intrinsicContentSize: CGSize {
        paddedSize(super.intrinsicContentSize)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let padding = fontPadding
        return paddedSize(
            super.sizeThatFits(
                CGSize(
                    width: size.width, height: max(0, size.height - padding.top - padding.bottom))))
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: fontPadding))
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.displayScale != traitCollection.displayScale {
            invalidateIntrinsicContentSize()
            setNeedsDisplay()
        }
    }

    private func paddedSize(_ size: CGSize) -> CGSize {
        let padding = fontPadding
        return CGSize(width: size.width, height: max(font.lineHeight, size.height) + padding.top + padding.bottom)
    }
}

private final class AndroidExploreSourceHeaderButton: UIButton {
    private(set) var suppressesCurrentTap = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        configuration = nil
        automaticallyUpdatesConfiguration = false
        backgroundColor = ExploreAndroidGraphics.sourceHeaderBackground
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override func accessibilityActivate() -> Bool {
        guard isEnabled, ExploreAndroidGraphics.isAvailableForInteraction(self) else { return false }
        suppressesCurrentTap = false
        sendActions(for: .touchUpInside)
        return true
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard isEnabled, ExploreAndroidGraphics.isAvailableForInteraction(self) else { return false }
        suppressesCurrentTap = false
        return super.beginTracking(touch, with: event)
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        guard !suppressesCurrentTap, isEnabled, ExploreAndroidGraphics.isAvailableForInteraction(self) else {
            cancelTracking(with: event)
            isHighlighted = false
            return
        }
        super.endTracking(touch, with: event)
    }

    func consumeLongPress() {
        suppressesCurrentTap = true
        cancelTracking(with: nil)
        isHighlighted = false
    }

    func resetInteraction() {
        cancelTracking(with: nil)
        isHighlighted = false
        // A reused/rebound row must wait for a new touch-down before it can toggle.
        suppressesCurrentTap = true
    }
}
