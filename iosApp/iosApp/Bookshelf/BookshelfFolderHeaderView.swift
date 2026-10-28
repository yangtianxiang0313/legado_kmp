import UIKit

final class BookshelfFolderHeaderView: UIView {
    var onBack: (() -> Void)?
    var onSearch: (() -> Void)?
    var onMore: (() -> Void)?
    var moreAnchor: UIView { moreButton }

    private let backButton = BookshelfHeaderActionButton(type: .custom)
    private let searchButton = BookshelfHeaderActionButton(type: .custom)
    private let moreButton = BookshelfHeaderActionButton(type: .custom)
    private let titleLabel = UILabel()
    private var preferredHeight: CGFloat = 56

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: preferredHeight)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = AndroidReplicaTheme.toolbarBackground
        accessibilityIdentifier = "bookshelf.folderHeader"
        isAccessibilityElement = false
        shouldGroupAccessibilityChildren = true
        setContentCompressionResistancePriority(.required, for: .vertical)

        configureActionButton(
            backButton, asset: "ReaderMenuAndroidBack", label: L10n.Reader.backAction,
            identifier: "bookshelf.folderBack", action: #selector(didTapBack))
        configureActionButton(
            searchButton, asset: "ReaderMenuAndroidSearch", label: L10n.Bookshelf.openSearch,
            identifier: "bookshelf.search", action: #selector(didTapSearch))
        configureActionButton(
            moreButton, asset: "ReaderMenuAndroidMore", label: L10n.Bookshelf.moreActions,
            identifier: "bookshelf.more", action: #selector(didTapMore))

        titleLabel.textColor = AndroidReplicaTheme.toolbarText
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.adjustsFontSizeToFitWidth = false
        titleLabel.isAccessibilityElement = true
        titleLabel.accessibilityTraits = .header
        titleLabel.accessibilityIdentifier = "bookshelf.folderTitle"
        addSubview(titleLabel)
        updateTypography()
        configure(groupName: nil)
        refreshColors()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    func configure(groupName: String?) {
        backButton.isHidden = groupName == nil
        backButton.isEnabled = groupName != nil
        titleLabel.text = groupName.map { "\(L10n.Tabs.bookshelf)(\($0))" } ?? L10n.Tabs.bookshelf
        titleLabel.accessibilityLabel = titleLabel.text
        accessibilityElements =
            groupName == nil
            ? [titleLabel, searchButton, moreButton]
            : [backButton, titleLabel, searchButton, moreButton]
        setNeedsLayout()
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: preferredHeight)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let leading = safeAreaInsets.left
        let width = max(0, bounds.width - leading - safeAreaInsets.right)
        func frame(leading offset: CGFloat, width itemWidth: CGFloat) -> CGRect {
            CGRect(
                x: leading + (rtl ? width - offset - itemWidth : offset),
                y: 0, width: itemWidth, height: bounds.height)
        }

        backButton.frame = frame(leading: 0, width: backButton.isHidden ? 0 : 56)
        searchButton.frame = frame(leading: max(0, width - 88), width: 48)
        moreButton.frame = frame(leading: max(0, width - 40), width: 40)
        moreButton.contentEdgeInsets = UIEdgeInsets(
            top: 0, left: rtl ? 10 : 6, bottom: 0, right: rtl ? 6 : 10)

        // AppCompat reserves the navigation/title inset separately from the fixed menu slots.
        let titleLeading: CGFloat = backButton.isHidden ? 16 : 72
        let titleHeight = ceil(titleLabel.font.lineHeight)
        titleLabel.frame = CGRect(
            x: leading + (rtl ? 96 : titleLeading),
            y: max(0, (bounds.height - titleHeight) / 2),
            width: max(0, width - titleLeading - 96), height: titleHeight)
        titleLabel.textAlignment = rtl ? .right : .left
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.hasDifferentColorAppearance(comparedTo: traitCollection) ?? true {
            refreshColors()
        }
        if previousTraitCollection?.preferredContentSizeCategory
            != traitCollection.preferredContentSizeCategory
        {
            updateTypography()
        }
    }

    func refreshColors() {
        backgroundColor = AndroidReplicaTheme.toolbarBackground.resolvedColor(with: traitCollection)
        titleLabel.textColor = AndroidReplicaTheme.toolbarText.resolvedColor(with: traitCollection)
        for button in [backButton, searchButton, moreButton] { button.refreshColors() }
    }

    private func updateTypography() {
        titleLabel.font = UIFontMetrics(forTextStyle: .headline).scaledFont(
            for: .systemFont(ofSize: 20, weight: .medium), compatibleWith: traitCollection)
        preferredHeight = max(56, ceil(titleLabel.font.lineHeight) + 24)
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private func configureActionButton(
        _ button: UIButton, asset: String, label: String, identifier: String, action: Selector
    ) {
        button.configuration = nil
        button.automaticallyUpdatesConfiguration = false
        button.backgroundColor = .clear
        button.tintColor = AndroidReplicaTheme.toolbarText
        var image = UIImage(named: asset)?.withRenderingMode(.alwaysTemplate)
        if button === backButton { image = image?.imageFlippedForRightToLeftLayoutDirection() }
        button.setImage(image, for: .normal)
        button.imageView?.contentMode = .center
        button.accessibilityLabel = label
        button.accessibilityIdentifier = identifier
        button.isExclusiveTouch = true
        button.addInteraction(UIToolTipInteraction(defaultToolTip: label))
        button.addTarget(self, action: action, for: .touchUpInside)
        addSubview(button)
    }

    @objc private func didTapBack() {
        guard !backButton.isHidden else { return }
        onBack?()
    }

    @objc private func didTapSearch() {
        onSearch?()
    }

    @objc private func didTapMore() {
        onMore?()
    }
}
