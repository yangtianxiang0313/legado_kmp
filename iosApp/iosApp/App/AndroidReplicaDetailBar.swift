import UIKit

final class AndroidReplicaDetailBar: NavigationToolbarView {
    override var usesOpaqueToolbarBackground: Bool { appearance != .coverOverlay }

    enum Appearance {
        case standard, coverOverlay
    }

    private let titleLabel = AndroidExploreTextLabel()
    private var toolbarHeight: NSLayoutConstraint!
    private var backButtonHeight: NSLayoutConstraint!
    private var backButtonLeading: NSLayoutConstraint!
    private var titleLeading: NSLayoutConstraint!
    private var actionsTrailing: NSLayoutConstraint!
    private var actionsCenterY: NSLayoutConstraint!
    private var availableSize: CGSize = .zero
    private let stack = UIStackView()
    private let backButton = UIButton(type: .custom)
    private var foregroundColor: UIColor {
        appearance == .coverOverlay ? .white : AndroidReplicaTheme.toolbarText
    }
    private let appearance: Appearance
    private var overflowButtons: [UIButton] = []

    private var resourceHeight: CGFloat {
        AndroidToolbarLayout.minimumHeight(for: availableSize)
    }

    init(title: String, target: Any?, backAction: Selector, appearance: Appearance = .standard) {
        self.appearance = appearance
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        backButton.setImage(ReaderMenuAndroidIcon.back.image(), for: .normal)
        backButton.accessibilityLabel = L10n.Reader.backAction
        backButton.accessibilityIdentifier = UIIdentifiers.Common.drillDownBackButton
        backButton.addTarget(target, action: backAction, for: .touchUpInside)
        backButton.widthAnchor.constraint(equalToConstant: 56).isActive = true
        backButtonHeight = backButton.heightAnchor.constraint(equalToConstant: resourceHeight)

        // ToolbarTitle is 20sp, inheriting Material's sans-serif-medium.
        titleLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 20, textStyle: .headline, weight: 500, compatibleWith: traitCollection)
        titleLabel.adjustsFontForContentSizeCategory = false
        titleLabel.adjustsFontSizeToFitWidth = false
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        if appearance == .coverOverlay {
            titleLabel.numberOfLines = 1
            titleLabel.clipsToBounds = true
            titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            configureOverlayButton(backButton)
        }
        setTitle(title)

        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = appearance == .coverOverlay ? 0 : 2

        for item in [backButton, titleLabel, stack] {
            item.translatesAutoresizingMaskIntoConstraints = false
            addSubview(item)
        }

        toolbarHeight = heightAnchor.constraint(equalToConstant: resourceHeight)
        backButtonLeading = backButton.leadingAnchor.constraint(equalTo: leadingAnchor)
        titleLeading = titleLabel.leadingAnchor.constraint(
            equalTo: backButton.trailingAnchor,
            constant: appearance == .coverOverlay
                ? AndroidToolbarLayout.contentInsetStartWithNavigation(for: availableSize) + 4 - 56 : 0)
        actionsTrailing = stack.trailingAnchor.constraint(
            equalTo: trailingAnchor, constant: appearance == .coverOverlay ? 0 : -8)
        actionsCenterY = stack.centerYAnchor.constraint(equalTo: topAnchor, constant: resourceHeight / 2)
        NSLayoutConstraint.activate([
            toolbarHeight,
            backButtonHeight,
            backButtonLeading,
            titleLeading,
            actionsTrailing,
            actionsCenterY,
            // AppCompat buttonGravity=top leaves buttons in the first resource-height row.
            backButton.topAnchor.constraint(equalTo: topAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: stack.leadingAnchor, constant: appearance == .coverOverlay ? -4 : -8),
        ])
        if appearance == .coverOverlay {
            titleLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 0).isActive = true
            stack.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        applyPalette()
        updateTypography()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateTypography()
        applyPalette()
    }

    func setTitle(_ title: String) {
        let display = title.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: "\u{FEFF}")
        if appearance == .coverOverlay {
            titleLabel.attributedText = NSAttributedString(string: display, attributes: [.kern: CGFloat(0)])
        } else {
            titleLabel.text = display
        }
        titleLabel.accessibilityLabel = title
    }

    /// The root supplies its available size, independently of the toolbar's measured height.
    func updateLayout(availableSize: CGSize) {
        guard availableSize.width.isFinite, availableSize.height.isFinite,
            availableSize.width > 0, availableSize.height > 0, self.availableSize != availableSize
        else { return }
        self.availableSize = availableSize
        backButtonHeight.constant = resourceHeight
        actionsCenterY.constant = resourceHeight / 2
        if appearance == .coverOverlay {
            let padding = AndroidToolbarLayout.horizontalPadding(for: availableSize)
            backButtonLeading.constant = padding
            titleLeading.constant = AndroidToolbarLayout.contentInsetStartWithNavigation(for: availableSize) + 4 - 56
            actionsTrailing.constant = -padding
        }
        updateToolbarHeight()
    }

    func addAction(_ button: UIButton, isOverflow: Bool = false) {
        applyPalette(to: button)
        let width: CGFloat = appearance == .coverOverlay ? (isOverflow ? 40 : 48) : 42
        let height: CGFloat = appearance == .coverOverlay ? 48 : 42
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
        button.heightAnchor.constraint(equalToConstant: height).isActive = true
        if appearance == .coverOverlay {
            configureOverlayButton(button)
            if isOverflow { overflowButtons.append(button) }
        }
        stack.addArrangedSubview(button)
    }

    override func layoutSubviews() {
        // AppCompat overflow padding is start 6dp / end 10dp, not a centered 48dp slot.
        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let insets = UIEdgeInsets(top: 0, left: isRTL ? 10 : 6, bottom: 0, right: isRTL ? 6 : 10)
        for button in overflowButtons where button.configuration == nil && button.contentEdgeInsets != insets {
            button.contentEdgeInsets = insets
        }
        super.layoutSubviews()
    }

    private func applyPalette() {
        // activity_book_info.xml uses themeMode="dark" even in a light app theme.
        tintColor = foregroundColor
        titleLabel.textColor = foregroundColor
        applyPalette(to: backButton)
        for case let button as UIButton in stack.arrangedSubviews {
            applyPalette(to: button)
        }
    }

    private func updateTypography() {
        titleLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 20, textStyle: .headline, weight: 500, compatibleWith: traitCollection)
        updateToolbarHeight()
    }

    private func updateToolbarHeight() {
        let padding = titleLabel.fontPadding
        toolbarHeight?.constant = max(
            resourceHeight,
            ceil(titleLabel.font.lineHeight + padding.top + padding.bottom + AndroidToolbarLayout.titleVerticalMargins))
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private func applyPalette(to button: UIButton) {
        button.tintColor = foregroundColor
        if button.configuration == nil {
            button.setTitleColor(foregroundColor, for: .normal)
        }
    }

    private func configureOverlayButton(_ button: UIButton) {
        guard button.configuration == nil else { return }
        button.backgroundColor = .clear
        button.contentEdgeInsets = .zero
        button.contentHorizontalAlignment = .center
        button.imageView?.contentMode = .center
    }
}
