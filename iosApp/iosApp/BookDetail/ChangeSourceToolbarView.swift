import UIKit

/// change_source.xml / ChangeBookSourceDialog.initSearchView at Legado 5f5d314.
final class ChangeSourceToolbarView: UIView {
    let searchField: UITextField = ChangeSourceToolbarSearchField()
    let moreButton = UIButton(type: .custom)
    var onBack: (() -> Void)?
    var onFilter: (() -> Void)?
    var onCollapseFilter: (() -> Void)?
    var onSearchToggle: (() -> Void)?
    var onMore: (() -> Void)?

    private let titleStack = UIStackView()
    private let nameLabel = ReaderTocSingleLineLabel()
    private let authorLabel = ReaderTocSingleLineLabel()
    private let backButton = UIButton(type: .custom)
    private let filterButton = UIButton(type: .custom)
    private let toggleButton = UIButton(type: .custom)
    private let searchPlate = UIView()
    private let searchUnderline = UIView()
    private let searchHintIcon = UIImageView()
    private var filterWidth: NSLayoutConstraint?
    private var filterTrailing: NSLayoutConstraint?
    private var navigationWidth: NSLayoutConstraint?
    private var heightConstraint: NSLayoutConstraint?
    private var inputHeightConstraint: NSLayoutConstraint?
    private var searchPlateHeight: NSLayoutConstraint?
    private var filterHeight: NSLayoutConstraint?
    private var titleText = ""
    private var authorText: String?
    private var isFilterExpanded = false
    private var areActionsEnabled = true
    private var palette: ChangeSourcePalette { ChangeSourcePalette(traits: traitCollection) }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureViews()
        configureLayout()
        updateTitle()
        setFilterExpanded(false)
        setSearching(false)
        applyPalette()
        let height = heightAnchor.constraint(equalToConstant: intrinsicContentSize.height)
        heightConstraint = height
        height.isActive = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override var intrinsicContentSize: CGSize {
        let titleHeight =
            nameLabel.intrinsicContentSize.height
            + (authorLabel.isHidden ? 0 : authorLabel.intrinsicContentSize.height) + 8
        return CGSize(width: UIView.noIntrinsicMetric, height: max(56, isFilterExpanded ? inputHeight + 12 : ceil(titleHeight)))
    }

    private var inputHeight: CGFloat {
        let font = searchField.font ?? .systemFont(ofSize: 18)
        let padding = AndroidExploreTextMetrics.padding(font: font, scale: traitCollection.displayScale)
        return max(36, ceil(font.lineHeight + padding.top + padding.bottom))
    }

    private func updateHeight() {
        let height = intrinsicContentSize.height
        heightConstraint?.constant = height
        inputHeightConstraint?.constant = inputHeight
        searchPlateHeight?.constant = inputHeight + 12
        filterHeight?.constant = isFilterExpanded ? height : 56
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let content = searchField.textRect(forBounds: searchField.bounds)
        let font = searchField.font ?? .systemFont(ofSize: 18)
        let space = (" " as NSString).size(withAttributes: [.font: font, .kern: CGFloat(0)]).width
        let size = max(0, min(floor(font.pointSize * 1.25), content.height, content.width - space))
        let isRTL = searchField.effectiveUserInterfaceLayoutDirection == .rightToLeft
        searchHintIcon.frame = CGRect(
            x: isRTL ? content.maxX - space - size : content.minX + space,
            y: content.midY - size / 2, width: size, height: size)
    }

    func configure(title: String, author: String?) {
        titleText = title
        authorText = author?.isEmpty == false ? author : nil
        updateNavigation()
        updateTitle()
    }

    func setSearching(_ searching: Bool) {
        let title = searching ? L10n.BookDetail.changeSourceStopSearch : L10n.BookDetail.changeSourceRestartSearch
        toggleButton.setImage(searching ? stopIcon : ReaderMenuAndroidIcon.refresh.image(), for: .normal)
        updateButtonDescription(toggleButton, title: title)
    }

    func setFilterExpanded(_ expanded: Bool) {
        isFilterExpanded = expanded
        updateNavigation()
        searchField.isHidden = !expanded
        searchField.accessibilityElementsHidden = !expanded
        searchPlate.isHidden = !expanded
        searchUnderline.isHidden = !expanded
        filterWidth?.constant = expanded ? 40 : 48
        filterTrailing?.constant = expanded ? -8 : 0
        filterButton.setImage(expanded ? ReaderMenuAndroidIcon.clear.image() : searchIcon, for: .normal)
        updateTitle()
        setFilterHasQuery(!(searchField.text ?? "").isEmpty)
        if expanded && areActionsEnabled {
            searchField.becomeFirstResponder()
        } else {
            searchField.resignFirstResponder()
        }
    }

    func setFilterHasQuery(_ hasQuery: Bool) {
        let hasText = hasQuery || !(searchField.text ?? "").isEmpty
        let title = isFilterExpanded ? (hasText ? "清空筛选" : "关闭筛选") : L10n.Reader.menuSearch
        updateButtonDescription(filterButton, title: title)
        searchHintIcon.isHidden = !isFilterExpanded || hasText
        searchField.accessibilityValue = searchField.text
    }

    /// Changes interaction only; search state, query, and action descriptions survive.
    func setActionsEnabled(_ enabled: Bool) {
        areActionsEnabled = enabled
        for button in [backButton, filterButton, toggleButton, moreButton] {
            button.isEnabled = enabled
        }
        searchField.isEnabled = enabled
        if !enabled { searchField.resignFirstResponder() }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateFonts()
        applyPalette()
    }

    private func configureViews() {
        clipsToBounds = true
        for label in [nameLabel, authorLabel] {
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        nameLabel.accessibilityTraits = .header
        titleStack.axis = .vertical
        titleStack.spacing = 0
        titleStack.clipsToBounds = true
        titleStack.addArrangedSubview(nameLabel)
        titleStack.addArrangedSubview(authorLabel)
        searchField.borderStyle = .none
        searchField.backgroundColor = .clear
        searchField.clearButtonMode = .never
        searchField.defaultTextAttributes[.kern] = 0
        searchField.autocapitalizationType = .none
        searchField.autocorrectionType = .no
        searchField.returnKeyType = .search
        searchField.accessibilityLabel = L10n.BookDetail.changeSourceSearchPlaceholder
        searchField.accessibilityIdentifier = "changeSource.filterField"
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        searchField.addTarget(self, action: #selector(updateSearchUnderline), for: [.editingDidBegin, .editingDidEnd])
        searchField.addTarget(self, action: #selector(queryChanged), for: .editingChanged)
        searchHintIcon.image = searchIcon
        searchHintIcon.contentMode = .scaleAspectFit
        searchHintIcon.isAccessibilityElement = false
        searchHintIcon.isUserInteractionEnabled = false
        searchField.addSubview(searchHintIcon)
        searchPlate.addSubview(searchField)
        searchPlate.addSubview(searchUnderline)
        searchUnderline.isUserInteractionEnabled = false
        configureButton(
            backButton, title: "返回", image: ReaderMenuAndroidIcon.back.image(), identifier: "changeSource.back"
        ) { [weak self] in self?.onBack?() }
        configureButton(
            filterButton, title: L10n.Reader.menuSearch, image: searchIcon, identifier: "changeSource.filter"
        ) { [weak self] in
            guard let self else { return }
            if self.isFilterExpanded, (self.searchField.text ?? "").isEmpty,
                let onCollapseFilter = self.onCollapseFilter
            {
                onCollapseFilter()
            } else {
                self.onFilter?()
            }
        }
        configureButton(
            toggleButton, title: L10n.BookDetail.changeSourceRestartSearch,
            image: ReaderMenuAndroidIcon.refresh.image(),
            identifier: "changeSource.searchToggle"
        ) { [weak self] in self?.onSearchToggle?() }
        configureButton(
            moreButton, title: "更多选项", image: ReaderMenuAndroidIcon.more.image(), identifier: "changeSource.more"
        ) { [weak self] in self?.onMore?() }
    }

    private func configureLayout() {
        for child in [
            backButton, titleStack, searchPlate, filterButton, toggleButton,
            moreButton,
        ] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        for button in [backButton, toggleButton, moreButton] {
            NSLayoutConstraint.activate([
                button.topAnchor.constraint(equalTo: topAnchor),
                button.heightAnchor.constraint(equalToConstant: 56),
            ])
        }
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchUnderline.translatesAutoresizingMaskIntoConstraints = false
        inputHeightConstraint = searchField.heightAnchor.constraint(equalToConstant: 36)
        searchPlateHeight = searchPlate.heightAnchor.constraint(equalToConstant: 48)
        filterHeight = filterButton.heightAnchor.constraint(equalToConstant: 56)
        filterWidth = filterButton.widthAnchor.constraint(equalToConstant: 48)
        filterTrailing = filterButton.trailingAnchor.constraint(equalTo: toggleButton.leadingAnchor)
        navigationWidth = backButton.widthAnchor.constraint(equalToConstant: 56)
        filterWidth?.isActive = true
        filterTrailing?.isActive = true
        navigationWidth?.isActive = true
        inputHeightConstraint?.isActive = true
        searchPlateHeight?.isActive = true
        filterHeight?.isActive = true
        NSLayoutConstraint.activate([
            filterButton.topAnchor.constraint(equalTo: topAnchor),
            backButton.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            moreButton.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            moreButton.widthAnchor.constraint(equalToConstant: 40),
            toggleButton.trailingAnchor.constraint(equalTo: moreButton.leadingAnchor),
            toggleButton.widthAnchor.constraint(equalToConstant: 48),
            titleStack.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 4),
            titleStack.trailingAnchor.constraint(equalTo: filterButton.leadingAnchor, constant: -4),
            titleStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleStack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 4),
            titleStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4),
            // Toolbar's 16dp content inset, SearchView's 8dp edit-frame margin, then 8dp input padding.
            searchPlate.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 24),
            searchPlate.trailingAnchor.constraint(equalTo: filterButton.trailingAnchor),
            searchPlate.centerYAnchor.constraint(equalTo: centerYAnchor),
            searchField.leadingAnchor.constraint(equalTo: searchPlate.leadingAnchor),
            searchField.trailingAnchor.constraint(equalTo: filterButton.leadingAnchor),
            searchField.centerYAnchor.constraint(equalTo: searchPlate.centerYAnchor),
            searchUnderline.leadingAnchor.constraint(equalTo: searchPlate.leadingAnchor),
            searchUnderline.trailingAnchor.constraint(equalTo: searchPlate.trailingAnchor),
            searchUnderline.bottomAnchor.constraint(equalTo: searchPlate.bottomAnchor),
            searchUnderline.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    private func updateNavigation() {
        let visible = !isFilterExpanded
        backButton.isHidden = !visible
        backButton.accessibilityElementsHidden = !visible
        navigationWidth?.constant = visible ? 56 : 0
    }

    private func updateTitle() {
        // Clear the content as well as hiding it, matching initSearchView's title/subtitle reset.
        nameLabel.text = isFilterExpanded ? nil : titleText
        authorLabel.text = isFilterExpanded ? nil : authorText
        for label in [nameLabel, authorLabel] {
            label.attributedText = label.text.map { NSAttributedString(string: $0, attributes: [.kern: 0]) }
        }
        nameLabel.accessibilityLabel = isFilterExpanded ? nil : titleText
        authorLabel.accessibilityLabel = isFilterExpanded ? nil : authorText
        authorLabel.isHidden = isFilterExpanded || authorText == nil
        titleStack.isHidden = isFilterExpanded
        titleStack.accessibilityElementsHidden = isFilterExpanded
        updateFonts()
    }

    private func updateFonts() {
        nameLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 20, textStyle: .headline, weight: 500, compatibleWith: traitCollection)
        authorLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 16, textStyle: .subheadline, compatibleWith: traitCollection)
        searchField.font = ReaderAndroidDefaultFont.scaledFont(
            size: 18, textStyle: .body, compatibleWith: traitCollection)
        updateHeight()
    }

    private var searchIcon: UIImage? {
        UIImage(named: "ChangeSourceAndroidSearch")?.withRenderingMode(.alwaysTemplate)
            ?? ReaderMenuAndroidIcon.search.image()
    }

    private var stopIcon: UIImage? {
        UIImage(named: "ChangeSourceAndroidStop")?.withRenderingMode(.alwaysTemplate)
            ?? UIImage(systemName: "stop.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 24))
    }

    private func configureButton(
        _ button: UIButton, title: String, image: UIImage?, identifier: String, handler: @escaping () -> Void
    ) {
        button.configuration = nil
        button.backgroundColor = .clear
        button.layer.cornerRadius = 0
        button.contentHorizontalAlignment = .center
        button.contentVerticalAlignment = .center
        button.imageView?.contentMode = .center
        button.setImage(image, for: .normal)
        button.accessibilityLabel = title
        button.accessibilityIdentifier = identifier
        button.accessibilityTraits = .button
        button.addInteraction(UIToolTipInteraction(defaultToolTip: title))
        button.addAction(
            UIAction { [weak self] _ in
                guard self?.areActionsEnabled == true else { return }
                handler()
            }, for: .touchUpInside)
    }

    private func updateButtonDescription(_ button: UIButton, title: String) {
        button.accessibilityLabel = title
        for tooltip in button.interactions.compactMap({ $0 as? UIToolTipInteraction }) {
            tooltip.defaultToolTip = title
        }
    }

    @objc private func queryChanged() {
        setFilterHasQuery(!(searchField.text ?? "").isEmpty)
    }

    @objc private func updateSearchUnderline() {
        searchUnderline.backgroundColor = palette.toolbarText.withAlphaComponent(searchField.isFirstResponder ? 1 : 0.5)
    }

    func applyPalette() {
        backgroundColor = palette.titleBackground
        nameLabel.textColor = palette.toolbarText
        authorLabel.textColor = palette.toolbarText.withAlphaComponent(0.7)
        searchField.textColor = palette.toolbarText
        searchField.tintColor = palette.toolbarText
        searchField.attributedPlaceholder = nil
        searchHintIcon.tintColor = palette.toolbarText.withAlphaComponent(0.5)
        for button in [backButton, filterButton, toggleButton, moreButton] {
            button.tintColor = palette.toolbarText
        }
        updateSearchUnderline()
    }
}

private final class ChangeSourceToolbarSearchField: UITextField {
    override func textRect(forBounds bounds: CGRect) -> CGRect { inputRect(in: bounds) }
    override func editingRect(forBounds bounds: CGRect) -> CGRect { inputRect(in: bounds) }

    private func inputRect(in bounds: CGRect) -> CGRect {
        let padding = AndroidExploreTextMetrics.padding(
            font: font ?? .systemFont(ofSize: 18), scale: traitCollection.displayScale)
        return CGRect(
            x: bounds.minX + 8, y: bounds.minY + padding.top,
            width: max(0, bounds.width - 16), height: max(0, bounds.height - padding.top - padding.bottom))
    }
}
